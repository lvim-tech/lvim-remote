-- lvim-remote.jobs: every external process — rsync (dry / real), scp single-file transfers, and
-- the ssh remote read for the diff view — through async `vim.system` with LIST-FORM argv (no
-- string shells on the local side). The argv builders are PURE functions, exposed so tests can
-- assert the exact command without touching a network. Remote-side safety: rsync gets `-s`
-- (secluded args — the remote shell never re-splits our paths) via config.rsync_flags, while scp
-- and the ssh `cat` DO traverse a remote shell, so their remote path is `vim.fn.shellescape`d.
-- No secrets anywhere: authentication is ssh's business; a failing target surfaces ssh's own
-- stderr to the caller.
--
---@module "lvim-remote.jobs"

local config = require("lvim-remote.config")

local M = {}

---@class LvimRemoteJobResult
---@field ok boolean       exit code == 0
---@field code integer     the process exit code
---@field stdout string
---@field stderr string

---@alias LvimRemoteDirection "up"|"down"

--- Join a target's remote root with an optional project-relative path, single-slashed.
---@param target LvimRemoteTarget
---@param rel string?  project-relative path ("" / nil = the root itself)
---@return string  the remote absolute path
local function remote_path(target, rel)
    local base = target.path:gsub("/+$", "")
    if not rel or rel == "" then
        return base
    end
    return base .. "/" .. rel:gsub("^/+", "")
end

--- The `host:path` remote spec rsync/scp expect.
---@param target LvimRemoteTarget
---@param rel string?
---@param escape boolean?  shell-escape the path part (scp / ssh — their remote side is a shell)
---@return string
local function remote_spec(target, rel, escape)
    local path = remote_path(target, rel)
    if escape then
        path = vim.fn.shellescape(path)
    end
    return target.host .. ":" .. path
end

--- Run an argv async; the callback gets a normalized result on the main loop.
---@param argv string[]
---@param cb fun(res: LvimRemoteJobResult)
---@return vim.SystemObj? handle  nil when the executable is missing (cb still fires with an error)
local function run(argv, cb)
    local ok, handle = pcall(vim.system, argv, { text = true }, function(out)
        vim.schedule(function()
            cb({
                ok = out.code == 0,
                code = out.code,
                stdout = out.stdout or "",
                stderr = out.stderr or "",
            })
        end)
    end)
    if not ok then
        vim.schedule(function()
            cb({ ok = false, code = -1, stdout = "", stderr = tostring(handle) })
        end)
        return nil
    end
    return handle
end

-- ── rsync (directory sync) ───────────────────────────────────────────────────

---@class LvimRemoteRsyncOpts
---@field direction LvimRemoteDirection  "up" = local → remote, "down" = remote → local
---@field root string        the local project root
---@field subdir string?     sync only this project-relative subtree
---@field dry boolean?       itemized dry run (`-n`)
---@field delete boolean?    propagate deletions (`--delete`) — the caller passes this ONLY after
---                          the review panel showed the deletions and the user applied

--- Build the exact rsync argv for a sync (pure — asserted by the tests). The dry run and the
--- real run share every flag except `-n`, so what the panel reviewed is what apply executes.
---@param target LvimRemoteTarget
---@param opts LvimRemoteRsyncOpts
---@return string[] argv
function M.rsync_argv(target, opts)
    local argv = { config.rsync }
    vim.list_extend(argv, config.rsync_flags)
    argv[#argv + 1] = "--itemize-changes"
    if opts.dry then
        argv[#argv + 1] = "-n"
    end
    if opts.delete then
        argv[#argv + 1] = "--delete"
    end
    for _, pat in ipairs(target.excluded or {}) do
        argv[#argv + 1] = "--exclude=" .. pat
    end
    if target.port then
        -- rsync itself splits this -e value into the remote-shell argv; no local shell involved.
        argv[#argv + 1] = "-e"
        argv[#argv + 1] = ("%s -p %d"):format(config.ssh, target.port)
    end
    -- Trailing slashes on BOTH sides: sync the trees' CONTENTS onto each other (never nest the
    -- source dir inside the destination).
    local local_side = vim.fs.joinpath(opts.root, opts.subdir or ""):gsub("/+$", "") .. "/"
    local remote_side = remote_spec(target, opts.subdir, false) .. "/"
    if opts.direction == "up" then
        vim.list_extend(argv, { local_side, remote_side })
    else
        vim.list_extend(argv, { remote_side, local_side })
    end
    return argv
end

--- Run a sync (dry or real) async.
---@param target LvimRemoteTarget
---@param opts LvimRemoteRsyncOpts
---@param cb fun(res: LvimRemoteJobResult)
---@return vim.SystemObj?
function M.rsync(target, opts, cb)
    return run(M.rsync_argv(target, opts), cb)
end

-- ── scp (single file) ────────────────────────────────────────────────────────

--- Build the scp argv for one file (pure). scp's remote side goes through a remote shell, so the
--- remote path is shell-escaped; the local path is a plain argv element.
---@param target LvimRemoteTarget
---@param direction LvimRemoteDirection
---@param rel string        project-relative file path
---@param local_path string  the local absolute file path
---@return string[] argv
function M.scp_argv(target, direction, rel, local_path)
    local argv = { config.scp, "-q" }
    if target.port then
        vim.list_extend(argv, { "-P", tostring(target.port) })
    end
    local remote = remote_spec(target, rel, true)
    if direction == "up" then
        vim.list_extend(argv, { local_path, remote })
    else
        vim.list_extend(argv, { remote, local_path })
    end
    return argv
end

--- Upload one file (current-buffer op / the save watcher).
---@param target LvimRemoteTarget
---@param rel string
---@param local_path string
---@param cb fun(res: LvimRemoteJobResult)
---@return vim.SystemObj?
function M.upload_file(target, rel, local_path, cb)
    return run(M.scp_argv(target, "up", rel, local_path), cb)
end

--- Download one file, overwriting the local copy (the caller confirms a modified buffer first).
---@param target LvimRemoteTarget
---@param rel string
---@param local_path string
---@param cb fun(res: LvimRemoteJobResult)
---@return vim.SystemObj?
function M.download_file(target, rel, local_path, cb)
    return run(M.scp_argv(target, "down", rel, local_path), cb)
end

-- ── ssh (remote read) ────────────────────────────────────────────────────────

--- Build the ssh argv that reads a remote file to stdout (pure). The `cat <path>` part executes
--- in the remote shell, so the path is shell-escaped.
---@param target LvimRemoteTarget
---@param rel string
---@return string[] argv
function M.cat_argv(target, rel)
    local argv = { config.ssh }
    if target.port then
        vim.list_extend(argv, { "-p", tostring(target.port) })
    end
    vim.list_extend(argv, { target.host, "cat " .. vim.fn.shellescape(remote_path(target, rel)) })
    return argv
end

--- Fetch a remote file's content (the diff view). cb gets the raw bytes in `stdout` on success.
---@param target LvimRemoteTarget
---@param rel string
---@param cb fun(res: LvimRemoteJobResult)
---@return vim.SystemObj?
function M.remote_cat(target, rel, cb)
    return run(M.cat_argv(target, rel), cb)
end

--- Probe a target non-interactively (health, opt-in): BatchMode forbids any prompt, so an
--- unreachable / unauthenticated target fails fast instead of hanging on a password ask.
---@param target LvimRemoteTarget
---@param timeout integer  seconds
---@return boolean ok, string detail
function M.reachable(target, timeout)
    local argv = { config.ssh, "-o", "BatchMode=yes", "-o", ("ConnectTimeout=%d"):format(timeout) }
    if target.port then
        vim.list_extend(argv, { "-p", tostring(target.port) })
    end
    vim.list_extend(argv, { target.host, "true" })
    local ok, res = pcall(function()
        return vim.system(argv, { text = true }):wait((timeout + 2) * 1000)
    end)
    if not ok then
        return false, tostring(res)
    end
    return res.code == 0, vim.trim(res.stderr or "")
end

return M
