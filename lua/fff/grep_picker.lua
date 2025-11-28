---@class fff.grep_picker
local M = {}

local fuzzy = require('fff.fuzzy')
local conf = require('fff.conf')
local preview = require('fff.file_picker.preview')
local utils = require('fff.utils')

-- State for the grep picker
M.state = {
  active = false,
  search_results = nil,
  current_query = '',
  -- Window handles
  input_win = nil,
  input_buf = nil,
  list_win = nil,
  list_buf = nil,
  preview_win = nil,
  preview_buf = nil,
  -- UI state
  selected_index = 1,
  display_offset = 0,
}

--- Calculate layout dimensions for ivy_split style (bottom split)
local function calculate_ivy_layout()
  local total_width = vim.o.columns
  local total_height = vim.o.lines

  -- ivy_split: 40% height at bottom of screen
  local picker_height = math.floor(total_height * 0.4)
  local input_height = 1
  local list_height = picker_height - input_height - 2  -- -2 for borders

  -- List takes 40%, preview takes 60%
  local list_width = math.floor(total_width * 0.4)
  local preview_width = total_width - list_width - 1  -- -1 for separator

  return {
    total_width = total_width,
    total_height = total_height,
    picker_height = picker_height,
    input_height = input_height,
    list_height = list_height,
    list_width = list_width,
    preview_width = preview_width,
    -- Position at bottom
    row = total_height - picker_height,
    col = 0,
  }
end

--- Create the picker windows in ivy_split layout
local function create_windows()
  local layout = calculate_ivy_layout()

  -- Create input buffer
  M.state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.state.input_buf].buftype = 'prompt'
  vim.bo[M.state.input_buf].bufhidden = 'wipe'

  -- Create list buffer
  M.state.list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.state.list_buf].bufhidden = 'wipe'
  vim.bo[M.state.list_buf].modifiable = false

  -- Create preview buffer
  M.state.preview_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.state.preview_buf].bufhidden = 'wipe'
  vim.bo[M.state.preview_buf].modifiable = false

  -- Create input window (full width, at bottom)
  M.state.input_win = vim.api.nvim_open_win(M.state.input_buf, true, {
    relative = 'editor',
    width = layout.total_width,
    height = layout.input_height,
    row = layout.row,
    col = 0,
    style = 'minimal',
    border = 'top',
    title = ' Grep Search ',
    title_pos = 'left',
  })

  -- Create list window (left side, below input)
  M.state.list_win = vim.api.nvim_open_win(M.state.list_buf, false, {
    relative = 'editor',
    width = layout.list_width,
    height = layout.list_height,
    row = layout.row + layout.input_height + 1,
    col = 0,
    style = 'minimal',
    border = 'none',
  })

  -- Create preview window (right side, below input)
  M.state.preview_win = vim.api.nvim_open_win(M.state.preview_buf, false, {
    relative = 'editor',
    width = layout.preview_width,
    height = layout.list_height,
    row = layout.row + layout.input_height + 1,
    col = layout.list_width + 1,
    style = 'minimal',
    border = 'left',
    title = ' Preview ',
    title_pos = 'left',
  })

  -- Setup prompt
  vim.fn.prompt_setprompt(M.state.input_buf, '  ')
  vim.fn.prompt_setcallback(M.state.input_buf, function(text)
    M.perform_search(text)
  end)

  -- Set window options
  vim.wo[M.state.list_win].number = false
  vim.wo[M.state.list_win].relativenumber = false
  vim.wo[M.state.list_win].cursorline = false
  vim.wo[M.state.preview_win].number = false
  vim.wo[M.state.preview_win].relativenumber = false
end

--- Close all picker windows
local function close_windows()
  if M.state.input_win and vim.api.nvim_win_is_valid(M.state.input_win) then
    vim.api.nvim_win_close(M.state.input_win, true)
  end
  if M.state.list_win and vim.api.nvim_win_is_valid(M.state.list_win) then
    vim.api.nvim_win_close(M.state.list_win, true)
  end
  if M.state.preview_win and vim.api.nvim_win_is_valid(M.state.preview_win) then
    vim.api.nvim_win_close(M.state.preview_win, true)
  end

  M.state.active = false
  M.state.search_results = nil
  M.state.current_query = ''
  M.state.selected_index = 1
  M.state.display_offset = 0
end

--- Setup keymaps for the picker
local function setup_keymaps()
  local function map(mode, key, fn, opts)
    opts = opts or {}
    opts.buffer = M.state.input_buf
    vim.keymap.set(mode, key, fn, opts)
  end

  -- Close picker
  map('n', '<Esc>', close_windows)
  map('n', '<C-c>', close_windows)
  map('i', '<C-c>', close_windows)

  -- Navigate results
  map('i', '<C-n>', function()
    M.move_selection(1)
  end)
  map('i', '<C-p>', function()
    M.move_selection(-1)
  end)
  map('i', '<Down>', function()
    M.move_selection(1)
  end)
  map('i', '<Up>', function()
    M.move_selection(-1)
  end)

  -- Open selected file
  map('i', '<CR>', function()
    M.open_selected()
  end)
  map('n', '<CR>', function()
    M.open_selected()
  end)

  -- Search on text change
  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = M.state.input_buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(M.state.input_buf, 0, -1, false)
      local query = lines[1] or ''
      -- Remove prompt
      query = query:gsub('^  ', '')
      M.perform_search(query)
    end,
  })
end

--- Perform grep search with fuzzy matching
--- @param query string Search query
function M.perform_search(query)
  if not query or query == '' then
    M.state.search_results = nil
    M.state.current_query = ''
    M.update_results_display()
    return
  end

  M.state.current_query = query

  local config = conf.get()

  -- Perform fuzzy grep search
  local result_ok, result = pcall(
    fuzzy.fuzzy_grep_search,
    query,  -- grep pattern
    query,  -- fuzzy query
    config.max_results or 100,
    config.max_threads or 4
  )

  if not result_ok then
    vim.notify('Grep search failed: ' .. tostring(result), vim.log.levels.ERROR)
    return
  end

  M.state.search_results = result
  M.state.selected_index = 1
  M.state.display_offset = 0
  M.update_results_display()
  M.update_preview()
end

--- Update the results list display
function M.update_results_display()
  if not M.state.list_buf or not vim.api.nvim_buf_is_valid(M.state.list_buf) then
    return
  end

  vim.bo[M.state.list_buf].modifiable = true

  if not M.state.search_results or not M.state.search_results.items or #M.state.search_results.items == 0 then
    local message = M.state.current_query == '' and 'Start typing to search...' or 'No matches found'
    vim.api.nvim_buf_set_lines(M.state.list_buf, 0, -1, false, { message })
    vim.bo[M.state.list_buf].modifiable = false
    return
  end

  local lines = {}
  local highlights = {}

  for i, item in ipairs(M.state.search_results.items) do
    local selected = (i == M.state.selected_index)
    local indicator = selected and '● ' or '  '

    -- Format: indicator path:line: content
    local line = string.format('%s%s:%d: %s',
      indicator,
      item.relative_path,
      item.line_number,
      item.line_content:gsub('^%s+', ''))  -- Trim leading whitespace

    table.insert(lines, line)

    -- Add highlight for selected line
    if selected then
      table.insert(highlights, { line_num = i - 1, hl_group = 'Visual' })
    end
  end

  vim.api.nvim_buf_set_lines(M.state.list_buf, 0, -1, false, lines)

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.state.list_buf, -1, hl.hl_group, hl.line_num, 0, -1)
  end

  vim.bo[M.state.list_buf].modifiable = false
end

--- Update the preview window
function M.update_preview()
  if not M.state.preview_buf or not vim.api.nvim_buf_is_valid(M.state.preview_buf) then
    return
  end

  if not M.state.search_results or not M.state.search_results.items or #M.state.search_results.items == 0 then
    vim.bo[M.state.preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, {})
    vim.bo[M.state.preview_buf].modifiable = false
    return
  end

  local item = M.state.search_results.items[M.state.selected_index]
  if not item then return end

  -- Use the preview module to load file content
  local success = preview.preview(item.path, M.state.preview_buf, item.line_number)

  if not success then
    vim.bo[M.state.preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, { 'Failed to load preview' })
    vim.bo[M.state.preview_buf].modifiable = false
  end
end

--- Move selection up or down
--- @param direction number 1 for down, -1 for up
function M.move_selection(direction)
  if not M.state.search_results or not M.state.search_results.items or #M.state.search_results.items == 0 then
    return
  end

  local new_index = M.state.selected_index + direction
  local max_index = #M.state.search_results.items

  -- Wrap around
  if new_index < 1 then
    new_index = max_index
  elseif new_index > max_index then
    new_index = 1
  end

  M.state.selected_index = new_index
  M.update_results_display()
  M.update_preview()
end

--- Open the selected file
function M.open_selected()
  if not M.state.search_results or not M.state.search_results.items or #M.state.search_results.items == 0 then
    return
  end

  local item = M.state.search_results.items[M.state.selected_index]
  if not item then return end

  -- Close picker first
  close_windows()

  -- Open file and jump to line
  vim.cmd(string.format('edit +%d %s', item.line_number, vim.fn.fnameescape(item.path)))
end

--- Open grep picker with optional initial query
--- @param initial_query string|nil Initial search query
function M.open(initial_query)
  if M.state.active then
    vim.notify('Grep picker is already open', vim.log.levels.WARN)
    return
  end

  local config = conf.get()

  -- Initialize content searcher if not already initialized
  local ok = pcall(fuzzy.init_content_searcher, config.base_path)
  if not ok then
    vim.notify('Failed to initialize content searcher', vim.log.levels.ERROR)
    return
  end

  M.state.active = true

  -- Create windows
  create_windows()

  -- Setup keymaps
  setup_keymaps()

  -- Set initial query if provided
  if initial_query and initial_query ~= '' then
    vim.api.nvim_buf_set_lines(M.state.input_buf, 0, -1, false, { '  ' .. initial_query })
    M.perform_search(initial_query)
  else
    M.update_results_display()  -- Show "Start typing..." message
  end

  -- Start in insert mode
  vim.cmd('startinsert!')
end

return M
