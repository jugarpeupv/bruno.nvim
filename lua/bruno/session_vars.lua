local Json = require('bruno.utils.json')

local M = {}

---Session-scoped runtime variables captured from after-response scripts.
---
---Bruno's `bru.setVar` values live only inside a single `bru run` process. The
---plugin runs every request as its own CLI invocation, so a token stored by a
---login request would be gone by the time the next request runs. To mirror the
---Bruno desktop app's "app session" behavior, we extract the simple
---`bru.setVar("NAME", expr)` assignments from the after-response script,
---evaluate them against the actual response, and inject them into following
---runs with `--env-var`.
---@type table<string, table<string, string>>
local store = {}

---@param root? string
---@param env? string
---@return string
local function key(root, env)
  return tostring(root or '') .. '\0' .. tostring(env or '')
end

---Names that look like authentication material.
local SENSITIVE_PATTERNS = {
  'TOKEN',
  'SECRET',
  'PASSWORD',
  'PASSWD',
  'API_KEY',
  'APIKEY',
  'PRIVATE',
  'CREDENTIAL',
  'AUTH',
}

---@param name string
---@return boolean
function M.is_sensitive(name)
  local upper = tostring(name):upper()
  for _, pattern in ipairs(SENSITIVE_PATTERNS) do
    if upper:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

---@param name string
---@return string
function M.display_value(name, value)
  if M.is_sensitive(name) then
    return '********'
  end
  return M.value_string(value)
end

---@param value any
---@return string
function M.value_string(value)
  if value == nil or value == vim.NIL then
    return ''
  end
  if type(value) == 'table' then
    return Json.pretty(value)
  end
  return tostring(value)
end

---Evaluate the right-hand side of a `bru.setVar(...)` / `bru.setEnvVar(...)`
---against the response. Supports `res.getStatus()` and dotted
---`res.getBody().field` access, plus string/number/boolean literals.
---@param expr string
---@param response table
---@return any
local function eval_expression(expr, response)
  expr = vim.trim(expr)

  local str = expr:match('^"(.*)"$') or expr:match("^'(.*)'$")
  if str ~= nil then
    return str
  end
  if expr == 'true' then
    return true
  end
  if expr == 'false' then
    return false
  end
  if expr == 'null' or expr == 'undefined' then
    return nil
  end
  local num = tonumber(expr)
  if num ~= nil then
    return num
  end

  if expr:match('^res%.getStatus%(%s*%)$') then
    return response.status
  end
  if expr:match('^res%.getBody%(%s*%)$') then
    return response.data
  end

  local chain = expr:match('^res%.getBody%(%s*%)%.(.+)$')
  if chain then
    local value = response.data
    for part in chain:gmatch('[^%.]+') do
      if type(value) ~= 'table' then
        value = nil
        break
      end
      value = value[part]
    end
    return value
  end

  return nil
end

---Parse `bru.setVar("name", value)` / `bru.setEnvVar("name", value)` from a
---script and resolve the values against the response.
---@param script string?
---@param response table
---@return table<string, string>
function M.extract(script, response)
  local result = {}
  if type(script) ~= 'string' or script == '' then
    return result
  end

  for line in script:gmatch('[^\r\n]+') do
    local name, expr = line:match('bru%.set%w+%(%s*["\']([^"\']+)["\']%s*,%s*(.+)$')
    if name and expr then
      expr = expr:gsub('%s*;%s*$', ''):gsub('%s*%)%s*$', ''):gsub('^%s+', '')
      local value = eval_expression(expr, response)
      if value ~= nil then
        result[name] = M.value_string(value)
      end
    end
  end

  return result
end

---Remember the runtime variables set by a finished request's after-response
---script so later requests can use them.
---@param request? bruno.Request
---@param env? string
---@param result? bruno.RunResult
function M.remember(request, env, result)
  if not request or not request.root then
    return
  end
  local first = result and result.results and result.results[1]
  local response = first and first.response
  if not response then
    return
  end

  local vars = M.extract(request.script and request.script.post, response)
  if next(vars) == nil then
    return
  end

  local bucket = key(request.root, env)
  store[bucket] = store[bucket] or {}
  for name, value in pairs(vars) do
    store[bucket][name] = value
  end
end

---Variables captured for a collection/environment.
---@param root? string
---@param env? string
---@return table<string, string>
function M.get(root, env)
  return store[key(root, env)] or {}
end

---Forget the captured variables for a collection (and optionally one env).
---@param root? string
---@param env? string
function M.forget(root, env)
  if root == nil then
    store = {}
    return
  end
  if env == nil then
    local prefix = tostring(root) .. '\0'
    for bucket in pairs(store) do
      if bucket:sub(1, #prefix) == prefix then
        store[bucket] = nil
      end
    end
    return
  end
  store[key(root, env)] = nil
end

---Forget every captured variable.
function M.reset()
  store = {}
end

---Arguments that inject the captured variables into a CLI run.
---@param request? bruno.Request
---@param env? string
---@return string[]
function M.args(request, env)
  local args = {}
  if not request or not request.root then
    return args
  end
  local vars = M.get(request.root, env)
  local names = vim.tbl_keys(vars)
  table.sort(names)
  for _, name in ipairs(names) do
    args[#args + 1] = '--env-var'
    args[#args + 1] = name .. '=' .. tostring(vars[name])
  end
  return args
end

return M
