-- lvim-remote.panel: the dry-run review — the ONE gate every destructive sync passes through.
-- One `lvim-ui.tabs` menu tab over the parsed itemize rows: each pending change is a row with an
-- op badge (send/receive/delete accents), the path in its op colour and the raw itemize cell dim
-- at the right edge. A filter bar (the shared lvim-ui.filters group model) narrows to
-- [c]hanged / [d]eleted / [a]ll with live counts; the border counter shows shown/total. The
-- footer is the contract: [y] APPLIES exactly what was reviewed (the caller receives whether
-- deletions were shown, and only then may pass `--delete` to the real run), [q]/<Esc> cancels —
-- the callback resolves exactly once either way. The chassis owns every window/band/sector; this
-- module renders rows and returns the decision.
--
---@module "lvim-remote.panel"

local config = require("lvim-remote.config")
local parse = require("lvim-remote.parse")
local ui = require("lvim-ui")
local ui_filters = require("lvim-ui.filters")

local M = {}

---@class LvimRemoteReviewOpts
---@field rows LvimRemoteChange[]      the parsed dry-run rows (non-empty)
---@field direction LvimRemoteDirection
---@field target_name string           the chosen target's name (title)
---@field subdir string?               the synced subtree (title suffix)
---@field layout string?               per-open layout override (session-sticky is the caller's)
---@field on_apply fun(with_delete: boolean)  the user applied; with_delete = deletions were shown
---@field on_cancel fun()?             the user cancelled / closed

---@class LvimRemotePanelState
---@field handle table?   the live ui.tabs handle
---@field tabs table[]?   the tab specs (rows mutated in place, seen by recalc)
---@field filter string   active filter id ("all"|"changed"|"deleted")
local state = {
    filter = "all",
}

--- Whether the review panel is currently open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.valid ~= nil and state.handle.valid()
end

--- Close the panel programmatically (fires the cancel path unless apply already ran).
function M.close()
    if M.is_open() then
        state.handle.close()
    end
end

-- ── row building ─────────────────────────────────────────────────────────────

--- Whether a change row passes the active filter.
---@param row LvimRemoteChange
---@param filter string
---@return boolean
local function matches(row, filter)
    if filter == "all" then
        return true
    end
    if filter == "deleted" then
        return row.op == "delete"
    end
    return row.op ~= "delete"
end

--- Op → badge glyph + highlight group suffix.
---@param op LvimRemoteOp
---@return string glyph, string suffix
local function badge(op)
    if op == "delete" then
        return config.icons.delete, "Delete"
    elseif op == "receive" then
        return config.icons.receive, "Receive"
    end
    return config.icons.send, "Send"
end

--- One change row: op badge + path (op accent) + the raw itemize cell dim on the right. A menu
--- row with no `run` — the panel is a review, not a per-row action list; the decision is the
--- footer's.
---@param row LvimRemoteChange
---@param i integer
---@return table
local function change_row(row, i)
    local glyph, sfx = badge(row.op)
    return {
        type = "action",
        name = ("change_%d"):format(i),
        flat = true,
        tight = true,
        icon = " " .. glyph .. " ",
        icon_hl = "LvimRemote" .. sfx .. "Badge",
        -- a trailing "/" marks a directory row (rsync already prints dirs with one)
        label = " " .. row.path .. ((row.kind == "dir" and not row.path:find("/$")) and "/" or ""),
        text_hl = "LvimRemote" .. sfx .. "Name",
        suffix = row.flags,
        suffix_hl = "LvimRemoteDim",
        run = function() end, -- selectable (j/k navigable) but inert: apply/cancel live in the footer
    }
end

--- The filter bar — the shared lvim-ui filter-group model, one group with live counts. The
--- button accents mirror the row accents: changed = the transfer colour, deleted = red.
---@param rows LvimRemoteChange[]
---@param refresh fun()
---@return table  a `type="bar"` row
local function filter_bar(rows, refresh)
    local buttons = {
        { id = "changed", label = "Changed" },
        { id = "deleted", label = "Deleted" },
        { id = "all", label = "All" },
    }
    local fb = ui_filters.bar({ { id = "ops", active = state.filter, buttons = buttons } }, {
        count = function(_, b)
            local n = 0
            for _, r in ipairs(rows) do
                if matches(r, b.id) then
                    n = n + 1
                end
            end
            return n
        end,
        on_select = function(_, id)
            state.filter = id
            refresh()
        end,
    })
    return { type = "bar", name = "filter", align = "center", items = fb.band.items }
end

--- Build the tab's rows from the parsed changes + the active filter.
---@param rows LvimRemoteChange[]
---@param refresh fun()
---@return table[]
local function build_rows(rows, refresh)
    local out = { filter_bar(rows, refresh) }
    local shown = 0
    for i, r in ipairs(rows) do
        if matches(r, state.filter) then
            shown = shown + 1
            out[#out + 1] = change_row(r, i)
        end
    end
    if shown == 0 then
        out[#out + 1] = {
            type = "spacer",
            name = "empty",
            label = "No pending changes match this filter",
            hl = { inactive = "LvimRemoteEmpty" },
        }
    end
    return out
end

--- How many rows the active filter shows (the border counter's "current").
---@param rows LvimRemoteChange[]
---@return integer
local function shown_count(rows)
    local n = 0
    for _, r in ipairs(rows) do
        if matches(r, state.filter) then
            n = n + 1
        end
    end
    return n
end

-- ── open ─────────────────────────────────────────────────────────────────────

--- Open the review panel over a dry run's parsed rows. `on_apply(with_delete)` fires exactly
--- once when the user confirms; `on_cancel` when they close without applying. `with_delete` is
--- true only when the dry run LISTED deletions — the caller's licence for the real `--delete`.
---@param opts LvimRemoteReviewOpts
function M.review(opts)
    if M.is_open() then
        state.handle.close()
        state.handle = nil
    end
    state.filter = "all" -- every review starts unfiltered: deletions are always shown first
    local rows = opts.rows or {}
    local counts = parse.counts(rows)
    local applied = false

    local function refresh()
        if not M.is_open() then
            return
        end
        state.tabs[1].rows = build_rows(rows, refresh)
        local idx = state.handle.cursor_index()
        state.handle.recalc()
        state.handle.focus_index(idx)
    end

    local arrow = opts.direction == "up" and "sync-up" or "sync-down"
    local scope = opts.subdir and opts.subdir ~= "" and (" ➤ " .. opts.subdir) or ""
    local title = ("%s %s ➤ %s%s"):format(config.title, arrow, opts.target_name, scope)

    local function apply(st)
        applied = true
        st.close()
        -- `--delete` is licensed ONLY by deletions having been in the reviewed list.
        opts.on_apply(counts.deleted > 0)
    end

    state.tabs = {
        {
            label = title,
            icon = config.icons.remote,
            menu = true,
            rows = build_rows(rows, refresh),
            footer = {
                { key = "y", label = "apply", run = apply },
                { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } },
                {
                    key = "q/Esc",
                    label = "cancel",
                    no_hotkey = true, -- q/<Esc> are the chassis close keys; this chip is a clickable legend
                    run = function(st)
                        st.close()
                    end,
                },
            },
        },
    }
    state.handle = ui.tabs({
        title = { icon = config.icons.remote, text = title },
        title_pos = config.title_pos,
        title_count = function()
            return { current = shown_count(rows), total = counts.total }
        end,
        tabs = state.tabs,
        layout = opts.layout or config.layout,
        pad = 0, -- the badges carry their own gutter; the list sits flush
        cursorline_hl = "LvimUiCursorLine",
        callback = function()
            state.handle = nil
            state.tabs = nil
            if not applied and opts.on_cancel then
                opts.on_cancel()
            end
        end,
    })
end

return M
