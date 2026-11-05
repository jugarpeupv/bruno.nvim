---A small YAML 1.2 subset parser.
---
---It is deliberately not a general-purpose YAML implementation. It covers the
---shapes used by OpenCollection request, folder, collection and environment
---files: block mappings, block sequences, flow collections, quoted scalars,
---comments and literal/folded block scalars.
local M = {}

---@class bruno.YamlLine
---@field indent integer
---@field text string
---@field raw string
---@field number integer
---@field blank boolean

---@class bruno.YamlParser
---@field lines bruno.YamlLine[]
---@field index integer

---@param text string
---@return string
local function strip_inline_comment(text)
  local in_single = false
  local in_double = false
  local escaped = false
  local i = 1
  while i <= #text do
    local ch = text:sub(i, i)
    if in_double then
      if escaped then
        escaped = false
      elseif ch == '\\' then
        escaped = true
      elseif ch == '"' then
        in_double = false
      end
    elseif in_single then
      if ch == "'" then
        if text:sub(i + 1, i + 1) == "'" then
          i = i + 1
        else
          in_single = false
        end
      end
    else
      if ch == '"' then
        in_double = true
      elseif ch == "'" then
        in_single = true
      elseif ch == '#' and (i == 1 or text:sub(i - 1, i - 1):match('%s')) then
        local stripped = text:sub(1, i - 1):gsub('%s+$', '')
        return stripped
      end
    end
    i = i + 1
  end
  return text
end

---@param text string
---@return string
local function strip_quotes(text)
  if #text < 2 then
    return text
  end
  local first = text:sub(1, 1)
  local last = text:sub(-1)
  if first == "'" and last == "'" then
    local inner = text:sub(2, -2):gsub("''", "'")
    return inner
  end
  if first == '"' and last == '"' then
    local result = text:sub(2, -2)
    result = result:gsub('\\n', '\n')
    result = result:gsub('\\r', '\r')
    result = result:gsub('\\t', '\t')
    result = result:gsub('\\"', '"')
    result = result:gsub('\\\\', '\\')
    result = result:gsub('\\u(%x%x%x%x)', function(hex)
      local code = tonumber(hex, 16)
      if not code then
        return ''
      end
      if code < 128 then
        return string.char(code)
      end
      return vim.fn.nr2char(code)
    end)
    return result
  end
  return text
end

---Find the first colon that acts as a mapping separator.
---@param text string
---@return string? key
---@return string? value
local function split_key_value(text)
  local in_single = false
  local in_double = false
  local escaped = false
  local i = 1
  while i <= #text do
    local ch = text:sub(i, i)
    if in_double then
      if escaped then
        escaped = false
      elseif ch == '\\' then
        escaped = true
      elseif ch == '"' then
        in_double = false
      end
    elseif in_single then
      if ch == "'" then
        if text:sub(i + 1, i + 1) == "'" then
          i = i + 1
        else
          in_single = false
        end
      end
    else
      if ch == '"' then
        in_double = true
      elseif ch == "'" then
        in_single = true
      elseif ch == ':' then
        local next_ch = text:sub(i + 1, i + 1)
        if next_ch == '' or next_ch:match('%s') then
          local key = vim.trim(text:sub(1, i - 1))
          local value = vim.trim(text:sub(i + 1))
          return key, value
        end
      end
    end
    i = i + 1
  end
  return nil, nil
end

---Split a flow collection while respecting quotes.
---@param text string
---@param delimiter string
---@return string[]
local function split_flow(text, delimiter)
  local parts = {}
  local current = {}
  local in_single = false
  local in_double = false
  local escaped = false
  local depth = 0
  local i = 1

  while i <= #text do
    local ch = text:sub(i, i)
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
        if text:sub(i + 1, i + 1) == "'" then
          current[#current + 1] = "'"
          i = i + 1
        else
          in_single = false
        end
      end
    else
      if ch == '"' then
        in_double = true
        current[#current + 1] = ch
      elseif ch == "'" then
        in_single = true
        current[#current + 1] = ch
      elseif ch == '[' or ch == '{' then
        depth = depth + 1
        current[#current + 1] = ch
      elseif ch == ']' or ch == '}' then
        depth = depth - 1
        current[#current + 1] = ch
      elseif ch == delimiter and depth == 0 then
        parts[#parts + 1] = vim.trim(table.concat(current))
        current = {}
      else
        current[#current + 1] = ch
      end
    end
    i = i + 1
  end

  local tail = vim.trim(table.concat(current))
  if tail ~= '' then
    parts[#parts + 1] = tail
  end
  return parts
end

---@param value string
---@return any
local function parse_scalar(value)
  value = vim.trim(value)
  if value == '' then
    return nil
  end

  local first = value:sub(1, 1)
  local last = value:sub(-1)

  if first == '[' and last == ']' then
    local inner = vim.trim(value:sub(2, -2))
    if inner == '' then
      return {}
    end
    local list = {}
    for _, part in ipairs(split_flow(inner, ',')) do
      list[#list + 1] = parse_scalar(part)
    end
    return list
  end

  if first == '{' and last == '}' then
    local inner = vim.trim(value:sub(2, -2))
    local map = {}
    if inner == '' then
      return map
    end
    for _, part in ipairs(split_flow(inner, ',')) do
      local key, item = split_key_value(part)
      if key then
        map[strip_quotes(key)] = parse_scalar(item or '')
      end
    end
    return map
  end

  if (first == '"' and last == '"') or (first == "'" and last == "'") then
    return strip_quotes(value)
  end

  local lowered = value:lower()
  if lowered == 'true' then
    return true
  end
  if lowered == 'false' then
    return false
  end
  if lowered == 'null' or value == '~' then
    return nil
  end

  if value:match('^-?%d+$') then
    return tonumber(value)
  end
  if value:match('^-?%d+%.%d+$') then
    return tonumber(value)
  end

  return value
end

---@param lines string[]
---@return bruno.YamlParser
local function new_parser(lines)
  local parsed = {}
  for index, raw in ipairs(lines) do
    local line = raw:gsub('\r$', '')
    local indent = #(line:match('^%s*') or '')
    local text = line:sub(indent + 1)
    parsed[#parsed + 1] = {
      indent = indent,
      text = text,
      raw = line,
      number = index,
      blank = vim.trim(text) == '' or vim.trim(text):sub(1, 1) == '#',
    }
  end
  return { lines = parsed, index = 1 }
end

---@param parser bruno.YamlParser
---@return bruno.YamlLine?
local function peek(parser)
  while parser.index <= #parser.lines do
    local line = parser.lines[parser.index]
    if line.blank then
      parser.index = parser.index + 1
    elseif line.text == '---' or line.text == '...' then
      parser.index = parser.index + 1
    else
      return line
    end
  end
  return nil
end

---@param parser bruno.YamlParser
---@param parent_indent integer
---@return string
local function parse_block_scalar(parser, parent_indent)
  local content = {}
  local content_indent = nil

  while parser.index <= #parser.lines do
    local line = parser.lines[parser.index]
    if line.blank then
      content[#content + 1] = ''
      parser.index = parser.index + 1
    elseif line.indent > parent_indent then
      content[#content + 1] = line.raw
      if content_indent == nil or line.indent < content_indent then
        content_indent = line.indent
      end
      parser.index = parser.index + 1
    else
      break
    end
  end

  if content_indent == nil then
    content_indent = parent_indent + 2
  end

  local indent_to_strip = content_indent
  if indent_to_strip < parent_indent then
    indent_to_strip = parent_indent
  end

  local stripped = {}
  for i, line in ipairs(content) do
    if line == '' then
      stripped[i] = ''
    else
      stripped[i] = line:sub(indent_to_strip + 1)
    end
  end

  while #stripped > 0 and stripped[#stripped] == '' do
    table.remove(stripped)
  end

  return table.concat(stripped, '\n')
end

---@param parser bruno.YamlParser
---@param parent_indent integer
---@param indicator string
---@return any
local function parse_nested(parser, parent_indent, indicator)
  if indicator:match('^[|>][%+%-]?[1-9]?$') then
    local text = parse_block_scalar(parser, parent_indent)
    if indicator:sub(1, 1) == '>' then
      text = text:gsub('\n', ' '):gsub('%s+$', '')
    end
    if not indicator:find('%-', 1, true) then
      text = text .. '\n'
    end
    return text
  end

  local line = peek(parser)
  if not line or line.indent <= parent_indent then
    return nil
  end
  return M.parse_block(parser, line.indent)
end

---@param parser bruno.YamlParser
---@param indent integer
---@param map table
---@return table
local function parse_mapping_into(parser, indent, map)
  while true do
    local line = peek(parser)
    if not line or line.indent < indent then
      break
    end
    if line.indent > indent then
      break
    end
    if line.text:sub(1, 1) == '-' and (line.text == '-' or line.text:sub(2, 2):match('%s')) then
      break
    end

    local text = strip_inline_comment(line.text)
    local key, value = split_key_value(text)
    if not key then
      peek(parser)
      parser.index = parser.index + 1
    else
      parser.index = parser.index + 1
      local clean_key = strip_quotes(vim.trim(key))
      if value == nil or value == '' then
        map[clean_key] = parse_nested(parser, indent, '')
      elseif value:match('^[|>][%+%-]?[1-9]?$') then
        map[clean_key] = parse_nested(parser, indent, value)
      else
        map[clean_key] = parse_scalar(value)
      end
    end
  end
  return map
end

---@param parser bruno.YamlParser
---@param indent integer
---@return table
local function parse_sequence(parser, indent)
  local result = {}

  while true do
    local line = peek(parser)
    if not line or line.indent < indent then
      break
    end
    if line.indent > indent then
      break
    end
    if not (line.text == '-' or line.text:sub(1, 2) == '- ') then
      break
    end

    local rest = vim.trim(line.text:sub(2))
    parser.index = parser.index + 1

    if rest == '' then
      local next_line = peek(parser)
      if next_line and next_line.indent > indent then
        result[#result + 1] = M.parse_block(parser, next_line.indent)
      else
        result[#result + 1] = nil
      end
    else
      local key, value = split_key_value(strip_inline_comment(rest))
      if key then
        local item = {}
        local clean_key = strip_quotes(vim.trim(key))
        if value == nil or value == '' then
          item[clean_key] = parse_nested(parser, indent + 2, '')
        elseif value:match('^[|>][%+%-]?[1-9]?$') then
          item[clean_key] = parse_nested(parser, indent + 2, value)
        else
          item[clean_key] = parse_scalar(value)
        end
        parse_mapping_into(parser, indent + 2, item)
        result[#result + 1] = item
      else
        result[#result + 1] = parse_scalar(rest)
      end
    end
  end

  return result
end

---Parse the block starting at `indent`.
---@param parser bruno.YamlParser
---@param indent integer
---@return any
function M.parse_block(parser, indent)
  local line = peek(parser)
  if not line then
    return nil
  end
  if line.indent < indent then
    return nil
  end
  if line.text == '-' or line.text:sub(1, 2) == '- ' then
    return parse_sequence(parser, line.indent)
  end
  return parse_mapping_into(parser, line.indent, {})
end

---Parse a YAML document.
---@param raw string
---@return table|nil doc
---@return string? err
function M.parse(raw)
  if type(raw) ~= 'string' then
    return nil, 'expected a string'
  end

  local lines = vim.split(raw:gsub('\r\n', '\n'):gsub('\r', '\n'), '\n', { plain = true })
  local parser = new_parser(lines)
  local ok, result = pcall(function()
    local first = peek(parser)
    if not first then
      return {}
    end
    return M.parse_block(parser, first.indent)
  end)

  if not ok then
    return nil, tostring(result)
  end

  if result == nil then
    result = {}
  end

  return result, nil
end

---Parse a YAML document into a flat string map. Useful for environment files.
---@param raw string
---@return table<string, string>
function M.parse_string_map(raw)
  local doc = M.parse(raw) or {}
  local result = {}
  if type(doc) ~= 'table' then
    return result
  end
  for key, value in pairs(doc) do
    if type(value) ~= 'table' then
      result[tostring(key)] = value == nil and '' or tostring(value)
    end
  end
  return result
end

M._internal = {
  split_key_value = split_key_value,
  parse_scalar = parse_scalar,
  strip_inline_comment = strip_inline_comment,
  split_flow = split_flow,
}

return M
