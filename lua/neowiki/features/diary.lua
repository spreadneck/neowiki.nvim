local util = require("neowiki.util")
local finder = require("neowiki.core.finder")
local config = require("neowiki.config")
local state = require("neowiki.state")
local actions = require("neowiki.core.actions")

local M = {}

---
-- Adds a new path to the navigation history.
-- Mirrors the logic from core.actions to keep history consistent.
-- @param path (string) The absolute path to add to history.
--
local function add_to_history(path)
  if not path or path == "" then
    return
  end

  if state.history_cursor > 0 and state.navigation_history[state.history_cursor] == path then
    return
  end

  if state.history_cursor > 0 and state.history_cursor < #state.navigation_history then
    state.navigation_history = vim.list_slice(state.navigation_history, 1, state.history_cursor)
  end

  table.insert(state.navigation_history, path)
  state.history_cursor = #state.navigation_history
end

---
-- Opens a file in the current window or jumps to an existing window if loaded.
-- @param full_path (string) Absolute path of the file to open.
--
local function open_file(full_path)
  local abs_path = vim.fn.fnamemodify(full_path, ":p")
  local buf = vim.fn.bufnr(abs_path, true)

  local win_nr = vim.fn.bufwinnr(buf)
  if win_nr ~= -1 then
    local win_id = vim.fn.win_getid(win_nr)
    vim.api.nvim_set_current_win(win_id)
  else
    vim.api.nvim_win_set_buf(0, buf)
  end
end

---
-- Resolves and ensures the diary directory for the current wiki.
-- @return string|nil The absolute path to the diary directory or nil if outside a wiki.
--
local function get_diary_dir()
  if not actions.check_in_neowiki() then
    return nil
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local active_wiki_path = vim.b[bufnr].active_wiki_path
  if not active_wiki_path then
    return nil
  end
  local diary_dir = util.join_path(active_wiki_path, "diary")
  util.ensure_path_exists(diary_dir)
  return diary_dir
end

---
-- Opens today's diary entry in the current wiki.
-- Ensures the diary directory exists, creates today's file if needed,
-- then opens it and records it in the navigation history.
--
M.open_today = function()
  local diary_dir = get_diary_dir()
  if not diary_dir then
    return
  end

  local today = os.date("%Y-%m-%d")
  local ext = state.markdown_extension or ".md"
  local diary_path = util.join_path(diary_dir, today .. ext)

  if vim.fn.filereadable(diary_path) == 0 then
    local ok, err = pcall(function()
      local f = assert(io.open(diary_path, "w"), "Failed to create diary file.")
      f:close()
    end)
    if not ok then
      vim.notify("Error creating diary file: " .. err, vim.log.levels.ERROR, { title = "neowiki" })
      return
    end
  end

  add_to_history(diary_path)
  open_file(diary_path)
end

---
-- Opens or creates the diary index file.
--
M.open_index = function()
  local diary_dir = get_diary_dir()
  if not diary_dir then
    return
  end

  local index_path = util.join_path(diary_dir, config.index_file)
  if vim.fn.filereadable(index_path) == 0 then
    local ok, err = pcall(function()
      local f = assert(io.open(index_path, "w"), "Failed to create diary index file.")
      f:close()
    end)
    if not ok then
      vim.notify("Error creating diary index: " .. err, vim.log.levels.ERROR, { title = "neowiki" })
      return
    end
  end

  add_to_history(index_path)
  open_file(index_path)
end

---
-- Generates a diary index by scanning diary entries and grouping them by year and month.
-- The index is written to the diary's index file.
--
M.update_index = function()
  local diary_dir = get_diary_dir()
  if not diary_dir then
    return
  end

  local ext = state.markdown_extension or ".md"
  local files = finder.find_wiki_pages(diary_dir, ext)

  local entries = {}
  for _, file in ipairs(files or {}) do
    local fname = vim.fn.fnamemodify(file, ":t")
    if fname ~= config.index_file then
      local y, m, d = fname:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
      if y and m and d then
        entries[y] = entries[y] or {}
        entries[y][m] = entries[y][m] or {}
        table.insert(entries[y][m], d)
      end
    end
  end

  local years = {}
  for y, _ in pairs(entries) do
    table.insert(years, y)
  end
  table.sort(years, function(a, b)
    return a > b
  end)

  local lines = { "# Diary Index", "" }
  for _, year in ipairs(years) do
    table.insert(lines, "## " .. year)
    local months = {}
    for m, _ in pairs(entries[year]) do
      table.insert(months, m)
    end
    table.sort(months, function(a, b)
      return a > b
    end)
    for _, month in ipairs(months) do
      table.insert(lines, "### " .. month)
      table.sort(entries[year][month], function(a, b)
        return a > b
      end)
      for _, day in ipairs(entries[year][month]) do
        local date_str = string.format("%s-%s-%s", year, month, day)
        local link = string.format("[%s](./%s%s)", date_str, date_str, ext)
        table.insert(lines, "- " .. link)
      end
      table.insert(lines, "")
    end
  end

  local index_path = util.join_path(diary_dir, config.index_file)
  local ok, err = pcall(function()
    local f = assert(io.open(index_path, "w"), "Failed to write diary index.")
    f:write(table.concat(lines, "\n"))
    f:close()
  end)
  if not ok then
    vim.notify("Error writing diary index: " .. err, vim.log.levels.ERROR, { title = "neowiki" })
  end
end

return M
