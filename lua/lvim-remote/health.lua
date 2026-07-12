-- lvim-remote: :checkhealth lvim-remote.
-- Diagnoses what makes a deploy misbehave invisibly: the transfer binaries (rsync/scp/ssh), the
-- lvim-ui / lvim-utils chassis the review panel is built on, the CURRENT project's
-- `.lvim/remote.lua` (found? parses? validates? — including the hard no-plaintext-secrets rule,
-- reported as an ERROR), the watcher state, a config sanity pass, and (opt-in) each target's
-- ssh reachability. Read-only reporting — never mutates config or state, never touches a secret.
--
---@module "lvim-remote.health"

local config = require("lvim-remote.config")
local project = require("lvim-remote.project")

local M = {}

--- Validate the live plugin config; error per violation, ok when clean.
---@param health table  the vim.health reporter
local function check_config(health)
    local problems = 0
    local layouts = { float = true, area = true, bottom = true }
    if not layouts[config.layout] then
        problems = problems + 1
        health.error(("config.layout '%s' is not one of float/area/bottom"):format(tostring(config.layout)))
    end
    if type(config.debounce) ~= "number" or config.debounce < 0 then
        problems = problems + 1
        health.error("config.debounce must be a non-negative number of milliseconds")
    end
    if type(config.rsync_flags) ~= "table" then
        problems = problems + 1
        health.error("config.rsync_flags must be a list of strings")
    else
        for _, banned in ipairs({ "-n", "--dry-run", "--delete", "--itemize-changes", "-i" }) do
            if vim.tbl_contains(config.rsync_flags, banned) then
                problems = problems + 1
                health.error(
                    ("config.rsync_flags must not contain '%s' — it is managed internally (the dry-run/review contract)"):format(
                        banned
                    )
                )
            end
        end
    end
    if problems == 0 then
        health.ok("config valid")
    end
end

--- Report the current project's `.lvim/remote.lua`: existence, parse, validation (the
--- plaintext-secret scan is part of validate() and surfaces here as an error).
---@param health table
local function check_project(health)
    local root = project.root()
    if not root then
        health.info("no " .. config.config_file .. " upward of here (scaffold one with :LvimRemote init)")
        return
    end
    local path = project.config_path(root)
    health.info("project config: " .. path)
    local cfg, err = project.load(root)
    if not cfg then
        health.error(err or "project config failed to load")
        return
    end
    local names = project.targets(cfg)
    health.ok(("%d target(s): %s"):format(#names, table.concat(names, ", ")))
    if cfg.default then
        health.info("default target: " .. cfg.default)
    else
        health.info("no default target" .. (#names > 1 and " — ops with several targets open the chooser" or ""))
    end
    if cfg.upload_on_save then
        health.info("upload_on_save = true (the watcher arms on the first :LvimRemote command)")
    end
    -- Opt-in reachability probe: BatchMode + a short timeout, so an unauthenticated target
    -- fails fast (never a password prompt — there is no password flow).
    if config.health_reachability then
        local jobs = require("lvim-remote.jobs")
        for _, name in ipairs(names) do
            local ok, detail = jobs.reachable(cfg.targets[name], 3)
            if ok then
                health.ok(("target '%s' reachable over ssh"):format(name))
            else
                health.warn(("target '%s' not reachable: %s"):format(name, detail ~= "" and detail or "timeout"))
            end
        end
    else
        health.info("reachability probe is off (config.health_reachability = false)")
    end
end

--- Run the health report.
function M.check()
    local health = vim.health
    health.start("lvim-remote")

    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim >= 0.11")
    else
        health.error("Neovim >= 0.11 is required (vim.system, vim.fs.root)")
    end

    -- the transfer binaries
    for _, bin in ipairs({ config.rsync, config.scp, config.ssh }) do
        if vim.fn.executable(bin) == 1 then
            health.ok(bin .. " found")
        else
            health.error(bin .. " not executable — set config." .. bin:match("[^/]+$") .. " or install it")
        end
    end

    -- the ecosystem the panel is built on
    local ok_ui = pcall(require, "lvim-ui")
    local ok_utils = pcall(require, "lvim-utils.utils")
    if ok_ui and ok_utils then
        health.ok("lvim-ui + lvim-utils found (review panel / palette)")
    else
        health.error("lvim-ui / lvim-utils not found — the review panel cannot open")
    end
    if pcall(require, "lvim-hud.overlay") then
        health.ok("lvim-hud found — the watch chip shows in the statusline")
    else
        health.info("lvim-hud not found — no watch chip (uploads still work)")
    end

    -- auth posture: there is nothing to check BY DESIGN — no credentials exist anywhere
    health.info(
        "auth: ssh keys / ssh_config only — no password flow, no stored secrets (plaintext secrets in "
            .. config.config_file
            .. " are rejected)"
    )

    local watch = require("lvim-remote.watch")
    health.info("upload-on-save: " .. (watch.enabled() and "ON" or "off"))

    check_project(health)
    check_config(health)
end

return M
