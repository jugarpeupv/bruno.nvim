local M = {}

---@param hex string
---@return string
local function hex_to_bytes(hex)
  local bytes = {}
  for i = 1, #hex, 2 do
    bytes[#bytes + 1] = string.char(tonumber(hex:sub(i, i + 1), 16))
  end
  return table.concat(bytes)
end

---Base64 URL encoding (RFC 4648 section 5).
---@param data string
---@return string
function M.base64url(data)
  local encoded = vim.base64.encode(data):gsub('+', '-'):gsub('/', '_'):gsub('=+$', '')
  return encoded
end

---@param value string
---@return string
function M.sha256(value)
  return hex_to_bytes(vim.fn.sha256(value))
end

---Generate a PKCE code verifier.
---@param bytes? integer
---@return string
function M.verifier(bytes)
  bytes = bytes or 64
  local random = vim.uv.random(bytes)
  if not random then
    local fd = io.open('/dev/urandom', 'rb')
    if fd then
      random = fd:read(bytes)
      fd:close()
    end
  end
  random = random or tostring(vim.uv.hrtime())
  return M.base64url(random)
end

---Create a PKCE challenge.
---@param verifier string
---@param method? 'S256'|'plain'
---@return string
function M.challenge(verifier, method)
  if method == 'plain' or method == 'Plain' then
    return verifier
  end
  return M.base64url(M.sha256(verifier))
end

---Generate an opaque OAuth2 state value.
---@return string
function M.state()
  return M.base64url(vim.uv.random(24) or tostring(vim.uv.hrtime()))
end

---Decode a base64url string.
---@param value string
---@return string?
function M.base64url_decode(value)
  local padded = value:gsub('-', '+'):gsub('_', '/'):gsub('=', '')
  local remainder = #padded % 4
  if remainder == 2 then
    padded = padded .. '=='
  elseif remainder == 3 then
    padded = padded .. '='
  end
  local ok, decoded = pcall(vim.base64.decode, padded)
  if ok then
    return decoded
  end
  return nil
end

return M
