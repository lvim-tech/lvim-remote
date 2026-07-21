-- lvim-remote: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it IN PLACE (via
-- lvim-utils.utils.merge), so every require("lvim-remote.config") reader sees the effective
-- values. Auth is deliberately ABSENT from this table: it is entirely ssh's business (keys /
-- ssh_config aliases) — lvim-remote never stores, prompts for, or passes secrets.
--
---@module "lvim-remote.config"

---@class LvimRemoteIcons
---@field remote string   the plugin lead glyph (panel title, notifications)
---@field send string     an upload / sent row badge
---@field receive string  a download / received row badge
---@field delete string   a pending-deletion row badge
---@field target string   the target chooser rows
---@field diff string     the remote-diff scratch title
---@field watch string    the upload-on-save hud chip

---@class LvimRemoteConfig
---@field rsync string           rsync executable (name on PATH or an absolute path)
---@field scp string             scp executable (single-file upload / download)
---@field ssh string             ssh executable (remote cat for the diff view)
---@field rsync_flags string[]   base rsync flags for every sync (dry AND real; -i/-n are added internally)
---@field config_file string     the per-project config path, relative to the project root
---@field layout "float"|"area"|"bottom"  default review-panel layout
---@field title string           review-panel title text
---@field title_pos "left"|"center"|"right"  review-panel title alignment
---@field debounce integer       upload-on-save debounce per file (ms)
---@field hud_chip boolean       show a watch chip in the statusline (lvim-hud overlay) while upload-on-save is on
---@field watch_notify boolean   notify on every successful upload-on-save transfer (errors always notify)
---@field health_reachability boolean  :checkhealth also probes each target over ssh (BatchMode, short timeout)
---@field icons LvimRemoteIcons  Nerd Font single-width glyphs
---@field colors table<string, string>  op accents (lvim-utils palette keys or "#rrggbb")

---@type LvimRemoteConfig
return {
    -- Executables. Names resolved on PATH, or absolute paths. rsync drives the directory syncs,
    -- scp the single-file upload/download, ssh the remote read for the diff view.
    rsync = "rsync",
    scp = "scp",
    ssh = "ssh",
    -- Base rsync flags shared by the dry run and the real run. `--itemize-changes` (the review
    -- rows), `-n` (dry), `--delete` (only after the panel showed the deletions) are added
    -- internally and must not be listed here.
    rsync_flags = { "-a", "-z", "-s" },
    -- The per-project deployment config, relative to the project root. Pure data (loaded in an
    -- empty environment — no function calls run), never executed implicitly on BufEnter.
    config_file = ".lvim/remote/config.lua",
    -- Where the dry-run review panel opens. Resolved per-command (a float|area|bottom token
    -- anywhere in the args, sticky for the session) → this default.
    layout = "float",
    -- Review-panel border/overlay title (the chassis places it per layout) and its alignment.
    title = "Remote",
    title_pos = "left",
    -- Upload-on-save: how long a file's saves are coalesced before the upload fires (ms).
    debounce = 500,
    -- A compact watch chip in the statusline (lvim-hud overlay) while upload-on-save is enabled.
    hud_chip = true,
    -- Notify on every successful watched upload (off = silent success; failures always notify).
    watch_notify = false,
    -- :checkhealth probes each target with `ssh -o BatchMode=yes -o ConnectTimeout=3 <host> true`
    -- (opt-in — it costs a network round-trip per target).
    health_reachability = false,
    -- Nerd Font single-width glyphs (real glyphs in the source; verified single-width).
    icons = {
        remote = "󰒍", -- nf-md-server_network
        send = "󰕒", -- nf-md-upload
        receive = "󰇚", -- nf-md-download
        delete = "󰆴", -- nf-md-delete
        target = "󰓾", -- nf-md-target
        diff = "", -- nf-fa-exchange
        watch = "", -- nf-fa-eye
    },
    -- Op accents: lvim-utils palette keys (track the live theme) or literal "#rrggbb".
    colors = {
        send = "green",
        receive = "blue",
        delete = "red",
    },
}
