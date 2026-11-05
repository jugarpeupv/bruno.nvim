local Json = require('bruno.utils.json')
local log = require('bruno.utils.log')
local url_util = require('bruno.utils.url')

local M = {}

local STATUS_MARKER = '__BRUNO_HTTP_STATUS__:'

---@param value string
---@return table<string, string>
local function parse_form_body(value)
  local result = {}
  for key, item in pairs(url_util.parse_query(value)) do
    result[key] = item[#item]
  end
  return result
end

---@param body string
---@return table
local function decode_body(body)
  body = vim.trim(body or '')
  if body == '' then
    return {}
  end

  local decoded = Json.decode(body)
  if type(decoded) == 'table' then
    return decoded
  end

  if body:find('access_token=') or body:find('error=') then
    return parse_form_body(body)
  end

  return { raw = body }
end

---@param body string
---@return string
local function error_message(body)
  local decoded = Json.decode(body or '')
  if type(decoded) == 'table' then
    local message = decoded.error_description or decoded.error or decoded.message
    if message then
      local code = decoded.error
      if code and decoded.error_description and code ~= decoded.error_description then
        return tostring(code) .. ': ' .. tostring(message)
      end
      return tostring(message)
    end
  end
  return vim.trim(body or '')
end

---Perform an application/x-www-form-urlencoded POST and decode the JSON response.
---@param endpoint string
---@param params { [1]: string, [2]: string }[]
---@param headers { [1]: string, [2]: string }[]
---@param timeout_ms integer
---@param callback fun(token: table|nil, err: string|nil)
function M.post_form(endpoint, params, headers, timeout_ms, callback)
  if vim.fn.executable('curl') ~= 1 then
    callback(nil, 'curl is required to exchange OAuth2 tokens')
    return
  end

  local body = url_util.encode_pairs(params)
  local timeout_sec = math.max(1, math.floor((timeout_ms or 30000) / 1000))

  local args = {
    'curl',
    '--silent',
    '--show-error',
    '--location',
    '--max-time',
    tostring(timeout_sec),
    '--request',
    'POST',
    '--header',
    'Content-Type: application/x-www-form-urlencoded',
    '--header',
    'Accept: application/json',
    '--data-binary',
    '@-',
    '--write-out',
    '\n' .. STATUS_MARKER .. '%{http_code}',
  }

  for _, header in ipairs(headers or {}) do
    if header[1] and header[1] ~= '' then
      table.insert(args, '--header')
      table.insert(args, header[1] .. ': ' .. (header[2] or ''))
    end
  end

  table.insert(args, endpoint)

  log.debug('oauth2 token request', {
    endpoint = endpoint,
    params = vim.tbl_map(function(pair)
      if pair[1] == 'client_secret' or pair[1] == 'code' or pair[1] == 'refresh_token' or pair[1] == 'password' then
        return { pair[1], '***' }
      end
      return pair
    end, params),
  })

  local ok, job = pcall(vim.system, args, {
    stdin = body,
    text = true,
    timeout = (timeout_ms or 30000) + 5000,
  }, function(result)
    vim.schedule(function()
      if result.signal ~= 0 then
        callback(nil, 'curl was killed with signal ' .. tostring(result.signal))
        return
      end
      if result.code ~= 0 then
        local message = vim.trim(result.stderr or '')
        if message == '' then
          message = 'curl exited with code ' .. tostring(result.code)
        end
        callback(nil, message)
        return
      end

      local stdout = result.stdout or ''
      local marker_start = stdout:find(STATUS_MARKER, 1, true)
      local status = 0
      local response_body = stdout

      if marker_start then
        local status_text = stdout:sub(marker_start + #STATUS_MARKER):match('^(%d+)')
        status = tonumber(status_text) or 0
        response_body = stdout:sub(1, marker_start - 1):gsub('\n$', '')
      end

      if status < 200 or status >= 300 then
        local detail = error_message(response_body)
        if detail == '' then
          detail = 'token endpoint returned HTTP ' .. tostring(status)
        else
          detail = 'token endpoint returned HTTP ' .. tostring(status) .. ': ' .. detail
        end
        callback(nil, detail)
        return
      end

      callback(decode_body(response_body), nil)
    end)
  end)

  if not ok then
    callback(nil, tostring(job))
    return
  end

  if job == nil then
    callback(nil, 'could not start curl')
  end
end

return M
