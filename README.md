# lvim-remote

Deploy and sync a project to remote machines over ssh — the deployment plugin of the lvim-tech
set. Targets live in a per-project `.lvim/remote.lua`; the current buffer can be uploaded,
downloaded, or diffed against its remote copy; whole trees sync with rsync in **both
directions**, and **every sync runs as a dry run first**: the itemized changes open in a review
panel, and nothing destructive executes until you apply exactly what you reviewed.

- **Per-project config** — `.lvim/remote.lua` at the project root (pure data: it is loaded in an
  empty Lua environment, so nothing in it can execute code — and only lazily, on the first
  `:LvimRemote` command, never on `BufEnter`). `:LvimRemote init` scaffolds it.
- **File ops** (current buffer) — `upload` (the saved disk file), `download` (asks before
  overwriting a modified buffer), `diff` (fetches the remote copy over ssh into a read-only
  `remote://target/path` scratch and diffs it in a vertical split — closing the scratch ends the
  session).
- **Directory sync** — `sync-up` / `sync-down [subdir]` runs `rsync` as an itemized **dry run**
  first and opens the **review panel**: one row per pending change with an op badge
  (send / receive / delete accents), a `[c]hanged / [d]eleted / [a]ll` filter bar with live
  counts, and a `[y] apply · [q] cancel` footer. Apply executes the SAME rsync for real;
  `--delete` is passed **only when the panel showed the deletions**.
- **Targets** — several targets → a themed chooser (`:LvimRemote target`); the pick is sticky for
  the session; `default` in the project config skips the chooser.
- **Upload on save** — `:LvimRemote watch on|off` (or `upload_on_save = true` in the project
  config): saved project files upload debounced, filtered by the target's `excluded` patterns. A
  watch chip shows in the statusline (lvim-hud) while enabled. A save never opens a chooser — with
  several targets and no default it warns once instead.
- **Auth is ssh's business — no passwords, ever.** lvim-remote has **no password flow**: use ssh
  keys / an ssh agent / `~/.ssh/config` aliases. No secret is stored, prompted for, logged, or
  put on a command line — and a plaintext-secret-looking field (`password`, `sshpass`, `token`,
  …) in `.lvim/remote.lua` makes the whole config **invalid** (`:checkhealth lvim-remote` reports
  it as an error).

## Requirements

- Neovim >= 0.11 (`vim.system`, `vim.fs.root`)
- `rsync`, `ssh`, `scp` on the PATH (or absolute paths in the config)
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) (palette / merge)
- [lvim-ui](https://github.com/lvim-tech/lvim-ui) (the review panel + choosers)
- Optional: [lvim-hud](https://github.com/lvim-tech/lvim-hud) for the watch statusline chip

## Installation

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and install /
update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin
manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-remote" },
})
require("lvim-remote").setup({})
```

## Usage

```vim
:LvimRemote init                 " scaffold .lvim/remote.lua at the project root and open it
:LvimRemote upload [target]      " upload the current buffer's file (must be saved)
:LvimRemote download [target]    " download the remote copy (confirms over a modified buffer)
:LvimRemote diff [target]        " diff the buffer against its remote copy (remote://… scratch)
:LvimRemote sync-up [subdir] [target] [float|area|bottom]
                                 " dry run ➤ review panel ➤ apply (local ➤ remote)
:LvimRemote sync-down [subdir] [target] [float|area|bottom]
                                 " dry run ➤ review panel ➤ apply (remote ➤ local)
:LvimRemote target [name]        " choose / set the session-sticky target
:LvimRemote watch [on|off]       " toggle upload-on-save (no arg = toggle)
```

A `float|area|bottom` token is recognised anywhere in a sync's arguments and is sticky for the
session; a token matching a target name selects that target (and makes it sticky).

### Review panel keys

| Key             | Action                                                    |
| --------------- | --------------------------------------------------------- |
| `j` / `k`       | move between change rows                                  |
| `y`             | apply — run the real rsync exactly as reviewed            |
| `q` / `<Esc>`   | cancel — nothing runs                                     |
| `<C-j>` / `<C-k>` | move between sectors (filter bar · list · footer)       |

## Project config — `.lvim/remote.lua`

```lua
-- PURE DATA, no code (loaded in an empty environment, so function calls fail).
-- Auth is entirely ssh's business: use ssh keys / ssh_config aliases.
-- NEVER put a password here — lvim-remote refuses plaintext secrets.
return {
    targets = {
        production = {
            host = "myserver", -- ssh alias (preferred) or user@host
            path = "/var/www/app", -- absolute remote project root
            excluded = { ".git", "node_modules", ".env" },
            port = nil, -- optional; else ssh_config decides
        },
    },
    default = "production",
    upload_on_save = false,
}
```

The project root is the nearest ancestor directory containing `.lvim/remote.lua`. `excluded`
entries are rsync `--exclude` patterns; the save watcher applies them too (matched as whole path
components or leading prefixes). An edited file is re-read on the next command (mtime-checked) —
no reload step.

## Setup

The full default configuration (every option at its default):

```lua
require("lvim-remote").setup({
    -- Executables (names on PATH or absolute paths).
    rsync = "rsync",
    scp = "scp",
    ssh = "ssh",
    -- Base rsync flags for every sync (dry AND real). `--itemize-changes`, `-n` and
    -- `--delete` are managed internally and must not be listed here.
    rsync_flags = { "-a", "-z", "-s" },
    -- The per-project config path, relative to the project root.
    config_file = ".lvim/remote.lua",
    -- Review panel: layout (a float|area|bottom token on the command overrides it,
    -- sticky for the session), title and title alignment.
    layout = "float",
    title = "Remote",
    title_pos = "left",
    -- Upload-on-save debounce per file (ms).
    debounce = 500,
    -- Statusline watch chip (lvim-hud overlay) while upload-on-save is enabled.
    hud_chip = true,
    -- Notify on every successful watched upload (failures always notify).
    watch_notify = false,
    -- :checkhealth probes each target over ssh (BatchMode, 3s timeout) — opt-in.
    health_reachability = false,
    -- Nerd Font single-width glyphs.
    icons = {
        remote = "󰒍",
        send = "󰕒",
        receive = "󰇚",
        delete = "󰆴",
        target = "󰓾",
        diff = "",
        watch = "",
    },
    -- Op accents: lvim-utils palette keys (track the live theme) or "#rrggbb".
    colors = {
        send = "green",
        receive = "blue",
        delete = "red",
    },
})
```

## Safety model

- **Nothing destructive without the panel.** Every `sync-up` / `sync-down` dry-runs first
  (always with `--delete`, so pending deletions surface in the list); the real run only executes
  from the panel's apply, with the same flags — and `--delete` only when deletions were shown.
- **`download` over a modified buffer asks first** (a themed confirm).
- **List-form argv everywhere** (`vim.system`) — no local shells; the scp/ssh remote path is
  shell-escaped, rsync gets `-s` (secluded args).
- **No secrets.** No password flow exists; a failing target surfaces ssh's own message. Plaintext
  secret fields in the project config are rejected outright.

## Highlights

Self-themed from the lvim-utils palette (rebuilt on ColorScheme / palette sync); accents from
`colors`:

- `LvimRemoteSendBadge` / `LvimRemoteReceiveBadge` / `LvimRemoteDeleteBadge` — the row op badges
- `LvimRemoteSendName` / `LvimRemoteReceiveName` / `LvimRemoteDeleteName` — the path cells
- `LvimRemoteDim`, `LvimRemoteEmpty`

## Health

`:checkhealth lvim-remote` — Neovim baseline, the rsync/scp/ssh binaries, the lvim-ui/lvim-utils
chassis, the current project's config (parse + validation, including the no-plaintext-secrets
rule), the watcher state, a config sanity pass, and (opt-in) per-target ssh reachability.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
