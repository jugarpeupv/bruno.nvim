local bru = require('bruno.parsers.bru')
local fs = require('bruno.utils.fs')
local json = require('bruno.utils.json')
local url_util = require('bruno.utils.url')

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

---@param config bruno.OAuth2Config
---@param token bruno.Token
---@return string value
---@return boolean is_header
local function token_value(config, token)
  local value = config.token_source == 'id_token' and token.id_token or token.access_token
  value = value or token.access_token or token.id_token or ''
  local placement = config.token_placement or 'header'

  if placement == 'url' then
    return value, false
  end

  local prefix = config.token_header_prefix
  if prefix == nil then
    prefix = 'Bearer'
  end
  if prefix == '' then
    return value, true
  end
  return prefix .. ' ' .. value, true
end

---@param lines string[]
---@param from integer
---@return integer
local function find_block_end(lines, from)
  local index = from + 1
  while index <= #lines do
    if lines[index] == '}' then
      return index
    end
    index = index + 1
  end
  return #lines + 1
end

---@param lines string[]
local function remove_top_level_auth(lines)
  local index = 1
  while index <= #lines do
    if lines[index]:match('^auth:[%w:_%-]+%s*{%s*$') then
      local last = find_block_end(lines, index)
      for cursor = last, index, -1 do
        if lines[cursor] ~= nil then
          table.remove(lines, cursor)
        end
      end
    else
      index = index + 1
    end
  end
end

---@param lines string[]
---@return integer? start
---@return integer? last
local function find_method_block(lines)
  for index, line in ipairs(lines) do
    local name = line:match('^([^%s{]+)%s*{%s*$')
    if name and (VERBS[name] or name == 'http') then
      return index, find_block_end(lines, index)
    end
  end
  return nil, nil
end

---@param lines string[]
---@param block_start integer
---@param block_end integer
local function force_auth_none(lines, block_start, block_end)
  for index = block_start + 1, block_end - 1 do
    if lines[index]:match('^%s*auth:%s*') then
      lines[index] = '  auth: none'
      return
    end
  end
  table.insert(lines, block_end, '  auth: none')
end

---@param lines string[]
---@param block_start integer
---@param block_end integer
---@param name string
---@param value string
local function set_bru_header(lines, block_start, block_end, name, value)
  local header_start
  local header_end

  for index, line in ipairs(lines) do
    local block_name = line:match('^([^%s{]+)%s*{%s*$')
    if block_name == 'headers' then
      header_start = index
      header_end = find_block_end(lines, index)
      break
    end
  end

  if not header_start then
    -- Insert a new headers block after the request block.
    local block = {
      '',
      'headers {',
      '  ' .. name .. ': ' .. value,
      '}',
    }
    for offset, line in ipairs(block) do
      table.insert(lines, block_end + offset, line)
    end
    return
  end

  local escaped_name = name:lower()
  for index = header_end - 1, header_start + 1, -1 do
    local line = lines[index]
    local key = line:match('^%s*~?["]?([^"%s:]+)["]?%s*:')
    if key and key:lower() == escaped_name then
      table.remove(lines, index)
    end
  end

  -- Recompute the end after removals.
  header_end = find_block_end(lines, header_start)
  table.insert(lines, header_end, '  ' .. name .. ': ' .. value)
end

---@param lines string[]
---@param block_start integer
---@param block_end integer
---@param key string
---@param value string
local function set_bru_url_query(lines, block_start, block_end, key, value)
  for index = block_start + 1, block_end - 1 do
    local prefix, current, suffix = lines[index]:match('^(%s*url:%s*)(.-)(%s*)$')
    if prefix then
      local quoted = current:sub(1, 1) == '"' and current:sub(-1) == '"'
      local plain = quoted and current:sub(2, -2) or current
      plain = url_util.append_query(plain, key, value)
      lines[index] = prefix .. (quoted and ('"' .. plain .. '"') or plain) .. suffix
      return
    end
  end
end

---@param request bruno.Request
---@param token bruno.Token
---@param config bruno.OAuth2Config
---@return string? path
---@return string? err
local function build_bru(request, token, config)
  local lines = vim.split(request.raw:gsub('\r\n', '\n'), '\n', { plain = true })
  remove_top_level_auth(lines)

  local block_start, block_end = find_method_block(lines)
  if not block_start or not block_end then
    return nil, 'could not find the request block in ' .. request.path
  end

  force_auth_none(lines, block_start, block_end)

  -- The indices can shift after inserting auth:none, so recompute the request block.
  block_start, block_end = find_method_block(lines)
  if not block_start or not block_end then
    return nil, 'could not find the request block in ' .. request.path
  end

  local value, is_header = token_value(config, token)
  if is_header then
    set_bru_header(lines, block_start, block_end, 'Authorization', value)
  else
    set_bru_url_query(lines, block_start, block_end, config.token_query_key or 'access_token', value)
  end

  local path = fs.sibling_tempname(request.path)
  local content = table.concat(lines, '\n')
  if content:sub(-1) ~= '\n' then
    content = content .. '\n'
  end

  local ok, err = fs.write_file(path, content, 384)
  if not ok then
    return nil, err
  end
  return path, nil
end

---@param line string
---@return integer
local function indent_of(line)
  return #(line:match('^ *') or '')
end

---@param line string
---@return boolean
local function is_blank(line)
  local trimmed = vim.trim(line or '')
  return trimmed == '' or trimmed:sub(1, 1) == '#'
end

---@param lines string[]
---@param start_index integer
---@param indent integer
---@return integer
local function block_end(lines, start_index, indent)
  local index = start_index + 1
  while index <= #lines do
    if not is_blank(lines[index]) and indent_of(lines[index]) <= indent then
      return index
    end
    index = index + 1
  end
  return #lines + 1
end

---@param lines string[]
---@param key string
---@param indent integer
---@param from_index? integer
---@param to_index? integer
---@return integer?
local function find_key(lines, key, indent, from_index, to_index)
  local pattern = '^' .. string.rep(' ', indent) .. key .. ':%s*$'
  for index = from_index or 1, (to_index or #lines) do
    if lines[index] and lines[index]:match(pattern) then
      return index
    end
  end
  return nil
end

---@param lines string[]
---@param key string
---@param indent integer
---@param from_index? integer
---@param to_index? integer
local function remove_key_block(lines, key, indent, from_index, to_index)
  local index = find_key(lines, key, indent, from_index, to_index)
  if not index then
    return false
  end
  local last = block_end(lines, index, indent)
  local remove_until = last - 1
  for cursor = remove_until, index, -1 do
    table.remove(lines, cursor)
  end
  return true
end

---@param value string
---@return string
local function yaml_quote(value)
  return json.encode(value)
end

---@param lines string[]
---@param http_start integer
---@param http_end integer
---@param value string
---@return boolean ok
---@return string? err
local function set_yml_header(lines, http_start, http_end, value)
  local headers_index = find_key(lines, 'headers', 2, http_start + 1, http_end)
  if not headers_index then
    local url_index = find_key(lines, 'url', 2, http_start + 1, http_end)
    local insert_at = url_index and url_index + 1 or http_start + 1
    local block = {
      '  headers:',
      '    - name: Authorization',
      '      value: ' .. yaml_quote(value),
    }
    for offset = #block, 1, -1 do
      table.insert(lines, insert_at, block[offset])
    end
    return true, nil
  end

  -- Block sequences are the only supported header representation here.
  local headers_line = lines[headers_index]
  if headers_line:match('^%s*headers:%s*%[%s*%]%s*$') then
    lines[headers_index] = '  headers:'
    table.insert(lines, headers_index + 1, '    - name: Authorization')
    table.insert(lines, headers_index + 2, '      value: ' .. yaml_quote(value))
    return true, nil
  end
  if not headers_line:match('^%s*headers:%s*$') then
    return false, 'unsupported flow-style headers list; cannot inject the Authorization header'
  end

  local headers_end = block_end(lines, headers_index, 2)
  local list_indent
  for index = headers_index + 1, headers_end - 1 do
    if not is_blank(lines[index]) then
      local current = indent_of(lines[index])
      if current > 2 then
        list_indent = current
        break
      end
    end
  end
  list_indent = list_indent or 4

  -- Remove an existing Authorization item.
  local index = headers_index + 1
  while index < headers_end do
    if not is_blank(lines[index]) and indent_of(lines[index]) == list_indent and lines[index]:match('^%s*%-') then
      local item_end = block_end(lines, index, list_indent)
      local is_authorization = false
      for cursor = index, item_end - 1 do
        local name = lines[cursor]:match('^%s*%-?%s*name:%s*(.-)%s*$')
        if name then
          name = name:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
          if name:lower() == 'authorization' then
            is_authorization = true
            break
          end
        end
      end
      if is_authorization then
        for cursor = item_end - 1, index, -1 do
          table.remove(lines, cursor)
        end
        headers_end = block_end(lines, headers_index, 2)
      else
        index = item_end
      end
    else
      index = index + 1
    end
  end

  -- Append our item at the end of the sequence.
  local insert_at = headers_end
  table.insert(lines, insert_at, string.rep(' ', list_indent + 2) .. 'value: ' .. yaml_quote(value))
  table.insert(lines, insert_at, string.rep(' ', list_indent) .. '- name: Authorization')
  return true, nil
end

---@param request bruno.Request
---@param token bruno.Token
---@param config bruno.OAuth2Config
---@return string? path
---@return string? err
local function build_yml(request, token, config)
  local lines = vim.split(request.raw:gsub('\r\n', '\n'), '\n', { plain = true })

  local http_start
  local http_end
  for index, line in ipairs(lines) do
    if line:match('^http:%s*$') or line:match('^graphql:%s*$') or line:match('^websocket:%s*$') then
      http_start = index
      http_end = block_end(lines, index, 0)
      break
    end
  end

  if not http_start then
    return nil, 'could not find the http section in ' .. request.path
  end

  remove_key_block(lines, 'auth', 2, http_start + 1, http_end)

  -- runtime.auth overrides http.auth when http.auth is absent, so remove it too.
  local runtime_index = find_key(lines, 'runtime', 0)
  if runtime_index then
    local runtime_end = block_end(lines, runtime_index, 0)
    remove_key_block(lines, 'auth', 2, runtime_index + 1, runtime_end)
  end

  -- Recompute after removals.
  for index, line in ipairs(lines) do
    if line:match('^http:%s*$') or line:match('^graphql:%s*$') or line:match('^websocket:%s*$') then
      http_start = index
      http_end = block_end(lines, index, 0)
      break
    end
  end

  local value, is_header = token_value(config, token)
  if is_header then
    local ok, err = set_yml_header(lines, http_start, http_end, value)
    if not ok then
      return nil, err
    end
  else
    local url_index = find_key(lines, 'url', 2, http_start + 1, http_end)
    if not url_index then
      return nil, 'could not find the request URL in ' .. request.path
    end
    local prefix, current = lines[url_index]:match('^(%s*url:%s*)(.-)%s*$')
    if prefix then
      local quoted = current:sub(1, 1) == '"' and current:sub(-1) == '"'
      local plain = quoted and current:sub(2, -2) or current
      plain = url_util.append_query(plain, config.token_query_key or 'access_token', value)
      lines[url_index] = prefix .. (quoted and ('"' .. plain .. '"') or plain)
    end
  end

  local path = fs.sibling_tempname(request.path)
  local content = table.concat(lines, '\n')
  if content:sub(-1) ~= '\n' then
    content = content .. '\n'
  end

  local ok, err = fs.write_file(path, content, 384)
  if not ok then
    return nil, err
  end
  return path, nil
end

---Create a temporary copy of the request with the OAuth2 access token applied.
---
---The Bruno CLI does not implement the authorization-code flow, so we replace
---the request-level auth with `none` and inject the token as a regular header
---(or URL query parameter). The temporary file lives next to the original so
---relative script/body paths keep working.
---@param request bruno.Request
---@param token bruno.Token
---@param config bruno.OAuth2Config
---@return string? path
---@return string? err
function M.build(request, token, config)
  if not token or (not token.access_token and not token.id_token) then
    return nil, 'no access token available'
  end

  if request.format == 'bru' then
    return build_bru(request, token, config)
  end
  return build_yml(request, token, config)
end

---@param path string?
function M.cleanup(path)
  if path then
    fs.unlink(path)
  end
end

M._internal = {
  token_value = token_value,
  indent_of = indent_of,
  block_end = block_end,
  find_key = find_key,
}

return M
