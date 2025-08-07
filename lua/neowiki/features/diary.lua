local util = require("neowiki.util")
local finder = require("neowiki.core.finder")
local config = require("neowiki.config")
local state = require("neowiki.state")
local actions = require("neowiki.core.actions")
local navigation = require("neowiki.core.navigation")

local M = {}
local diary_cfg = config.diary
local update_job = nil

local function fmt_to_pattern(fmt)
  local order = {}
  local pattern = fmt:gsub("%%[Ymd]", function(spec)
    local c = spec:sub(2)
    table.insert(order, c)
    if c == "Y" then
      return "(%d%d%d%d)"
    else
      return "(%d%d)"
    end
  end)
  return "^" .. pattern .. "$", order
end

local function format_from_parts(fmt, year, month, day)
  local rep = { Y = year, m = month, d = day }
  return (fmt:gsub("%%([Ymd])", function(k)
    return rep[k]
  end))
end

local function month_name(month)
  local m = tonumber(month)
  if not m then
    return month
  end
  return os.date("%B", os.time({ year = 2000, month = m, day = 1 }))
end

---
-- Resolves and ensures the diary directory for the current wiki.
-- @return string|nil, string|nil, string|nil, string|nil
--   - The absolute path to the diary directory or nil if outside a wiki.
--   - The wiki_root of the calling buffer.
--   - The active_wiki_path of the calling buffer.
--   - The ultimate_wiki_root of the calling buffer.
--
local function get_diary_dir()
  if not actions.check_in_neowiki() then
    return nil
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local wiki_root = vim.b[bufnr].wiki_root
  local active_wiki_path = vim.b[bufnr].active_wiki_path
  local ultimate_wiki_root = vim.b[bufnr].ultimate_wiki_root
  if not active_wiki_path or not wiki_root then
    return nil
  end
  local parent = vim.fn.fnamemodify(wiki_root, ":h")
  local diary_dir = util.join_path(parent, diary_cfg.rel_path)
  util.ensure_path_exists(diary_dir)
  return diary_dir, wiki_root, active_wiki_path, ultimate_wiki_root
end

---
-- Opens today's diary entry in the current wiki.
-- Ensures the diary directory exists, creates today's file if needed,
-- then opens it and records it in the navigation history.
--
M.open_today = function()
  local diary_dir, wiki_root, active_wiki_path, ultimate_wiki_root = get_diary_dir()
  if not diary_dir then
    return
  end

  local today = os.date(diary_cfg.date_format)
  local ext = state.markdown_extension or ".md"
  local diary_path = util.join_path(diary_dir, today .. ext)
  local created = false
  if vim.fn.filereadable(diary_path) == 0 then
    local ok, err = pcall(function()
      local f = assert(io.open(diary_path, "w"), "Failed to create diary file.")
      local content
      if type(diary_cfg.entry_template) == "function" then
        content = diary_cfg.entry_template()
      elseif type(diary_cfg.entry_template) == "string" then
        content = os.date(diary_cfg.entry_template)
      else
        local header = os.date(diary_cfg.entry_header_format)
        content = "# " .. header .. "\n\n"
      end
      f:write(content)
      f:close()
    end)
    if not ok then
      vim.notify("Error creating diary file: " .. err, vim.log.levels.ERROR, { title = "neowiki" })
      return
    end
    created = true
  end

  if created and diary_cfg.auto_update_index then
    M.update_index()
  end

  navigation.add_to_history(diary_path)
  navigation.open_file(diary_path)
  vim.b[0].wiki_root = wiki_root
  vim.b[0].active_wiki_path = active_wiki_path
  vim.b[0].ultimate_wiki_root = ultimate_wiki_root
end

---
-- Opens or creates the diary index file.
--
M.open_index = function()
  local diary_dir, wiki_root, active_wiki_path, ultimate_wiki_root = get_diary_dir()
  if not diary_dir then
    return
  end

  local index_path = util.join_path(diary_dir, diary_cfg.index_file)
  if vim.fn.filereadable(index_path) == 0 then
    local ok, err = pcall(function()
      local f = assert(io.open(index_path, "w"), "Failed to create diary index file.")
      f:write("# " .. diary_cfg.header .. "\n\n")
      f:close()
    end)
    if not ok then
      vim.notify("Error creating diary index: " .. err, vim.log.levels.ERROR, { title = "neowiki" })
      return
    end
  end

  navigation.add_to_history(index_path)
  navigation.open_file(index_path)
  vim.b[0].wiki_root = wiki_root
  vim.b[0].active_wiki_path = active_wiki_path
  vim.b[0].ultimate_wiki_root = ultimate_wiki_root
end

---
-- Internal function used by a headless job to collect diary entry metadata.
-- It prints a JSON array of {y, m, d} tables to stdout.
--
M._collect_entries = function(dir, ext, date_fmt)
  local pattern, order = fmt_to_pattern(date_fmt)
  local files = finder.find_wiki_pages(dir, ext)
  local results = {}
  for _, file in ipairs(files or {}) do
    local fname = vim.fn.fnamemodify(file, ":t")
    if fname ~= diary_cfg.index_file then
      local stem = vim.fn.fnamemodify(file, ":t:r")
      local caps = { stem:match(pattern) }
      if #caps == #order then
        local parts = {}
        for i, tok in ipairs(order) do
          parts[tok] = caps[i]
        end
        local y, m, d = parts.Y, parts.m, parts.d
        if y and m and d then
          table.insert(results, { y = y, m = m, d = d })
        end
      end
    end
  end
  io.stdout:write(vim.fn.json_encode(results))
end

---
-- Generates a diary index by scanning diary entries and grouping them by year and month.
-- File discovery and parsing are run in a background job.
--
M.update_index = function()
  local diary_dir = get_diary_dir()
  if not diary_dir then
    return
  end
  if update_job then
    vim.notify("Diary index update already running.", vim.log.levels.INFO, { title = "neowiki" })
    return
  end

  local ext = state.markdown_extension or ".md"
  local runtime_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
  local cmd = {
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "--cmd",
    "set rtp+=" .. runtime_root,
    "-c",
    string.format(
      "lua require('neowiki.features.diary')._collect_entries(%q, %q, %q)",
      diary_dir,
      ext,
      diary_cfg.date_format
    ),
    "-c",
    "qa!",
  }

  local output = ""
  update_job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then
        output = output .. table.concat(data, "")
      end
    end,
    on_exit = function(_, code)
      update_job = nil
      if code ~= 0 then
        vim.schedule(function()
          vim.notify(
            "Failed to collect diary entries.",
            vim.log.levels.ERROR,
            { title = "neowiki" }
          )
        end)
        return
      end
      local ok, parsed = pcall(vim.fn.json_decode, output)
      if not ok then
        vim.schedule(function()
          vim.notify(
            "Failed to parse diary entry data.",
            vim.log.levels.ERROR,
            { title = "neowiki" }
          )
        end)
        return
      end
      vim.schedule(function()
        local entries = {}
        for _, item in ipairs(parsed or {}) do
          local y, m, d = item.y, item.m, item.d
          entries[y] = entries[y] or {}
          entries[y][m] = entries[y][m] or {}
          table.insert(entries[y][m], d)
        end

        local years = {}
        for y, _ in pairs(entries) do
          table.insert(years, y)
        end
        table.sort(years, function(a, b)
          return a > b
        end)

        local lines = { "# " .. diary_cfg.header, "" }
        for _, year in ipairs(years) do
          table.insert(lines, "## " .. year)
          table.insert(lines, "")
          local months = {}
          for m, _ in pairs(entries[year]) do
            table.insert(months, tonumber(m))
          end
          table.sort(months, function(a, b)
            return a > b
          end)
          for _, month_num in ipairs(months) do
            local month = string.format("%02d", month_num)
            table.insert(lines, "### " .. month_name(month))
            table.insert(lines, "")
            local days = {}
            for _, d in ipairs(entries[year][month]) do
              table.insert(days, tonumber(d))
            end
            table.sort(days, function(a, b)
              return a > b
            end)
            for _, day_num in ipairs(days) do
              local day = string.format("%02d", day_num)
              local date_str = format_from_parts(diary_cfg.date_format, year, month, day)
              local link = string.format("[%s](./%s%s)", date_str, date_str, ext)
              table.insert(lines, "- " .. link)
            end
            table.insert(lines, "")
          end
        end

        local index_path = util.join_path(diary_dir, diary_cfg.index_file)
        local ok2, err = pcall(function()
          local f = assert(io.open(index_path, "w"), "Failed to write diary index.")
          f:write(table.concat(lines, "\n"))
          f:close()
        end)
        if not ok2 then
          vim.notify(
            "Error writing diary index: " .. err,
            vim.log.levels.ERROR,
            { title = "neowiki" }
          )
          return
        end

        local bufnr = vim.fn.bufnr(index_path)
        if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent! edit!")
          end)
        end
      end)
    end,
  })
end

return M
