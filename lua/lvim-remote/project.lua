-- lvim-remote.project: the per-project deployment config — root finding, `.lvim/remote/config.lua`
-- load / validate / scaffold. The file is user-authored PROJECT DATA (the same trust level as an
-- exrc), but it is still handled conservatively: loaded lazily on the first command (never
-- implicitly on BufEnter), executed in an EMPTY environment (a pure data table — any function
-- call inside fails), and REFUSED outright when any target carries a plaintext-secret-looking
-- field (passwords must never exist in plain text; auth is entirely ssh's business).
--
---@module "lvim-remote.project"

local uv = vim.uv
local config = require("lvim-remote.config")

local M = {}

---@class LvimRemoteTarget
---@field host string        ssh alias (preferred) or user@host
---@field path string        absolute remote project root
---@field excluded? string[] rsync exclude patterns (also filter upload-on-save)
---@field port? integer      optional ssh port; nil = ssh_config decides

---@class LvimRemoteProjectConfig
---@field targets table<string, LvimRemoteTarget>
---@field default? string          the target used when none is chosen
---@field upload_on_save? boolean  enable the save watcher once this project config loads

-- Per-root cache: the loaded config, invalidated by the file's identity (an edited remote.lua is
-- re-read on the next command — no manual reload step). Keyed on the FULL mtime (sec + nsec) plus
-- size, not the second alone: two writes within the same second (a scripted edit, a `git checkout`
-- of a branch with same-second timestamps) still invalidate.
---@type table<string, { sec: integer, nsec: integer, size: integer, cfg: LvimRemoteProjectConfig }>
local cache = {}

-- Target keys that smell like a plaintext secret. Their PRESENCE (with a string value) makes the
-- whole config invalid — there is no supported password flow; ssh keys / ssh_config own auth.
---@type string[]
local SECRET_KEYS = { "password", "passwd", "pass", "sshpass", "secret", "token" }

--- The project-config template written by `:LvimRemote init` (and shown in the docs).
---@return string
function M.template()
    return table.concat({
        "-- lvim-remote per-project deployment config — PURE DATA, no code (loaded in an empty",
        "-- environment, so function calls fail). Auth is entirely ssh's business: use ssh keys /",
        "-- ssh_config aliases. NEVER put a password here — lvim-remote refuses plaintext secrets.",
        "return {",
        "    targets = {",
        "        production = {",
        '            host = "myserver", -- ssh alias (preferred) or user@host',
        '            path = "/var/www/app", -- absolute remote project root',
        '            excluded = { ".git", "node_modules", ".env" },',
        "            port = nil, -- optional; else ssh_config decides",
        "        },",
        "    },",
        '    default = "production",',
        "    upload_on_save = false,",
        "}",
        "",
    }, "\n")
end

--- The directory that anchors a scaffold: the nearest `.git` ancestor of `from` (else its cwd).
---@param from string?  a path to start from (default: the current buffer's file, else the cwd)
---@return string
local function scaffold_root(from)
    local start = from or vim.api.nvim_buf_get_name(0)
    if start == "" then
        start = vim.fn.getcwd()
    end
    return vim.fs.normalize(vim.fs.root(start, ".git") or vim.fn.getcwd())
end

--- Find the project root: the nearest ancestor (of the current file, else the cwd) that contains
--- the project config file (`config.config_file`). nil when no ancestor has one.
---@param from string?  a path to start from (default: the current buffer's file, else the cwd)
---@return string? root
function M.root(from)
    local start = from or vim.api.nvim_buf_get_name(0)
    if start == "" then
        start = vim.fn.getcwd()
    end
    start = vim.fs.normalize(start)
    local stat = uv.fs_stat(start)
    local dir = (stat and stat.type == "directory") and start or vim.fs.dirname(start)
    while dir do
        if uv.fs_stat(vim.fs.joinpath(dir, config.config_file)) then
            return dir
        end
        local parent = vim.fs.dirname(dir)
        if parent == dir then
            return nil
        end
        dir = parent
    end
    return nil
end

--- The absolute path of a root's project config file.
---@param root string
---@return string
function M.config_path(root)
    return vim.fs.joinpath(root, config.config_file)
end

--- Validate a decoded project config. Collects EVERY violation (not just the first), including
--- the hard secret rule: any target field named like a password/secret invalidates the config.
---@param cfg any  the value the project file returned
---@return boolean ok, string[] errors
function M.validate(cfg)
    local errs = {}
    local function err(fmt, ...)
        errs[#errs + 1] = fmt:format(...)
    end
    if type(cfg) ~= "table" then
        err("the config file must return a table")
        return false, errs
    end
    if type(cfg.targets) ~= "table" or vim.tbl_isempty(cfg.targets) then
        err("targets must be a non-empty table")
        return false, errs
    end
    for name, t in pairs(cfg.targets) do
        if type(t) ~= "table" then
            err("target '%s' must be a table", tostring(name))
        else
            -- `host` reaches argv in POSITIONAL / option-adjacent slots of ssh / scp / rsync
            -- (`{ target.host, "cat …" }`, `host:path`), and ssh has no reliable `--`
            -- end-of-options. A `-`-leading value would be parsed as an OPTION (e.g.
            -- `-oProxyCommand=…` → local command execution) — so a cloned repo's `.lvim/remote/config.lua`
            -- must never be able to smuggle one. Restrict `host` to the documented shape (ssh alias
            -- or user@host): first char alnum/`_`, then only `[A-Za-z0-9 . @ _ -]`. This rejects a
            -- leading `-`, whitespace, slashes, and quotes at the validation seam (the correct place).
            if type(t.host) ~= "string" or vim.trim(t.host) == "" then
                err("target '%s': host must be a non-empty string (ssh alias or user@host)", name)
            elseif not t.host:match("^[%w_][%w%.@_%-]*$") then
                err(
                    "target '%s': host has an invalid character or a leading '-' — must be an ssh alias or user@host ([A-Za-z0-9._@-], not starting with '-')",
                    name
                )
            end
            if type(t.path) ~= "string" or not t.path:match("^/") then
                err("target '%s': path must be an absolute remote path", name)
            end
            if t.excluded ~= nil then
                if type(t.excluded) ~= "table" then
                    err("target '%s': excluded must be a list of strings", name)
                else
                    for i, pat in ipairs(t.excluded) do
                        if type(pat) ~= "string" then
                            err("target '%s': excluded[%d] is not a string", name, i)
                        end
                    end
                end
            end
            if t.port ~= nil and (type(t.port) ~= "number" or t.port < 1 or t.port > 65535 or t.port % 1 ~= 0) then
                err("target '%s': port must be an integer in 1..65535 (or nil for ssh_config)", name)
            end
            -- The hard secret rule: plaintext passwords must never exist. A secret-looking field
            -- (with a string value — an actual credential, not a boolean flag) refuses the config.
            for _, key in ipairs(SECRET_KEYS) do
                if type(t[key]) == "string" then
                    err(
                        "target '%s': plaintext secrets are forbidden ('%s' field found) — auth is ssh's business (keys / ssh_config)",
                        name,
                        key
                    )
                end
            end
        end
    end
    if cfg.default ~= nil and cfg.targets[cfg.default] == nil then
        err("default names a missing target ('%s')", tostring(cfg.default))
    end
    if cfg.upload_on_save ~= nil and type(cfg.upload_on_save) ~= "boolean" then
        err("upload_on_save must be a boolean")
    end
    return #errs == 0, errs
end

--- Load a root's project config through the cache (invalidated by the file's mtime). The chunk
--- runs with an EMPTY environment — the file is a pure data table; any function call inside
--- raises, so nothing in it can execute code.
---@param root string
---@return LvimRemoteProjectConfig? cfg, string? err
function M.load(root)
    local path = M.config_path(root)
    local stat = uv.fs_stat(path)
    if not stat then
        return nil, ("no project config (%s)"):format(path)
    end
    local hit = cache[root]
    if hit and hit.sec == stat.mtime.sec and hit.nsec == stat.mtime.nsec and hit.size == stat.size then
        return hit.cfg
    end
    local chunk, load_err = loadfile(path)
    if not chunk then
        return nil, ("cannot parse %s: %s"):format(path, load_err or "?")
    end
    setfenv(chunk, {}) -- pure data: no globals, no function calls (LuaJIT / Lua 5.1)
    local ok, cfg = pcall(chunk)
    if not ok then
        return nil, ("error evaluating %s: %s"):format(path, tostring(cfg))
    end
    local valid, errs = M.validate(cfg)
    if not valid then
        return nil, ("invalid %s:\n  - %s"):format(path, table.concat(errs, "\n  - "))
    end
    cache[root] = { sec = stat.mtime.sec, nsec = stat.mtime.nsec, size = stat.size, cfg = cfg }
    return cfg
end

--- Drop the cached config for `root` (or every root). The mtime check already reloads edited
--- files; this is for tests and for a deleted config.
---@param root string?
function M.invalidate(root)
    if root then
        cache[root] = nil
    else
        cache = {}
    end
end

--- The sorted target names of a project config.
---@param cfg LvimRemoteProjectConfig
---@return string[]
function M.targets(cfg)
    local names = vim.tbl_keys(cfg.targets)
    table.sort(names)
    return names
end

--- Scaffold the project config: write the template at the nearest `.git` root (else the cwd) —
--- never overwriting an existing file — then open it for editing.
---@return string path  the (created or pre-existing) config file path
function M.scaffold()
    local root = M.root() or scaffold_root()
    local path = M.config_path(root)
    if not uv.fs_stat(path) then
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        local fd = assert(io.open(path, "w"))
        fd:write(M.template())
        fd:close()
        vim.notify("lvim-remote: scaffolded " .. path, vim.log.levels.INFO)
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
    return path
end

return M
