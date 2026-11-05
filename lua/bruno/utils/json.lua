local M = {}

---@param value any
---@return boolean
local function is_null(value)
  return value == nil or value == vim.NIL
end

---@param str string
---@return string
local function encode_string(str)
  return vim.json.encode(str)
end

---@param value any
---@param indent string
---@param level integer
---@return string
local function encode_value(value, indent, level)
  if is_null(value) then
    return 'null'
  end

  local kind = type(value)
  if kind == 'string' then
    return encode_string(value)
  end
  if kind == 'number' or kind == 'boolean' then
    return tostring(value)
  end

  local pad = string.rep(indent, level)
  local child_pad = string.rep(indent, level + 1)

  if kind == 'table' then
    local is_list = vim.islist(value)
    if is_list then
      if #value == 0 then
        return '[]'
      end
      local out = {}
      for _, item in ipairs(value) do
        out[#out + 1] = child_pad .. encode_value(item, indent, level + 1)
      end
      return '[\n' .. table.concat(out, ',\n') .. '\n' .. pad .. ']'
    end

    local keys = vim.tbl_keys(value)
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    if #keys == 0 then
      return '{}'
    end
    local out = {}
    for _, key in ipairs(keys) do
      out[#out + 1] = child_pad .. encode_string(tostring(key)) .. ': ' .. encode_value(value[key], indent, level + 1)
    end
    return '{\n' .. table.concat(out, ',\n') .. '\n' .. pad .. '}'
  end

  return encode_string(tostring(value))
end

---Decode a JSON string.
---@param raw string
---@return table|nil data
---@return string? err
function M.decode(raw)
  local ok, data = pcall(vim.json.decode, raw)
  if not ok then
    return nil, tostring(data)
  end
  return data, nil
end

---Encode a table as compact JSON.
---@param value any
---@return string
function M.encode(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded
  end
  return encode_value(value, '  ', 0)
end

---Return a deterministic, human-readable JSON representation.
---@param value any
---@param indent? string
---@return string
function M.pretty(value, indent)
  return encode_value(value, indent or '  ', 0)
end

---Try to pretty-print a raw JSON string, otherwise return it untouched.
---@param raw string
---@return string
function M.pretty_string(raw)
  local trimmed = vim.trim(raw or '')
  if trimmed == '' then
    return raw
  end
  local data = M.decode(trimmed)
  if data == nil then
    return raw
  end
  return M.pretty(data)
end

---@param raw string
---@return boolean
function M.looks_like_json(raw)
  local trimmed = vim.trim(raw or '')
  if trimmed == '' then
    return false
  end
  local first = trimmed:sub(1, 1)
  return first == '{' or first == '['
end

return M
