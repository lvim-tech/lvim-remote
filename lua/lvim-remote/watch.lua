-- lvim-remote.watch: upload-on-save. One BufWritePost autocmd (installed only while enabled —
-- disabled watch costs nothing), debounced per file so a save burst coalesces into one upload.
-- A saved file uploads only when EVERY gate passes silently: the project has a config, the file
-- is under its root, it clears the target's exclusion patterns, and a target resolves without
-- asking (the session-sticky choice, the config default, or a single target) — a save must never
-- pop a chooser. While enabled, a chip shows in the statusline via the lvim-hud overlay. The
-- explicit `:LvimRemote watch on|off` always wins over the project's `upload_on_save` flag for
-- the rest of the session.
--
---@module "lvim-remote.watch"

local api = vim.api
local uv = vim.uv
local config = require("lvim-remote.config")
local project = require("lvim-remote.project")
local jobs = require("lvim-remote.jobs")

local M = {}

local AUGROUP = "LvimRemoteWatch"

---@class LvimRemoteWatchState
---@field enabled boolean
---@field user_set boolean          the user toggled explicitly (project upload_on_save no longer decides)
---@field timers table<string, uv.uv_timer_t>  per-file debounce timers (keyed by absolute path)
---@field warned table<string, boolean>        roots already warned about an unresolvable target
local state = {
    enabled = false,
    user_set = false,
    timers = {},
    warned = {},
}

---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-remote: " .. msg, level or vim.log.levels.INFO)
end

--- Whether upload-on-save is enabled.
---@return boolean
function M.enabled()
    return state.enabled
end

--- Update the lvim-hud statusline chip: shown while the watcher is enabled, cleared otherwise.
--- No-op when hud_chip is off or lvim-hud is absent (loaded lazily + guarded — cross-plugin).
local function refresh_chip()
    if not config.hud_chip then
        return
    end
    local ok, overlay = pcall(require, "lvim-hud.overlay")
    if not ok then
        return
    end
    if state.enabled then
        pcall(overlay.set, { icon = config.icons.watch, title = "remote watch" })
    else
        pcall(overlay.clear)
    end
end

--- Whether `rel` is caught by a target's exclusion patterns. This is the SAME list rsync gets as
--- `--exclude`, so the watch gate must honour the same shapes, or a target that excludes e.g.
--- `*.log` from the sync would still upload every saved `.log` file:
---   * plain entries — a whole path COMPONENT (".git", "node_modules" anywhere) or a leading path
---     PREFIX ("dist/assets");
---   * wildcard entries (`*` / `?` / `[…]`) — compiled to a regex via glob2regpat. A pattern with
---     no "/" matches a basename at ANY depth (each component tested); one with a "/" is anchored to
---     the project root (the rel path tested) — matching rsync's own anchoring rule.
---@param rel string
---@param excluded string[]?
---@return boolean
function M.excluded(rel, excluded)
    for _, pat in ipairs(excluded or {}) do
        local p = pat:gsub("/+$", "")
        if p:find("[%*%?%[]") then
            local ok, re = pcall(vim.regex, vim.fn.glob2regpat(p))
            if ok and re then
                if p:find("/") then
                    if re:match_str(rel) then
                        return true
                    end
                else
                    for comp in rel:gmatch("[^/]+") do
                        if re:match_str(comp) then
                            return true
                        end
                    end
                end
            end
        elseif rel == p or rel:sub(1, #p + 1) == p .. "/" then
            return true
        else
            for comp in rel:gmatch("[^/]+") do
                if comp == p then
                    return true
                end
            end
        end
    end
    return false
end

--- Resolve the target a save uploads to, SILENTLY (never a chooser): the session-sticky choice
--- (init.lua records it per root), else the config default, else a single target. nil + a
--- once-per-root warning otherwise.
---@param root string
---@param cfg LvimRemoteProjectConfig
---@return LvimRemoteTarget? target, string? name
local function silent_target(root, cfg)
    -- inline require: init owns the sticky-target session state; circular at load time
    local sticky = require("lvim-remote").sticky_target(root)
    local name = (sticky and cfg.targets[sticky] and sticky) or cfg.default
    if not name then
        local names = project.targets(cfg)
        if #names == 1 then
            name = names[1]
        end
    end
    if not name then
        if not state.warned[root] then
            state.warned[root] = true
            notify("watch: several targets and no default — pick one with :LvimRemote target", vim.log.levels.WARN)
        end
        return nil
    end
    return cfg.targets[name], name
end

--- Upload one saved file (the debounced leaf).
---@param path string  absolute file path
local function upload(path)
    local root = project.root(path)
    if not root then
        return
    end
    local cfg = project.load(root)
    if not cfg then
        return -- an invalid config already notified on the command path; a save stays silent
    end
    local rel = path:sub(#root + 2)
    local target, name = silent_target(root, cfg)
    if not target or M.excluded(rel, target.excluded) then
        return
    end
    jobs.upload_file(target, rel, path, function(res)
        if res.ok then
            if config.watch_notify then
                notify(("%s ➤ %s"):format(rel, name))
            end
        else
            notify(
                ("watch: upload of %s to %s failed: %s"):format(rel, name, vim.trim(res.stderr)),
                vim.log.levels.ERROR
            )
        end
    end)
end

--- The BufWritePost handler: debounce per file, then upload.
---@param path string
local function on_save(path)
    local t = state.timers[path]
    if t then
        t:stop()
    else
        local nt = uv.new_timer()
        if not nt then
            return
        end
        t = nt
        state.timers[path] = t
    end
    t:start(
        config.debounce,
        0,
        vim.schedule_wrap(function()
            local timer = state.timers[path]
            -- Coalescing guard: this expiry was queued (schedule_wrap) before it ran; if a save in
            -- that gap re-armed the timer (`on_save` did stop()+start()), it is active again — this
            -- STALE expiry must not steal its pending upload or close the freshly re-armed timer.
            -- Let the re-armed timer's own expiry do the work.
            if timer and timer:is_active() then
                return
            end
            if timer then
                timer:stop()
                timer:close()
                state.timers[path] = nil
            end
            if state.enabled then
                upload(path)
            end
        end)
    )
end

--- Enable upload-on-save (installs the autocmd; idempotent).
---@param user boolean?  true when the user toggled explicitly (wins over project upload_on_save)
function M.enable(user)
    if user then
        state.user_set = true
    end
    if state.enabled then
        return
    end
    state.enabled = true
    api.nvim_create_autocmd("BufWritePost", {
        group = api.nvim_create_augroup(AUGROUP, { clear = true }),
        callback = function(ev)
            local path = api.nvim_buf_get_name(ev.buf)
            if path ~= "" and vim.bo[ev.buf].buftype == "" then
                on_save(vim.fs.normalize(path))
            end
        end,
    })
    refresh_chip()
    notify("watch on — saves upload (debounced)")
end

--- Disable upload-on-save (drops the autocmd and every pending debounce).
---@param user boolean?
function M.disable(user)
    if user then
        state.user_set = true
    end
    if not state.enabled then
        return
    end
    state.enabled = false
    pcall(api.nvim_del_augroup_by_name, AUGROUP)
    for path, t in pairs(state.timers) do
        t:stop()
        t:close()
        state.timers[path] = nil
    end
    refresh_chip()
    notify("watch off")
end

--- Toggle upload-on-save (an explicit user action).
function M.toggle()
    if state.enabled then
        M.disable(true)
    else
        M.enable(true)
    end
end

--- Honour a freshly loaded project config's `upload_on_save = true` — but never override an
--- explicit user toggle, and never as an implicit BufEnter side effect (init calls this only on
--- a user-invoked command, after the lazy first load).
---@param cfg LvimRemoteProjectConfig
function M.maybe_enable(cfg)
    if cfg.upload_on_save and not state.user_set then
        M.enable(false)
    end
end

return M
