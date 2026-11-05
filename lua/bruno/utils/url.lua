local M = {}

---@class bruno.ParsedUrl
---@field scheme? string
---@field authority? string
---@field host? string
---@field port? integer
---@field path string
---@field query? string
---@field fragment? string
---@field userinfo? string

---Parse an absolute URL into its parts. Keeps the query/fragment untouched.
---@param url string
---@return bruno.ParsedUrl
function M.parse(url)
  local result = { path = '' }
  local rest = url or ''

  local scheme, after_scheme = rest:match('^(%a[%w+.-]*)://(.*)$')
  if scheme then
    result.scheme = scheme:lower()
    rest = after_scheme
  end

  local fragment
  local without_fragment, fragment_value = rest:match('^(.-)#(.*)$')
  if without_fragment then
    rest = without_fragment
    fragment = fragment_value
  end
  result.fragment = fragment

  local query
  local without_query, query_value = rest:match('^(.-)%?(.*)$')
  if without_query then
    rest = without_query
    query = query_value
  end
  result.query = query

  local authority, path
  if result.scheme then
    authority, path = rest:match('^([^/]*)(.*)$')
    result.authority = authority
    result.path = path ~= '' and path or '/'
  else
    result.path = rest
  end

  if authority then
    local userinfo, hostport = authority:match('^([^@]*)@(.*)$')
    result.userinfo = userinfo
    hostport = hostport or authority

    if hostport:sub(1, 1) == '[' then
      local host, port = hostport:match('^%[([^%]]+)%]:(%d+)$')
      if host then
        result.host = host
        result.port = tonumber(port)
      else
        result.host = hostport:match('^%[([^%]]+)%]$') or hostport
      end
    else
      local host, port = hostport:match('^(.-):(%d+)$')
      if host then
        result.host = host
        result.port = tonumber(port)
      else
        result.host = hostport
      end
    end
  end

  return result
end

---@param parsed bruno.ParsedUrl
---@return string
function M.build(parsed)
  local out = ''
  if parsed.scheme then
    out = parsed.scheme .. '://'
  end
  if parsed.userinfo and parsed.userinfo ~= '' then
    out = out .. parsed.userinfo .. '@'
  end
  local host = parsed.host
  if host and host:find(':', 1, true) and not host:find('^%[') then
    host = '[' .. host .. ']'
  end
  out = out .. (host or parsed.authority or '')
  if parsed.port then
    out = out .. ':' .. tostring(parsed.port)
  end
  out = out .. (parsed.path or '')
  if parsed.query and parsed.query ~= '' then
    out = out .. '?' .. parsed.query
  end
  if parsed.fragment and parsed.fragment ~= '' then
    out = out .. '#' .. parsed.fragment
  end
  return out
end

---@param value string
---@return string
function M.decode(value)
  local ok, decoded = pcall(vim.uri_decode, value)
  if ok then
    return decoded
  end
  return value
end

---@param value string
---@return string
function M.component(value)
  return (tostring(value):gsub('([^%w%-%._~])', function(ch)
    return string.format('%%%02X', ch:byte())
  end))
end

---application/x-www-form-urlencoded encoding.
---@param value string
---@return string
function M.form_encode(value)
  local encoded = M.component(value):gsub('%%20', '+')
  return encoded
end

---@param query string?
---@return table<string, string[]>
function M.parse_query(query)
  local result = {}
  if not query or query == '' then
    return result
  end
  for pair in query:gmatch('[^&]+') do
    local key, value = pair:match('^(.-)=(.*)$')
    if not key then
      key = pair
      value = ''
    end
    key = M.decode((key:gsub('%+', ' ')))
    value = M.decode((value:gsub('%+', ' ')))
    result[key] = result[key] or {}
    table.insert(result[key], value)
  end
  return result
end

---Append a query parameter to a URL, preserving an existing query string.
---@param url string
---@param key string
---@param value string
---@return string
function M.append_query(url, key, value)
  local fragment = ''
  local base = url
  local hash = base:find('#', 1, true)
  if hash then
    fragment = base:sub(hash)
    base = base:sub(1, hash - 1)
  end

  local separator = '?'
  if base:find('?', 1, true) then
    separator = base:find('[?&]$') and '' or '&'
  end

  return base .. separator .. M.component(key) .. '=' .. M.component(value) .. fragment
end

---Build a query string from ordered key/value pairs.
---@param pairs { [1]: string, [2]: string }[]
---@return string
function M.encode_pairs(pairs)
  local out = {}
  for _, pair in ipairs(pairs) do
    out[#out + 1] = M.form_encode(pair[1]) .. '=' .. M.form_encode(pair[2])
  end
  return table.concat(out, '&')
end

---@param value any
---@return string
function M.value_to_string(value)
  if value == nil or value == vim.NIL then
    return ''
  end
  if type(value) == 'table' then
    local ok, encoded = pcall(vim.json.encode, value)
    return ok and encoded or tostring(value)
  end
  return tostring(value)
end

return M
