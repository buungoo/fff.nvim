---@class fff.grep_picker
local M = {}

local fuzzy = require('fff.fuzzy')
local conf = require('fff.conf')

--- Open grep picker with optional initial query
--- @param initial_query string|nil Initial search query
function M.open(initial_query)
  local config = conf.get()

  -- Initialize content searcher if not already initialized
  local ok = pcall(fuzzy.init_content_searcher, config.base_path)
  if not ok then
    vim.notify('Failed to initialize content searcher', vim.log.levels.ERROR)
    return
  end

  -- Prompt user for search pattern
  local pattern = initial_query or vim.fn.input('Grep pattern: ')
  if not pattern or pattern == '' then
    return
  end

  -- Perform fuzzy grep search
  local result_ok, result = pcall(
    fuzzy.fuzzy_grep_search,
    pattern,         -- grep pattern (string)
    pattern,         -- fuzzy query (string)
    config.max_results or 100,
    config.max_threads or 4
  )

  if not result_ok then
    vim.notify('Grep search failed: ' .. tostring(result), vim.log.levels.ERROR)
    return
  end

  if not result.items or #result.items == 0 then
    vim.notify('No matches found for: ' .. pattern, vim.log.levels.INFO)
    return
  end

  -- Display results using vim.ui.select
  local formatted_items = {}
  for i, item in ipairs(result.items) do
    formatted_items[i] = string.format('%s:%d: %s',
      item.relative_path,
      item.line_number,
      item.line_content:gsub('^%s+', ''))  -- Trim leading whitespace
  end

  vim.ui.select(formatted_items, {
    prompt = string.format('Grep results (%d matches):', #result.items),
    format_item = function(item) return item end,
  }, function(choice, idx)
    if choice and idx then
      local item = result.items[idx]
      vim.cmd(string.format('edit +%d %s', item.line_number, vim.fn.fnameescape(item.path)))
    end
  end)
end

return M
