local env_mod = require('bruno.env')
local log = require('bruno.utils.log')
local parsers = require('bruno.parsers')

local M = {}

---@class bruno.VariableHover
---@field win integer
---@field buf integer
---@field source_win integer
---@field source_buf integer

---@type bruno.VariableHover?
local active = nil

---@param value? string
---@return boolean
local function is_set(value)
  return value ~= nil and value ~= ''
end

---@return string?
local function variable_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
  local init = 1

  while true do
    local start_col, end_col = line:find('{{.-}}', init)
    if not start_col then
      return nil
    end

    if cursor_col >= start_col - 1 and cursor_col < end_col then
      local name = line:sub(start_col + 2, end_col - 2):gsub('^%s+', ''):gsub('%s+$', '')
      if name ~= '' then
        return name
      end
    end
    init = end_col + 1
  end
end

---@param request? bruno.Request
---@param name string
---@return string? value
---@return string? environment
local function resolve_variable(request, name)
  if not request then
    return nil, nil
  end

  local environment = env_mod.ensure(request.root)
  local variables = parsers.request_vars(request, environment)
  return variables[name], environment
end

---@param request? bruno.Request
---@param name string
---@return string[]
local function build_lines(request, name)
  local value, environment = resolve_variable(request, name)
  local lines = {
    '{{' .. name .. '}}',
    '',
    'Environment: ' .. (environment or '(none)'),
  }

  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Value:'
  if is_set(value) then
    for _, line in ipairs(vim.split(value, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
  else
    lines[#lines + 1] = '<not set>'
  end

  return lines
end

---@param source_win integer
---@param source_buf integer
---@return integer buf
---@return integer win
local function open_float(source_win, source_buf, lines)
  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, #line)
  end

  local max_columns = math.max(10, vim.o.columns - 6)
  local width = math.min(math.max(24, max_width + 2), max_columns)
  local height = math.min(#lines, math.max(3, vim.o.lines - 8))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'text'

  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Variable ',
    title_pos = 'center',
    focusable = true,
    zindex = 60,
  })
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false

  active = {
    win = win,
    buf = buf,
    source_win = source_win,
    source_buf = source_buf,
  }

  local function close_and_return()
    local previous = active and active.source_win
    M.close()
    if previous and vim.api.nvim_win_is_valid(previous) then
      vim.api.nvim_set_current_win(previous)
    end
  end

  vim.keymap.set('n', 'K', close_and_return, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set('n', 'q', close_and_return, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set('n', '<Esc>', close_and_return, { buffer = buf, silent = true, nowait = true })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      if active and active.buf == buf then
        active = nil
      end
    end,
  })

  return buf, win
end

---Close the variable hover window.
function M.close()
  if not active then
    return
  end
  local hover = active
  active = nil
  if vim.api.nvim_win_is_valid(hover.win) then
    pcall(vim.api.nvim_win_close, hover.win, true)
  end
  if vim.api.nvim_buf_is_valid(hover.buf) then
    pcall(vim.api.nvim_buf_delete, hover.buf, { force = true })
  end
end

---Show or focus the variable hover for the token under the cursor.
---@param request? bruno.Request
---@return integer? win
function M.show(request)
  if active and vim.api.nvim_win_is_valid(active.win) and vim.api.nvim_buf_is_valid(active.buf) then
    vim.api.nvim_set_current_win(active.win)
    pcall(vim.api.nvim_win_set_cursor, active.win, { 1, 0 })
    return active.win
  end

  active = nil

  if not request then
    log.notify('Bruno: no request selected', 'warn')
    return nil
  end

  local name = variable_under_cursor()
  if not name then
    return nil
  end

  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()
  local lines = build_lines(request, name)
  local _, win = open_float(source_win, source_buf, lines)
  return win
end

---@return boolean
function M.is_open()
  return active ~= nil and vim.api.nvim_win_is_valid(active.win)
end

return M
