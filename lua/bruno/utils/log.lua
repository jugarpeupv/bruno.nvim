local M = {}

local LEVELS = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

local MAX_ENTRIES = 1000

---@type string[]
local entries = {}

---@type fun()[]
local listeners = {}

---@return string
local function log_path()
  return vim.fn.stdpath('cache') .. '/bruno.nvim/bruno.log'
end

---@return string
function M.path()
  return log_path()
end

---@return string[]
function M.entries()
  return entries
end

function M.clear()
  entries = {}
end

---@param callback fun()
function M.on_change(callback)
  listeners[#listeners + 1] = callback
end

---@param level 'debug'|'info'|'warn'|'error'
---@param message string
---@param data? table
function M.write(level, message, data)
  local config = require('bruno.config').get()
  local configured = config.log_level or 'warn'
  if configured == 'off' then
    return
  end

  local display_message = tostring(message):gsub('\r?\n', ' ')
  local line = string.format('[%s] %-5s %s', os.date('%Y-%m-%d %H:%M:%S'), level:upper(), display_message)
  if data ~= nil then
    line = line .. ' ' .. vim.inspect(data):gsub('\n', ' ')
  end

  entries[#entries + 1] = line
  if #entries > MAX_ENTRIES then
    table.remove(entries, 1)
  end

  -- The in-memory Logs tab keeps every level; `log_level` only controls the
  -- file sink.
  if LEVELS[level] >= LEVELS[configured] then
    local path = log_path()
    pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ':h'), 'p')
    pcall(vim.fn.writefile, { line }, path, 'a')
  end

  for _, listener in ipairs(listeners) do
    pcall(listener)
  end
end

---@param message string
---@param data? table
function M.debug(message, data)
  M.write('debug', message, data)
end

---@param message string
---@param data? table
function M.info(message, data)
  M.write('info', message, data)
end

---@param message string
---@param data? table
function M.warn(message, data)
  M.write('warn', message, data)
end

---@param message string
---@param data? table
function M.error(message, data)
  M.write('error', message, data)
end

---Notify the user unless notifications are disabled.
---@param message string
---@param level? 'debug'|'info'|'warn'|'error'
function M.notify(message, level)
  local config = require('bruno.config').get()
  M.write(level or 'info', message)
  if not config.notify then
    return
  end
  vim.notify(message, LEVELS[level or 'info'] or vim.log.levels.INFO, { title = 'bruno.nvim' })
end

return M
