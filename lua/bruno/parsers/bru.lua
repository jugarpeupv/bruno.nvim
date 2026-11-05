local fs = require('bruno.utils.fs')

local M = {}

local VERBS = {
  get = true,
  post = true,
  put = true,
  delete = true,
  patch = true,
  options = true,
  head = true,
  connect = true,
  trace = true,
}

local TEXT_BLOCKS = {
  ['body'] = true,
  ['body:json'] = true,
  ['body:text'] = true,
  ['body:xml'] = true,
  ['body:sparql'] = true,
  ['body:graphql'] = true,
  ['body:graphql:vars'] = true,
  ['script:pre-request'] = true,
  ['script:post-response'] = true,
  ['tests'] = true,
  ['docs'] = true,
}

local ARRAY_BLOCKS = {
  ['vars:secret'] = true,
}

local AUTH_MODES = {
  ['auth:basic'] = 'basic',
  ['auth:bearer'] = 'bearer',
  ['auth:digest'] = 'digest',
  ['auth:ntlm'] = 'ntlm',
  ['auth:wsse'] = 'wsse',
  ['auth:apikey'] = 'apikey',
  ['auth:oauth1'] = 'oauth1',
  ['auth:oauth2'] = 'oauth2',
  ['auth:awsv4'] = 'awsv4',
  ['auth:akamai-edgegrid'] = 'akamai-edgegrid',
}

---@class bruno.BruBlock
---@field name string
---@field start_line integer
---@field end_line integer
---@field content_lines string[]
---@field entries? bruno.KeyValue[]
---@field text? string
---@field items? string[]

---@class bruno.BruDocument
---@field raw string
---@field lines string[]
---@field blocks bruno.BruBlock[]
---@field by_name table<string, bruno.BruBlock>

---@param text string
---@return string
local function unquote(text)
  text = vim.trim(text)
  if #text >= 2 and text:sub(1, 1) == '"' and text:sub(-1) == '"' then
    local inner = text:sub(2, -2):gsub('\\"', '"'):gsub('\\\\', '\\')
    return inner
  end
  return text
end

---Split a `key: value` pair, honouring quoted keys.
---@param line string
---@return string? key
---@return string? value
local function split_pair(line)
  local text = line:gsub('^%s+', '')
  local disabled = false
  if text:sub(1, 1) == '~' then
    disabled = true
    text = text:sub(2)
  end

  local key
  local rest
  if text:sub(1, 1) == '"' then
    local i = 2
    local escaped = false
    local chars = {}
    while i <= #text do
      local ch = text:sub(i, i)
      if escaped then
        chars[#chars + 1] = ch
        escaped = false
      elseif ch == '\\' then
        escaped = true
      elseif ch == '"' then
        break
      else
        chars[#chars + 1] = ch
      end
      i = i + 1
    end
    key = table.concat(chars)
    rest = text:sub(i + 1)
    if rest:sub(1, 1) ~= ':' then
      return nil, nil
    end
    rest = rest:sub(2)
  else
    local separator = text:find(':', 1, true)
    if not separator then
      return nil, nil
    end
    key = vim.trim(text:sub(1, separator - 1))
    rest = text:sub(separator + 1)
  end

  if disabled then
    key = '~' .. key
  end
  return key, vim.trim(rest)
end

---@param value string
---@return string[]
local function parse_array_value(value)
  local inner = vim.trim(value)
  if inner:sub(1, 1) == '[' then
    inner = inner:sub(2)
  end
  if inner:sub(-1) == ']' then
    inner = inner:sub(1, -2)
  end

  local items = {}
  local current = {}
  local in_single = false
  local in_double = false
  local escaped = false

  local function push()
    local item = vim.trim(table.concat(current))
    if item ~= '' then
      items[#items + 1] = unquote(item)
    end
    current = {}
  end

  for i = 1, #inner do
    local ch = inner:sub(i, i)
    if in_double then
      current[#current + 1] = ch
      if escaped then
        escaped = false
      elseif ch == '\\' then
        escaped = true
      elseif ch == '"' then
        in_double = false
      end
    elseif in_single then
      current[#current + 1] = ch
      if ch == "'" then
        in_single = false
      end
    else
      if ch == '"' then
        in_double = true
        current[#current + 1] = ch
      elseif ch == "'" then
        in_single = true
        current[#current + 1] = ch
      elseif ch == ',' or ch == '\n' then
        push()
      else
        current[#current + 1] = ch
      end
    end
  end
  push()

  return items
end

---@param content_lines string[]
---@return bruno.KeyValue[]
local function parse_entries(content_lines)
  local entries = {}
  local index = 1

  while index <= #content_lines do
    local line = content_lines[index]
    local trimmed = vim.trim(line)

    if trimmed == '' or trimmed:sub(1, 1) == '#' or trimmed:sub(1, 1) == '@' then
      index = index + 1
    else
      local key, value = split_pair(line)
      if key then
        if value and value:sub(1, 1) == '[' and not value:find(']', 1, true) then
          local parts = { value }
          local depth = 1
          index = index + 1
          while index <= #content_lines do
            local continuation = content_lines[index]
            parts[#parts + 1] = continuation
            local opens = select(2, continuation:gsub('%[', ''))
            local closes = select(2, continuation:gsub('%]', ''))
            depth = depth + opens - closes
            index = index + 1
            if depth <= 0 then
              break
            end
          end
          value = table.concat(parts, '\n')
        else
          index = index + 1
        end

        local enabled = true
        if key:sub(1, 1) == '~' then
          enabled = false
          key = key:sub(2)
        end

        if value and value:sub(1, 1) == '[' then
          for _, item in ipairs(parse_array_value(value)) do
            entries[#entries + 1] = {
              name = item,
              value = '',
              enabled = enabled,
            }
          end
        else
          entries[#entries + 1] = {
            name = key,
            value = unquote(value or ''),
            enabled = enabled,
          }
        end
      else
        index = index + 1
      end
    end
  end

  return entries
end

---@param lines string[]
---@return string
local function outdent(lines)
  local result = {}
  local min_indent = nil
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= '' then
      local indent = #(line:match('^%s*') or '')
      if min_indent == nil or indent < min_indent then
        min_indent = indent
      end
    end
  end

  if min_indent == nil then
    return ''
  end

  for _, line in ipairs(lines) do
    result[#result + 1] = line:sub(min_indent + 1)
  end

  while #result > 0 and vim.trim(result[1]) == '' do
    table.remove(result, 1)
  end
  while #result > 0 and vim.trim(result[#result]) == '' do
    table.remove(result)
  end

  return table.concat(result, '\n')
end

---@param raw string
---@return bruno.BruDocument
function M.parse(raw)
  raw = (raw or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  local lines = vim.split(raw, '\n', { plain = true })
  local blocks = {}
  local by_name = {}
  local index = 1

  while index <= #lines do
    local line = lines[index]
    local name, opener = line:match('^([^%s{]+)%s*([{%[])%s*$')
    if name and not line:match('^%s') then
      local closer = opener == '[' and ']' or '}'
      local start_line = index
      local content_lines = {}
      index = index + 1
      while index <= #lines do
        local closing = lines[index]
        if closing == closer or closing == closer .. '\r' then
          break
        end
        content_lines[#content_lines + 1] = closing
        index = index + 1
      end
      local end_line = index

      ---@type bruno.BruBlock
      local block = {
        name = name,
        start_line = start_line,
        end_line = end_line,
        content_lines = content_lines,
      }

      if TEXT_BLOCKS[name] or name:match('^script:') then
        block.text = outdent(content_lines)
      elseif ARRAY_BLOCKS[name] or opener == '[' then
        block.items = {}
        for _, content_line in ipairs(content_lines) do
          for _, item in ipairs(parse_array_value(content_line)) do
            block.items[#block.items + 1] = item
          end
        end
      else
        block.entries = parse_entries(content_lines)
      end

      blocks[#blocks + 1] = block
      by_name[name] = block
      index = index + 1
    else
      index = index + 1
    end
  end

  return {
    raw = raw,
    lines = lines,
    blocks = blocks,
    by_name = by_name,
  }
end

---@param doc bruno.BruDocument
---@param name string
---@return bruno.BruBlock?
function M.get_block(doc, name)
  return doc.by_name[name]
end

---@param entries? bruno.KeyValue[]
---@param name string
---@return string?
function M.entry_value(entries, name)
  for _, entry in ipairs(entries or {}) do
    if entry.name:lower() == name:lower() then
      return entry.value
    end
  end
  return nil
end

---@param entries? bruno.KeyValue[]
---@return table<string, string>
function M.entries_to_map(entries)
  local result = {}
  for _, entry in ipairs(entries or {}) do
    result[entry.name] = entry.value
  end
  return result
end

---@param doc bruno.BruDocument
---@return string? method
---@return bruno.BruBlock? block
function M.find_method_block(doc)
  for _, block in ipairs(doc.blocks) do
    if VERBS[block.name] then
      return block.name:upper(), block
    end
  end
  local http = doc.by_name.http
  if http then
    local method = M.entry_value(http.entries, 'method')
    return method and method:upper() or 'GET', http
  end
  return nil, nil
end

---@param value? string
---@return boolean
local function to_boolean(value)
  if value == nil then
    return false
  end
  return value:lower() == 'true'
end

---@param block bruno.BruBlock
---@param send_in string
---@param param_type string
---@param out bruno.OAuth2AdditionalParams
local function add_additional_params(block, send_in, param_type, out)
  if not block then
    return
  end
  local params = out[param_type] or {}
  for _, entry in ipairs(block.entries or {}) do
    params[#params + 1] = {
      name = entry.name,
      value = entry.value,
      enabled = entry.enabled,
      send_in = send_in,
    }
  end
  out[param_type] = params
end

---@param doc bruno.BruDocument
---@param block bruno.BruBlock
---@return bruno.OAuth2Config
local function parse_oauth2(doc, block)
  local map = M.entries_to_map(block.entries)
  local additional = {}

  add_additional_params(
    doc.by_name['auth:oauth2:additional_params:auth_req:headers'],
    'headers',
    'authorization',
    additional
  )
  add_additional_params(
    doc.by_name['auth:oauth2:additional_params:auth_req:queryparams'],
    'queryparams',
    'authorization',
    additional
  )
  add_additional_params(
    doc.by_name['auth:oauth2:additional_params:access_token_req:headers'],
    'headers',
    'token',
    additional
  )
  add_additional_params(
    doc.by_name['auth:oauth2:additional_params:access_token_req:queryparams'],
    'queryparams',
    'token',
    additional
  )
  add_additional_params(doc.by_name['auth:oauth2:additional_params:access_token_req:body'], 'body', 'token', additional)
  add_additional_params(
    doc.by_name['auth:oauth2:additional_params:refresh_token_req:headers'],
    'headers',
    'refresh',
    additional
  )
  add_additional_params(
    doc.by_name['auth:oauth2:additional_params:refresh_token_req:queryparams'],
    'queryparams',
    'refresh',
    additional
  )
  add_additional_params(
    doc.by_name['auth:oauth2:additional_params:refresh_token_req:body'],
    'body',
    'refresh',
    additional
  )

  ---@type bruno.OAuth2Config
  local config = {
    grant_type = (map.grant_type or 'authorization_code'):gsub('%-', '_'),
    client_id = map.client_id,
    client_secret = map.client_secret,
    username = map.username,
    password = map.password,
    authorization_url = map.authorization_url,
    access_token_url = map.access_token_url,
    refresh_token_url = map.refresh_token_url,
    callback_url = map.callback_url,
    scope = map.scope,
    state = map.state,
    pkce = to_boolean(map.pkce),
    credentials_placement = map.credentials_placement,
    credentials_id = map.credentials_id,
    token_source = map.token_source,
    token_placement = map.token_placement,
    token_header_prefix = map.token_header_prefix,
    token_query_key = map.token_query_key,
    auto_fetch_token = map.auto_fetch_token == nil and true or to_boolean(map.auto_fetch_token),
    auto_refresh_token = map.auto_refresh_token == nil and false or to_boolean(map.auto_refresh_token),
  }

  if next(additional) ~= nil then
    config.additional_params = additional
  end

  return config
end

---@param doc bruno.BruDocument
---@return bruno.Auth
function M.parse_auth(doc)
  for name, mode in pairs(AUTH_MODES) do
    local block = doc.by_name[name]
    if block then
      if mode == 'oauth2' then
        return { mode = mode, config = parse_oauth2(doc, block) }
      end
      return { mode = mode, config = M.entries_to_map(block.entries) }
    end
  end

  local _, http = M.find_method_block(doc)
  local mode = http and M.entry_value(http.entries, 'auth')
  if mode and mode ~= '' then
    mode = mode:lower()
    if mode == 'none' or mode == 'inherit' then
      return { mode = mode, config = {} }
    end
    return { mode = mode, config = {} }
  end

  return { mode = 'none', config = {} }
end

---@param doc bruno.BruDocument
---@return bruno.Body
function M.parse_body(doc)
  local modes = {
    { block = 'body:json', mode = 'json' },
    { block = 'body:text', mode = 'text' },
    { block = 'body:xml', mode = 'xml' },
    { block = 'body:sparql', mode = 'sparql' },
    { block = 'body:graphql', mode = 'graphql' },
    { block = 'body:graphql:vars', mode = 'graphql-vars' },
    { block = 'body:form-urlencoded', mode = 'form-urlencoded' },
    { block = 'body:multipart-form', mode = 'multipart-form' },
    { block = 'body:file', mode = 'file' },
    { block = 'body', mode = 'text' },
  }

  for _, item in ipairs(modes) do
    local block = doc.by_name[item.block]
    if block then
      if block.entries then
        return { mode = item.mode, entries = block.entries }
      end
      return { mode = item.mode, content = block.text or '' }
    end
  end

  return { mode = 'none' }
end

---@param path string
---@param raw string
---@return bruno.Request
function M.parse_request(path, raw)
  raw = raw or fs.read_file(path) or ''
  local doc = M.parse(raw)
  local meta_map = M.entries_to_map((doc.by_name.meta or {}).entries)
  local method, method_block = M.find_method_block(doc)
  method = method or 'GET'
  method_block = method_block or { entries = {}, name = '', start_line = 0, end_line = 0, content_lines = {} }

  local http_map = M.entries_to_map(method_block.entries)
  local query_entries = (doc.by_name['params:query'] or doc.by_name.query or { entries = {} }).entries or {}
  local path_entries = (doc.by_name['params:path'] or { entries = {} }).entries or {}

  local script = {
    pre = doc.by_name['script:pre-request'] and doc.by_name['script:pre-request'].text or nil,
    post = doc.by_name['script:post-response'] and doc.by_name['script:post-response'].text or nil,
  }

  local vars_req = (doc.by_name['vars:pre-request'] or doc.by_name.vars or { entries = {} }).entries or {}
  local vars_res = (doc.by_name['vars:post-response'] or { entries = {} }).entries or {}

  local assertions = {}
  local assert_block = doc.by_name.assert
  if assert_block and assert_block.entries then
    for _, entry in ipairs(assert_block.entries) do
      assertions[#assertions + 1] = { name = entry.name, value = entry.value, enabled = entry.enabled }
    end
  end

  ---@type bruno.Request
  local request = {
    path = fs.normalize(path),
    relpath = '',
    root = '',
    format = 'bru',
    name = meta_map.name or fs.basename_no_ext(path),
    type = meta_map.type or 'http',
    method = method,
    url = http_map.url or '',
    params = query_entries,
    path_params = path_entries,
    headers = (doc.by_name.headers or { entries = {} }).entries or {},
    body = M.parse_body(doc),
    auth = M.parse_auth(doc),
    script = script,
    tests = doc.by_name.tests and doc.by_name.tests.text or nil,
    docs = doc.by_name.docs and doc.by_name.docs.text or nil,
    assertions = assertions,
    vars = { req = vars_req, res = vars_res },
    raw = raw,
  }

  return request
end

---@param path string
---@return table<string, string>
function M.parse_env(path)
  local raw = fs.read_file(path) or ''
  local doc = M.parse(raw)
  local result = {}

  local vars = doc.by_name.vars
  if vars and vars.entries then
    for _, entry in ipairs(vars.entries) do
      if entry.enabled then
        result[entry.name] = entry.value
      end
    end
  end

  local secrets = doc.by_name['vars:secret']
  if secrets and secrets.items then
    for _, item in ipairs(secrets.items) do
      result[item] = ''
    end
  end

  return result
end

---@param path string
---@return bruno.Auth?
function M.parse_folder_auth(path)
  local raw = fs.read_file(path)
  if not raw then
    return nil
  end
  local doc = M.parse(raw)
  local auth = M.parse_auth(doc)
  if auth.mode == 'none' or auth.mode == 'inherit' then
    return nil
  end
  auth.source = path
  return auth
end

M._internal = {
  parse_entries = parse_entries,
  parse_array_value = parse_array_value,
  split_pair = split_pair,
  outdent = outdent,
}

return M
