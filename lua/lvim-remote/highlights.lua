-- lvim-remote.highlights: the review panel's op accents, self-themed from the lvim-utils
-- palette. One accent per operation (send/receive/delete, from config.colors), the lead badge a
-- tint of its accent toward the editor bg (the shared "mtint" convention), so the rows track the
-- live theme. build() is bound via lvim-utils.highlight.bind in setup(), re-derived on
-- ColorScheme / palette sync.
--
---@module "lvim-remote.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")
local config = require("lvim-remote.config")

local M = {}

--- Blend an accent toward the editor bg (the shared "mtint" convention).
---@param accent string
---@param t number
---@return string
local function mtint(accent, t)
    return hl.blend(accent, c.bg, t)
end

--- Resolve a `config.colors` value to a real colour: a palette KEY (`c[key]`, tracks the live
--- theme) or, when it is not a palette field, the value itself (a literal "#rrggbb").
---@param key string
---@return string
local function accent(key)
    local v = c[key]
    return type(v) == "string" and v or key
end

--- The lvim-remote highlight groups from the live palette + `config.colors`.
---@return table<string, table>
function M.build()
    local send = accent(config.colors.send)
    local receive = accent(config.colors.receive)
    local delete = accent(config.colors.delete)
    return {
        -- lead badges (the row's op icon box) — fg = the op accent on its own soft tint
        LvimRemoteSendBadge = { fg = send, bg = mtint(send, 0.3), bold = true },
        LvimRemoteReceiveBadge = { fg = receive, bg = mtint(receive, 0.3), bold = true },
        LvimRemoteDeleteBadge = { fg = delete, bg = mtint(delete, 0.3), bold = true },
        -- the path cell, painted per op (the primary text reads in the row's accent)
        LvimRemoteSendName = { fg = send },
        LvimRemoteReceiveName = { fg = receive },
        LvimRemoteDeleteName = { fg = delete },
        -- row text zones
        LvimRemoteDim = { fg = mtint(c.fg, 0.6) },
        LvimRemoteEmpty = { fg = mtint(c.fg, 0.5), italic = true },
    }
end

return M
