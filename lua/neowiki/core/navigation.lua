local ui = require("neowiki.core.ui")
local state = require("neowiki.state")

local M = {}

---
-- Adds a new path to the navigation history.
-- This function handles truncation of "forward" history if a new path is
-- visited after navigating back.
-- @param path (string): The absolute path of the page to add to the history.
M.add_to_history = function(path)
  if not path or path == "" then
    return
  end

  -- If the cursor is pointing to the same path, do nothing.
  if state.history_cursor > 0 and state.navigation_history[state.history_cursor] == path then
    return
  end

  -- If we've navigated back and are now opening a new link,
  -- truncate the "forward" part of the history.
  if state.history_cursor > 0 and state.history_cursor < #state.navigation_history then
    state.navigation_history = vim.list_slice(state.navigation_history, 1, state.history_cursor)
  end

  table.insert(state.navigation_history, path)
  state.history_cursor = #state.navigation_history
end

---
-- Opens a file at a given path. If the file is already open in a window,
-- it jumps to that window. Otherwise, it opens the file in the current window
-- or via a specified command (e.g., 'vsplit').
-- @param full_path (string): The absolute path to the file.
-- @param open_cmd (string|nil): Optional vim command to open the file (e.g., "vsplit", "tabnew", "float").
M.open_file = function(full_path, open_cmd)
  local abs_path = vim.fn.fnamemodify(full_path, ":p")
  local buffer_number = vim.fn.bufnr(abs_path, true)

  if open_cmd == "float" then
    -- reusing the existing floating window for new file
    ui.open_file_in_float(buffer_number)
    return
  end

  -- If buffer is already open and visible, jump to its window.
  if buffer_number ~= -1 then
    local win_nr = vim.fn.bufwinnr(buffer_number)
    if win_nr ~= -1 then
      local win_id = vim.fn.win_getid(win_nr)
      vim.api.nvim_set_current_win(win_id)
      return
    end
  end

  -- Open the file using the specified command or in the current window.
  if open_cmd and type(open_cmd) == "string" and #open_cmd > 0 then
    vim.cmd(open_cmd .. " " .. vim.fn.fnameescape(full_path))
  else
    local bn_to_open = vim.fn.bufnr(full_path, true)
    vim.api.nvim_win_set_buf(0, bn_to_open)
  end
end

return M
