-- lvim-remote.parse: rsync `--itemize-changes` output → review rows. Pure string work, no IO —
-- the dry run's stdout comes in, `{ op, kind, path, flags }` rows come out, and the review panel
-- renders exactly those. The itemize grammar (`YXcstpoguax path`): Y is the update type — `<`/`>`
-- a transfer, `c` created on the receiver, `h` hardlink, `.` attributes only (no content — noise
-- for a deploy review, skipped), `*` a message word (`*deleting`). Y's arrow points at the
-- DESTINATION side, so the op is derived from the sync DIRECTION (up = every transfer is a send,
-- down = a receive), never from the arrow itself. X is the file kind (f/d/L/D/S). Both the dry
-- and the real run use the same flags, so what parsed here is what apply transfers.
--
---@module "lvim-remote.parse"

local M = {}

---@alias LvimRemoteOp "send"|"receive"|"delete"

---@class LvimRemoteChange
---@field op LvimRemoteOp  what apply will do to this path
---@field kind "file"|"dir"|"link"|"other"
---@field path string      destination-relative path (as rsync printed it)
---@field flags string     the raw itemize cell (shown dim in the review row)

-- Itemize kind char → row kind.
---@type table<string, string>
local KINDS = { f = "file", d = "dir", L = "link" }

--- Parse itemized dry-run output into review rows. Lines that are not itemize records (rsync
--- banners, blank lines) and pure attribute updates (`.` — timestamps/perms, no content) are
--- dropped; the top-level `./` record is noise too.
---@param output string|string[]  rsync stdout (raw or already split)
---@param direction LvimRemoteDirection  "up" = transfers are sends, "down" = receives
---@return LvimRemoteChange[] rows
function M.itemized(output, direction)
    ---@type string[]
    local lines
    if type(output) == "string" then
        lines = vim.split(output, "\n", { plain = true })
    else
        lines = output
    end
    local op = direction == "up" and "send" or "receive"
    local rows = {}
    for _, line in ipairs(lines) do
        if line ~= "" then
            local del = line:match("^%*deleting%s+(.+)$")
            if del then
                rows[#rows + 1] = { op = "delete", kind = "other", path = del, flags = "*deleting" }
            else
                local flags, path = line:match("^([<>ch.][fdLDS]%S*)%s(.+)$")
                if flags and path ~= "./" then
                    local y = flags:sub(1, 1)
                    if y ~= "." then
                        rows[#rows + 1] = {
                            op = op,
                            kind = KINDS[flags:sub(2, 2)] or "other",
                            path = path,
                            flags = flags,
                        }
                    end
                end
            end
        end
    end
    return rows
end

--- Row counts for the filter bar / the apply decision.
---@param rows LvimRemoteChange[]
---@return { changed: integer, deleted: integer, total: integer }
function M.counts(rows)
    local changed, deleted = 0, 0
    for _, r in ipairs(rows) do
        if r.op == "delete" then
            deleted = deleted + 1
        else
            changed = changed + 1
        end
    end
    return { changed = changed, deleted = deleted, total = changed + deleted }
end

return M
