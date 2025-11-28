---@class fff.grep_picker
local M = {}

local picker_ui = require('fff.picker_ui')
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

  -- Create a custom picker for grep
  picker_ui.open_with_callback(initial_query or '', function(input, on_select)
    if not input or input == '' then
      return { items = {}, scores = {}, total_matched = 0, total_grepped = 0 }
    end

    -- Perform fuzzy grep search
    local result_ok, result = pcall(
      fuzzy.fuzzy_grep_search,
      input,           -- grep pattern
      input,           -- fuzzy query (same as pattern for simplicity)
      config.max_results or 100,
      config.max_threads or 4
    )

    if not result_ok then
      vim.notify('Grep search failed: ' .. tostring(result), vim.log.levels.ERROR)
      return { items = {}, scores = {}, total_matched = 0, total_grepped = 0 }
    end

    return result
  end, {
    title = 'Grep Search',
    format_item = function(item)
      return string.format('%s:%d: %s', item.relative_path, item.line_number, item.line_content)
    end,
    on_select = function(item)
      vim.cmd(string.format('edit +%d %s', item.line_number, vim.fn.fnameescape(item.path)))
    end,
  })
end

return M
