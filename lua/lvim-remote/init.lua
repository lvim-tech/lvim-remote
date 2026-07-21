-- lvim-remote: deploy/sync a project to remote machines over ssh — the deployment plugin of the
-- lvim-tech set. Per-project targets in `.lvim/remote/config.lua` (pure data, loaded lazily on the
-- first command — never on BufEnter), single-file upload/download/diff for the current buffer,
-- and whole-tree rsync in BOTH directions where EVERY sync runs as a dry run first and shows the
-- itemized changes in a review panel — nothing destructive ever executes unreviewed, and
-- `--delete` reaches the real run only when the panel showed the deletions. Auth is entirely
-- ssh's business (keys / ssh_config aliases): no password flow exists, no secret is ever stored,
-- prompted for, or put on a command line. This module is the public seam: `setup()`, the
-- `:LvimRemote` command (+completion), the session-sticky target, and the op orchestration.
--
---@module "lvim-remote"

local api = vim.api
local config = require("lvim-remote.config")
local project = require("lvim-remote.project")
local jobs = require("lvim-remote.jobs")
local parse = require("lvim-remote.parse")
local panel = require("lvim-remote.panel")
local diff = require("lvim-remote.diff")
local watch = require("lvim-remote.watch")
local highlights = require("lvim-remote.highlights")
local merge = require("lvim-utils.utils").merge
local hl = require("lvim-utils.highlight")
local ui = require("lvim-ui")

local M = {}

---@type boolean  setup() ran (command registered)
local registered = false

--- The session-sticky target per project root (chosen via the chooser / an explicit arg).
---@type table<string, string>
local sticky = {}

--- The session-sticky review-panel layout (a per-command float|area|bottom token survives).
---@type string?
local sticky_layout

---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-remote: " .. msg, level or vim.log.levels.INFO)
end

--- The sticky target name for a root (the watch module reads it — saves must resolve silently).
---@param root string
---@return string?
function M.sticky_target(root)
    return sticky[root]
end

-- ── project / target resolution ──────────────────────────────────────────────

--- Load the project context for the current buffer: root + validated config. Errors notify.
--- Loading is the ONLY execution of the project file, and it happens here — on a user command.
---@return string? root, LvimRemoteProjectConfig? cfg
local function context()
    local root = project.root()
    if not root then
        notify(
            "no " .. config.config_file .. " found upward — scaffold one with :LvimRemote init",
            vim.log.levels.WARN
        )
        return nil
    end
    local cfg, err = project.load(root)
    if not cfg then
        notify(err or "project config failed to load", vim.log.levels.ERROR)
        return root
    end
    watch.maybe_enable(cfg) -- honour upload_on_save on the lazy first load (a user command, not BufEnter)
    return root, cfg
end

--- Resolve the target an op runs against: an explicit name, the session-sticky choice, the
--- config default, a single target — or the `ui.select` chooser (async), whose pick becomes
--- sticky. `cb(target, name)` fires only on a resolved target.
---@param root string
---@param cfg LvimRemoteProjectConfig
---@param explicit string?
---@param cb fun(target: LvimRemoteTarget, name: string)
local function resolve_target(root, cfg, explicit, cb)
    if explicit then
        local t = cfg.targets[explicit]
        if not t then
            notify(
                ("no target '%s' (have: %s)"):format(explicit, table.concat(project.targets(cfg), ", ")),
                vim.log.levels.ERROR
            )
            return
        end
        sticky[root] = explicit
        cb(t, explicit)
        return
    end
    local name = sticky[root] or cfg.default
    if name and cfg.targets[name] then
        cb(cfg.targets[name], name)
        return
    end
    local names = project.targets(cfg)
    if #names == 1 then
        sticky[root] = names[1]
        cb(cfg.targets[names[1]], names[1])
        return
    end
    M.choose_target(root, cfg, cb)
end

--- The target chooser (`:LvimRemote target`, or any op with several targets and no default):
--- an `lvim-ui.select` over the target names; the pick is sticky for the session.
---@param root string
---@param cfg LvimRemoteProjectConfig
---@param cb fun(target: LvimRemoteTarget, name: string)?
function M.choose_target(root, cfg, cb)
    local names = project.targets(cfg)
    local items = {}
    for _, name in ipairs(names) do
        local t = cfg.targets[name]
        items[#items + 1] = {
            label = ("%s — %s:%s"):format(name, t.host, t.path),
            icon = config.icons.target,
            _name = name,
        }
    end
    local current = sticky[root] or cfg.default
    local current_item
    for _, it in ipairs(items) do
        if it._name == current then
            current_item = it
        end
    end
    ui.select({
        title = config.icons.remote .. " Remote target",
        items = items,
        current_item = current_item,
        callback = function(confirmed, index)
            if confirmed == true and items[index] then
                local name = items[index]._name
                sticky[root] = name
                notify("target ➤ " .. name)
                if cb then
                    cb(cfg.targets[name], name)
                end
            end
        end,
    })
end

--- The current buffer as a project file: absolute path + root-relative path. Errors notify.
---@param root string
---@return string? path, string? rel, integer? buf
local function buffer_file(root)
    local buf = api.nvim_get_current_buf()
    local path = api.nvim_buf_get_name(buf)
    if path == "" or vim.bo[buf].buftype ~= "" then
        notify("the current buffer is not a file", vim.log.levels.WARN)
        return nil
    end
    path = vim.fs.normalize(path)
    if path:sub(1, #root + 1) ~= root .. "/" then
        notify("the current file is outside the project root " .. root, vim.log.levels.WARN)
        return nil
    end
    return path, path:sub(#root + 2), buf
end

-- ── file ops (current buffer) ────────────────────────────────────────────────

--- Upload the current buffer's file to a target.
---@param explicit string?  target name from the command line
function M.upload(explicit)
    local root, cfg = context()
    if not (root and cfg) then
        return
    end
    local path, rel, buf = buffer_file(root)
    if not (path and rel) then
        return
    end
    if buf and vim.bo[buf].modified then
        notify("the buffer has unsaved changes — save it first (the DISK file is what uploads)", vim.log.levels.WARN)
        return
    end
    resolve_target(root, cfg, explicit, function(target, name)
        jobs.upload_file(target, rel, path, function(res)
            if res.ok then
                notify(("%s %s ➤ %s"):format(config.icons.send, rel, name))
            else
                notify(("upload failed: %s"):format(vim.trim(res.stderr)), vim.log.levels.ERROR)
            end
        end)
    end)
end

--- Download the remote copy over the current buffer's file. Overwriting a MODIFIED buffer asks
--- first (`ui.confirm`); the buffer reloads from disk after the transfer.
---@param explicit string?
function M.download(explicit)
    local root, cfg = context()
    if not (root and cfg) then
        return
    end
    local path, rel, buf = buffer_file(root)
    if not (path and rel and buf) then
        return
    end
    resolve_target(root, cfg, explicit, function(target, name)
        local function fetch()
            jobs.download_file(target, rel, path, function(res)
                if not res.ok then
                    notify(("download failed: %s"):format(vim.trim(res.stderr)), vim.log.levels.ERROR)
                    return
                end
                if api.nvim_buf_is_valid(buf) then
                    api.nvim_buf_call(buf, function()
                        vim.cmd.edit({ bang = true }) -- reload the transferred content (drops local edits by consent)
                    end)
                end
                notify(("%s %s ⬅ %s"):format(config.icons.receive, rel, name))
            end)
        end
        if vim.bo[buf].modified then
            ui.confirm({
                title = config.icons.receive .. " Overwrite modified buffer?",
                prompt = rel .. " has unsaved changes",
                default_no = true,
                callback = function(yes)
                    if yes then
                        fetch()
                    end
                end,
            })
        else
            fetch()
        end
    end)
end

--- Diff the current buffer against its remote copy (read-only scratch, `remote://target/path`).
---@param explicit string?
function M.diff(explicit)
    local root, cfg = context()
    if not (root and cfg) then
        return
    end
    local _, rel, buf = buffer_file(root)
    if not (rel and buf) then
        return
    end
    resolve_target(root, cfg, explicit, function(target, name)
        diff.open(target, name, rel, buf, function(ok, err)
            if not ok then
                notify(("diff: cannot read remote %s: %s"):format(rel, err or "?"), vim.log.levels.ERROR)
            end
        end)
    end)
end

-- ── directory sync (dry run → review panel → apply) ──────────────────────────

--- Long rsync output goes to a read-only `ui.info` viewer instead of a notification.
---@param title string
---@param res LvimRemoteJobResult
local function show_failure(title, res)
    local text = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
    if text == "" then
        text = "exit " .. res.code
    end
    ui.info(vim.split(text, "\n", { plain = true }), {
        title = config.icons.remote .. " " .. title,
        hide_cursor = true,
    })
end

--- Run a sync: rsync DRY RUN (always with `--delete`, so pending deletions surface) → parse →
--- the review panel → on apply, the REAL rsync with the same flags (`--delete` only when the
--- panel showed deletions). Nothing destructive without the panel.
---@param direction LvimRemoteDirection
---@param subdir string?
---@param explicit string?  target name
---@param layout string?    review-panel layout override (sticky for the session)
function M.sync(direction, subdir, explicit, layout)
    local root, cfg = context()
    if not (root and cfg) then
        return
    end
    if layout then
        sticky_layout = layout
    end
    resolve_target(root, cfg, explicit, function(target, name)
        local arrow = direction == "up" and "➤" or "⬅"
        notify(("dry run %s %s…"):format(arrow, name))
        jobs.rsync(
            target,
            { direction = direction, root = root, subdir = subdir, dry = true, delete = true },
            function(res)
                if not res.ok then
                    notify(("dry run against %s failed (exit %d)"):format(name, res.code), vim.log.levels.ERROR)
                    show_failure("rsync dry run — " .. name, res)
                    return
                end
                local rows = parse.itemized(res.stdout, direction)
                if #rows == 0 then
                    notify(("%s is already in sync"):format(name))
                    return
                end
                panel.review({
                    rows = rows,
                    direction = direction,
                    target_name = name,
                    subdir = subdir,
                    layout = sticky_layout,
                    on_apply = function(with_delete)
                        notify(("syncing %s %s…"):format(arrow, name))
                        jobs.rsync(
                            target,
                            { direction = direction, root = root, subdir = subdir, delete = with_delete },
                            function(rres)
                                if rres.ok then
                                    -- Report the REAL run's itemized counts (the real rsync carries
                                    -- --itemize-changes too), not the dry-run rows — the tree can
                                    -- change between review and apply. Fall back to the dry counts
                                    -- when the real output itemizes nothing.
                                    local real = parse.counts(parse.itemized(rres.stdout, direction))
                                    local c = (real.changed > 0 or real.deleted > 0) and real or parse.counts(rows)
                                    notify(
                                        ("%s %s %s: %d change(s)%s"):format(
                                            config.icons.remote,
                                            direction == "up" and "sync-up" or "sync-down",
                                            name,
                                            c.changed,
                                            with_delete and (", %d deletion(s)"):format(c.deleted) or ""
                                        )
                                    )
                                else
                                    notify(
                                        ("sync against %s failed (exit %d)"):format(name, rres.code),
                                        vim.log.levels.ERROR
                                    )
                                    show_failure("rsync — " .. name, rres)
                                end
                            end
                        )
                    end,
                })
            end
        )
    end)
end

-- ── the command ──────────────────────────────────────────────────────────────

---@type table<string, boolean>
local LAYOUTS = { float = true, area = true, bottom = true }
local SUBS = { "init", "upload", "download", "diff", "sync-up", "sync-down", "target", "watch" }

--- Classify one `:LvimRemote` token: a layout, a known target name, or a plain word (subdir /
--- watch arg). Target names come from the (already loaded) project config; nil cfg = no targets.
---@param tok string
---@param cfg LvimRemoteProjectConfig?
---@return "layout"|"target"|"word"
local function classify(tok, cfg)
    if LAYOUTS[tok] then
        return "layout"
    end
    if cfg and cfg.targets[tok] then
        return "target"
    end
    return "word"
end

--- Execute a parsed `:LvimRemote` invocation.
---@param sub string
---@param rest string[]
local function execute(sub, rest)
    if sub == "init" then
        project.scaffold()
        return
    end
    if sub == "watch" then
        local arg = rest[1]
        if arg == "on" then
            watch.enable(true)
        elseif arg == "off" then
            watch.disable(true)
        else
            watch.toggle()
        end
        return
    end
    -- The remaining subcommands live inside a project: classify their free tokens against the
    -- project's target set (loaded lazily HERE — the first project-file execution is this
    -- user-invoked command, per the no-implicit-execution rule).
    local root = project.root()
    local cfg = root and project.load(root) or nil
    local target, layout, words = nil, nil, {}
    for _, tok in ipairs(rest) do
        local kind = classify(tok, cfg)
        if kind == "layout" then
            layout = tok
        elseif kind == "target" then
            target = tok
        else
            words[#words + 1] = tok
        end
    end
    if sub == "upload" then
        M.upload(target)
    elseif sub == "download" then
        M.download(target)
    elseif sub == "diff" then
        M.diff(target)
    elseif sub == "sync-up" or sub == "sync-down" then
        M.sync(sub == "sync-up" and "up" or "down", words[1], target, layout)
    elseif sub == "target" then
        local r, c = context()
        if r and c then
            if words[1] and not c.targets[words[1]] then
                notify(("no target '%s'"):format(words[1]), vim.log.levels.ERROR)
            elseif target or words[1] then
                sticky[r] = target or words[1]
                notify("target ➤ " .. sticky[r])
            else
                M.choose_target(r, c)
            end
        end
    else
        notify(("unknown subcommand '%s'"):format(sub), vim.log.levels.WARN)
    end
end

--- Configure lvim-remote: merge `opts` into the live config, bind the theme factory and
--- register the `:LvimRemote` command. Idempotent past the first call. Nothing here reads the
--- project config — that stays lazy until the first command.
---@param opts LvimRemoteConfig?
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    if registered then
        return
    end
    registered = true
    hl.setup()
    hl.bind(highlights.build)

    api.nvim_create_user_command("LvimRemote", function(cmd)
        local toks = {}
        for tok in cmd.args:gmatch("%S+") do
            toks[#toks + 1] = tok
        end
        local sub = table.remove(toks, 1)
        if not sub then
            notify("usage: :LvimRemote " .. table.concat(SUBS, "|"), vim.log.levels.WARN)
            return
        end
        execute(sub, toks)
    end, {
        nargs = "*",
        desc = "lvim-remote: init / upload / download / diff / sync-up|sync-down [subdir] / target / watch [on|off] — [target] [float|area|bottom]",
        complete = function(_, line)
            -- First arg → the subcommands; later args → target names + layout tokens (+ watch's
            -- on/off). Completion may load the project config: it is user-driven, like a command.
            if line:match("^%s*LvimRemote%s+%S*$") then
                return SUBS
            end
            if line:match("%f[%w]watch%s+%S*$") then
                return { "on", "off", "toggle" }
            end
            local out = {}
            local root = project.root()
            local cfg = root and project.load(root) or nil
            if cfg then
                vim.list_extend(out, project.targets(cfg))
            end
            if line:match("%f[%w]sync%-") then
                vim.list_extend(out, { "float", "area", "bottom" })
            end
            return out
        end,
    })
end

return M
