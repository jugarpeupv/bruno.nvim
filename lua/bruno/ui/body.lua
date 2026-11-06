local M = {}

local log = require('bruno.utils.log')

---@type table<integer, string>
local temp_files = {}

---@param value any
---@return string
local function body_text(value)
  if value == nil or value == vim.NIL then
    return ''
  end
  if type(value) == 'table' then
    return require('bruno.utils.json').pretty(value)
  end
  return tostring(value)
end

---@param headers any
---@param name string
---@return string?
local function header(headers, name)
  if type(headers) ~= 'table' then
    return nil
  end
  for key, value in pairs(headers) do
    if type(key) == 'string' and key:lower() == name and value ~= nil and value ~= vim.NIL then
      return tostring(value)
    end
  end
  return nil
end

---@param response table
---@return string?
local function content_type(response)
  return header(response.headers, 'content-type')
end

---@param response table
---@return boolean
function M.is_image(response)
  local value = content_type(response)
  if not value then
    return false
  end
  local lowered = value:lower()
  return lowered:find('image/', 1, true) ~= nil
end

---@param response table
---@return boolean
function M.is_json(response)
  if type(response.data) == 'table' then
    return true
  end
  local value = content_type(response)
  if value and value:lower():find('json', 1, true) then
    return true
  end
  local body = body_text(response.data)
  return require('bruno.utils.json').looks_like_json(body)
end

---@param response table
---@return string
function M.text(response)
  return body_text(response.data)
end

---Run `jq <query>` over `body`.
---@param body string
---@param query string
---@return string? output
---@return string? err
function M.jq(body, query)
  if body == '' then
    return body
  end
  local ok, result = pcall(function()
    return vim.system({ 'jq', query }, { stdin = body, text = true }):wait(5000)
  end)
  if not ok then
    return nil, tostring(result)
  end
  if result.code ~= 0 then
    return nil, ((result.stderr or ''):gsub('%s+$', ''))
  end
  return ((result.stdout or ''):gsub('%s+$', ''))
end

---@param body string
---@return string[]
function M.hex_lines(body)
  local lines = {}
  local length = #body
  local offset = 0
  while offset < length do
    local bytes = { string.byte(body, offset + 1, math.min(offset + 16, length)) }
    local hex = {}
    local ascii = {}
    for index = 1, 16 do
      local byte = bytes[index]
      if byte then
        hex[#hex + 1] = string.format('%02x', byte)
        ascii[#ascii + 1] = byte >= 32 and byte <= 126 and string.char(byte) or '.'
      else
        hex[#hex + 1] = '  '
      end
      if index == 8 then
        hex[#hex + 1] = ''
      end
    end
    lines[#lines + 1] = string.format('%08x  %s |%s|', offset, table.concat(hex, ' '), table.concat(ascii))
    offset = offset + 16
  end
  return lines
end

---@param body string
---@return string[]
function M.binary_lines(body)
  local lines = {}
  local current = {}
  for index = 1, #body do
    local byte = body:byte(index)
    for bit = 7, 0, -1 do
      current[#current + 1] = (byte % (2 ^ (bit + 1)) >= 2 ^ bit) and '1' or '0'
    end
    if #current >= 64 then
      lines[#lines + 1] = table.concat(current)
      current = {}
    end
  end
  if #current > 0 then
    lines[#lines + 1] = table.concat(current)
  end
  return lines
end

---@param body string
---@param extension string
---@return string
local function write_temp(body, extension)
  local path = vim.fn.tempname() .. extension
  local file = io.open(path, 'wb')
  if not file then
    return path
  end
  file:write(body)
  file:close()
  return path
end

---@param bytes string
---@return string?
local function image_extension(bytes)
  if bytes:sub(1, 8) == '\137PNG\r\n\26\n' then
    return '.png'
  end
  if bytes:sub(1, 3) == '\255\216\255' then
    return '.jpg'
  end
  if bytes:sub(1, 4) == 'GIF8' then
    return '.gif'
  end
  if bytes:sub(1, 4) == 'RIFF' and bytes:sub(9, 12) == 'WEBP' then
    return '.webp'
  end
  if bytes:sub(1, 2) == 'BM' then
    return '.bmp'
  end
  return nil
end

---Download the response URL with the same request details, used when the
---Bruno CLI JSON output did not preserve the original binary bytes.
---@param request bruno.Request
---@return string? path
---@return string? err
local function download(request)
  local env = require('bruno.env').ensure(request.root)
  local oauth2 = require('bruno.oauth2')
  local token, config = oauth2.cached_token(request, env)
  local command = require('bruno.curl').build(request, { env = env, token = token, oauth2 = config })

  local path = vim.fn.tempname() .. '.download'
  local out = vim
    .system({ 'sh', '-c', command .. ' -sS -L -o ' .. vim.fn.shellescape(path) }, { text = true })
    :wait(20000)
  if out.code ~= 0 or vim.fn.filereadable(path) ~= 1 then
    return nil, ((out.stderr or ''):gsub('%s+$', ''))
  end
  return path, nil
end

---Resolve a filesystem path with the image bytes for the response.
---@param response table
---@param request? bruno.Request
---@return string? path
---@return string? err
local function image_path(response, request)
  local body = body_text(response.data)
  local extension = image_extension(body)
  if extension then
    return write_temp(body, extension), nil
  end

  if request then
    local path, err = download(request)
    if path then
      local handle = io.open(path, 'rb')
      local head = handle and handle:read(16) or ''
      if handle then
        handle:close()
      end
      local detected = image_extension(head)
      if detected then
        os.rename(path, path .. detected)
        return path .. detected, nil
      end
      os.remove(path)
    else
      return nil, err
    end
  end

  return nil, 'response body does not contain image data'
end

---Clear any inline images rendered for the buffer.
---@param bufnr integer
function M.clear(bufnr)
  local ok, image = pcall(require, 'image')
  if not ok then
    return
  end
  local listed, images = pcall(image.get_images, { buffer = bufnr })
  if not listed or type(images) ~= 'table' then
    return
  end
  for _, img in ipairs(images) do
    pcall(img.clear, img)
  end
end

---Render the response image inline with image.nvim, if available.
---@param bufnr integer
---@param win integer
---@param ui_state bruno.UIState
---@return boolean rendered
---@return string? err
function M.render(bufnr, win, ui_state)
  local result = ui_state.result
  local first = result and result.results[1]
  local response = first and first.response or nil
  if not response then
    return false, 'no response'
  end

  local path, err = image_path(response, ui_state.request)
  if not path then
    return false, err
  end

  if temp_files[bufnr] and temp_files[bufnr] ~= path then
    pcall(os.remove, temp_files[bufnr])
  end
  temp_files[bufnr] = path

  M.clear(bufnr)

  local ok, image = pcall(require, 'image')
  if not ok then
    return false, 'image.nvim is not installed'
  end

  -- Anchor the image to the workbench window at the `## BODY` heading so it is
  -- not drawn over whatever window happened to be current.
  local row = 0
  for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match('^## BODY') then
      row = index
    end
  end

  local created, img = pcall(image.from_file, path, {
    window = win,
    buffer = bufnr,
    x = 2,
    y = math.max(row - 1, 0),
  })
  if not created then
    return false, tostring(img)
  end
  if not img then
    return false, 'image.nvim could not load the image'
  end
  local shown = pcall(function()
    img:render()
  end)
  if not shown then
    return false, 'could not render the image'
  end
  log.info('Bruno: rendered response image inline')
  return true, nil
end

---@param bufnr integer
function M.cleanup(bufnr)
  M.clear(bufnr)
  local path = temp_files[bufnr]
  if path then
    pcall(os.remove, path)
    temp_files[bufnr] = nil
  end
end

return M
