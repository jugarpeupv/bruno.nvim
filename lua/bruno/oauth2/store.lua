local fs = require('bruno.utils.fs')
local json = require('bruno.utils.json')

local M = {}

---@type string?
local path_override = nil

---@return string
function M.default_path()
  return vim.fn.stdpath('cache') .. '/bruno.nvim/oauth2.json'
end

---@return string
function M.path()
  return path_override or M.default_path()
end

---@param path? string
function M.set_path(path)
  path_override = path
end

---@return table<string, bruno.Token>
function M.load()
  local path = M.path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local raw = fs.read_file(path)
  if not raw or raw == '' then
    return {}
  end
  local data = json.decode(raw)
  if type(data) ~= 'table' then
    return {}
  end
  return data
end

---@param data table<string, bruno.Token>
---@return boolean ok
---@return string? err
function M.save(data)
  local path = M.path()
  if not fs.mkdir(vim.fn.fnamemodify(path, ':h')) then
    return false, 'could not create cache directory'
  end
  return fs.write_file(path, json.pretty(data), 384)
end

---Build a stable cache key for an OAuth2 configuration.
---@param request bruno.Request
---@param config bruno.OAuth2Config
---@param env? string
---@return string
function M.key(request, config, env)
  local parts = {
    request.root or '',
    env or '',
    config.credentials_id or '',
    config.client_id or '',
    config.access_token_url or config.authorization_url or '',
  }
  return vim.fn.sha256(table.concat(parts, '\0'))
end

---@param key string
---@return bruno.Token?
function M.get(key)
  local data = M.load()
  return data[key]
end

---@param key string
---@param token bruno.Token
---@return boolean ok
---@return string? err
function M.set(key, token)
  local data = M.load()
  data[key] = token
  return M.save(data)
end

---@param key string
---@return boolean
function M.delete(key)
  local data = M.load()
  if data[key] == nil then
    return false
  end
  data[key] = nil
  M.save(data)
  return true
end

---@return boolean
function M.clear()
  local path = M.path()
  if vim.fn.filereadable(path) == 1 then
    fs.unlink(path)
  end
  return true
end

---@param token bruno.Token
---@param leeway? integer
---@return boolean
function M.is_expired(token, leeway)
  if not token or not token.expires_at then
    return false
  end
  leeway = leeway or 0
  return (tonumber(token.expires_at) or 0) - leeway <= os.time()
end

---@param token bruno.Token
---@return integer?
function M.remaining(token)
  if not token or not token.expires_at then
    return nil
  end
  return (tonumber(token.expires_at) or 0) - os.time()
end

return M
