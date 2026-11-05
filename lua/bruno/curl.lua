local parsers = require('bruno.parsers')
local url_util = require('bruno.utils.url')

local M = {}

---@param parts string[]
---@param value string
local function add(parts, value)
  parts[#parts + 1] = vim.fn.shellescape(value, true)
end

---@param value string
---@param vars table<string, string>
---@return string
local function interpolate(value, vars)
  return parsers.interpolate(value or '', vars)
end

---@param headers { [1]: string, [2]: string }[]
---@param name string
---@param value string
local function set_header(headers, name, value)
  for _, header in ipairs(headers) do
    if header[1]:lower() == name:lower() then
      header[2] = value
      return
    end
  end
  headers[#headers + 1] = { name, value }
end

---@param request bruno.Request
---@param opts? { env?: string, token?: bruno.Token, oauth2?: bruno.OAuth2Config }
---@return string
function M.build(request, opts)
  opts = opts or {}
  local vars = parsers.request_vars(request, opts.env)
  local parts = { 'curl' }

  local target = parsers.resolved_url(request, opts.env)

  for _, param in ipairs(request.params or {}) do
    if param.enabled then
      target = url_util.append_query(target, interpolate(param.name, vars), interpolate(param.value, vars))
    end
  end

  local headers = {}
  for _, header in ipairs(request.headers or {}) do
    if header.enabled then
      headers[#headers + 1] = {
        interpolate(header.name, vars),
        interpolate(header.value, vars),
      }
    end
  end

  local auth = parsers.resolve_effective_auth(request) or request.auth
  local oauth2_config = opts.oauth2
  if auth and auth.mode == 'oauth2' and opts.token and oauth2_config then
    local config = oauth2_config
    local token = config.token_source == 'id_token' and opts.token.id_token or opts.token.access_token
    token = token or opts.token.access_token or ''
    if config.token_placement == 'url' then
      target = url_util.append_query(target, config.token_query_key or 'access_token', token)
    else
      local prefix = config.token_header_prefix
      if prefix == nil then
        prefix = 'Bearer'
      end
      set_header(headers, 'Authorization', prefix ~= '' and (prefix .. ' ' .. token) or token)
    end
  elseif auth and auth.mode == 'bearer' and type(auth.config) == 'table' then
    set_header(headers, 'Authorization', 'Bearer ' .. interpolate(auth.config.token or '', vars))
  elseif auth and auth.mode == 'basic' and type(auth.config) == 'table' then
    parts[#parts + 1] = '--user'
    add(parts, interpolate(auth.config.username or '', vars) .. ':' .. interpolate(auth.config.password or '', vars))
  elseif auth and auth.mode == 'apikey' and type(auth.config) == 'table' then
    local key = interpolate(auth.config.key or '', vars)
    local value = interpolate(auth.config.value or '', vars)
    if auth.config.placement == 'queryparams' then
      target = url_util.append_query(target, key, value)
    elseif key ~= '' then
      set_header(headers, key, value)
    end
  end

  parts[#parts + 1] = '--request'
  add(parts, request.method)
  parts[#parts + 1] = '--url'
  add(parts, target)

  for _, header in ipairs(headers) do
    parts[#parts + 1] = '--header'
    add(parts, header[1] .. ': ' .. header[2])
  end

  local body = request.body or { mode = 'none' }
  if body.mode == 'json' or body.mode == 'text' or body.mode == 'xml' or body.mode == 'sparql' then
    if body.content and body.content ~= '' then
      parts[#parts + 1] = '--data-raw'
      add(parts, interpolate(body.content, vars))
    end
  elseif body.mode == 'graphql' or body.mode == 'graphql-vars' then
    local query = body.content or ''
    parts[#parts + 1] = '--data-raw'
    add(parts, interpolate(query, vars))
  elseif body.mode == 'form-urlencoded' then
    for _, entry in ipairs(body.entries or {}) do
      if entry.enabled then
        parts[#parts + 1] = '--data-urlencode'
        add(parts, interpolate(entry.name, vars) .. '=' .. interpolate(entry.value, vars))
      end
    end
  elseif body.mode == 'multipart-form' then
    for _, entry in ipairs(body.entries or {}) do
      if entry.enabled then
        parts[#parts + 1] = '--form'
        add(parts, interpolate(entry.name, vars) .. '=' .. interpolate(entry.value, vars))
      end
    end
  elseif body.mode == 'file' then
    for _, entry in ipairs(body.entries or {}) do
      if entry.enabled then
        parts[#parts + 1] = '--data-binary'
        add(parts, '@' .. interpolate(entry.value, vars))
      end
    end
  end

  return table.concat(parts, ' ')
end

---Copy the request as a cURL command.
---@param request bruno.Request
---@param opts? { env?: string, token?: bruno.Token, oauth2?: bruno.OAuth2Config }
---@return string command
function M.copy(request, opts)
  local command = M.build(request, opts)
  vim.fn.setreg('+', command)
  return command
end

return M
