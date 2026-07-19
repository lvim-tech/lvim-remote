-- lvim-remote.diff: the remote diff view — fetch the remote copy of the current file (over ssh,
-- to memory; nothing touches the local file) and diff the buffer against it in a vertical split.
-- The remote side is a READ-ONLY scratch buffer named `remote://<target>/<path>` (bufhidden=wipe
-- — closing it is the whole cleanup: a BufWipeout autocmd turns diff mode off in the local
-- window again). One diff session per local buffer; re-running replaces the previous scratch.
--
---@module "lvim-remote.diff"

local api = vim.api
local jobs = require("lvim-remote.jobs")

local M = {}

--- Open (or refresh) the diff of `buf` against its remote copy.
---@param target LvimRemoteTarget
---@param target_name string
---@param rel string     project-relative file path
---@param buf integer    the local buffer
---@param cb fun(ok: boolean, err: string?)?  optional completion callback (tests / notify)
function M.open(target, target_name, rel, buf, cb)
    jobs.remote_cat(target, rel, function(res)
        if not res.ok then
            if cb then
                cb(false, vim.trim(res.stderr ~= "" and res.stderr or ("exit " .. res.code)))
            end
            return
        end
        if not api.nvim_buf_is_valid(buf) then
            if cb then
                cb(false, "the local buffer is gone")
            end
            return
        end
        local name = ("remote://%s/%s"):format(target_name, rel)
        -- Re-running the diff for the same file replaces the previous scratch (same name).
        local old = vim.fn.bufnr("^" .. vim.fn.escape(name, "\\^$.*~[]") .. "$")
        if old ~= -1 then
            pcall(api.nvim_buf_delete, old, { force = true })
        end

        local scratch = api.nvim_create_buf(false, true)
        local lines = vim.split(res.stdout, "\n", { plain = true })
        -- `cat` output ends with the file's final newline → one trailing empty split element;
        -- dropping it keeps the buffer's line count identical to the remote file's.
        if lines[#lines] == "" then
            lines[#lines] = nil
        end
        api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
        api.nvim_buf_set_name(scratch, name)
        vim.bo[scratch].buftype = "nofile"
        vim.bo[scratch].bufhidden = "wipe"
        vim.bo[scratch].swapfile = false
        vim.bo[scratch].modifiable = false
        vim.bo[scratch].filetype = vim.bo[buf].filetype -- same syntax as the local side

        -- Find a window that STILL shows `buf`. The ssh callback is scheduled arbitrarily later, so
        -- the window the command ran from may no longer be current (the user could have `<C-w>w`'d
        -- away while `ssh cat` was in flight). Forcing the local buffer into whatever window is now
        -- current would clobber it (a panel / float / another file view). Prefer a window showing
        -- `buf` in the current tabpage; only when NONE shows it do we fall back to the current window
        -- and load it there.
        local local_win
        local cur_tab = api.nvim_get_current_tabpage()
        for _, w in ipairs(vim.fn.win_findbuf(buf)) do
            if api.nvim_win_is_valid(w) then
                if api.nvim_win_get_tabpage(w) == cur_tab then
                    local_win = w
                    break
                end
                local_win = local_win or w
            end
        end
        if not local_win then
            local_win = api.nvim_get_current_win()
            api.nvim_win_set_buf(local_win, buf)
        end

        -- Diff the local side against the scratch in a fresh vsplit, and undo the local diff mode
        -- when the scratch dies.
        api.nvim_set_current_win(local_win)
        vim.cmd.diffthis()
        vim.cmd.vsplit()
        local remote_win = api.nvim_get_current_win()
        api.nvim_win_set_buf(remote_win, scratch)
        vim.cmd.diffthis()

        api.nvim_create_autocmd("BufWipeout", {
            buffer = scratch,
            once = true,
            callback = function()
                if api.nvim_win_is_valid(local_win) and api.nvim_win_get_buf(local_win) == buf then
                    api.nvim_win_call(local_win, function()
                        vim.cmd.diffoff()
                    end)
                end
            end,
        })
        if cb then
            cb(true)
        end
    end)
end

return M
