local Json = require('bruno.utils.json')
local Server = require('bruno.oauth2.server')
local url = require('bruno.utils.url')

local M = {}

---@return integer
function M.free_port()
  local tcp = vim.uv.new_tcp()
  tcp:bind('127.0.0.1', 0)
  local port = tcp:getsockname().port
  tcp:close()
  return port
end

---@class bruno.MockOAuthServer
---@field url string
---@field requests table[]
---@field get_authorize fun(): table?
---@field stop fun()

---Start a minimal OAuth2 provider for tests.
---@param opts? { token_response?: table, code?: string }
---@return bruno.MockOAuthServer
function M.start(opts)
  opts = opts or {}
  local requests = {}
  local authorize
  local instance

  instance = assert(Server.listen({ host = '127.0.0.1', port = 0 }, function(request)
    if request.path == '/authorize' then
      authorize = request.params
      local redirect_uri = request.params.redirect_uri and request.params.redirect_uri[1] or ''
      local state = request.params.state and request.params.state[1] or ''
      local separator = redirect_uri:find('?', 1, true) and '&' or '?'
      return {
        status = 302,
        headers = {
          Location = redirect_uri
            .. separator
            .. url.encode_pairs({ { 'code', opts.code or 'auth-code-123' }, { 'state', state } }),
        },
      }
    end

    if request.path == '/token' then
      local body = url.parse_query(request.body)
      requests[#requests + 1] = {
        body = body,
        headers = request.headers,
      }
      local response = opts.token_response
        or {
          access_token = 'mock-access-token',
          refresh_token = 'mock-refresh-token',
          expires_in = 3600,
          token_type = 'Bearer',
          scope = 'read write',
        }
      return {
        status = 200,
        content_type = 'application/json',
        body = Json.encode(response),
      }
    end

    return { status = 404, body = 'not found' }
  end))

  local port = instance:port_number()
  return {
    url = 'http://127.0.0.1:' .. tostring(port),
    requests = requests,
    get_authorize = function()
      return authorize
    end,
    stop = function()
      instance:stop()
    end,
  }
end

return M
