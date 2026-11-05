local url_util = require('bruno.utils.url')

local M = {}

---@class bruno.OAuthServerRequest
---@field method string
---@field path string
---@field query string?
---@field params table<string, string[]>
---@field headers table<string, string>
---@field body string

---@class bruno.OAuthServerResponse
---@field status? integer
---@field body? string
---@field content_type? string

---@class bruno.OAuthServer
---@field host string
---@field port integer
---@field path string
---@field tcp table
---@field clients table[]
---@field timer? table
---@field stopped boolean
---@field handler fun(req: bruno.OAuthServerRequest): bruno.OAuthServerResponse
---@field stop fun(self: bruno.OAuthServer)
---@field clear_timeout fun(self: bruno.OAuthServer)
---@field set_timeout fun(self: bruno.OAuthServer, ms: integer, callback: fun())
---@field port_number fun(self: bruno.OAuthServer): integer

local Server = {}
Server.__index = Server

---@param text string
---@return string
function M.html_escape(text)
  return (tostring(text):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'):gsub("'", '&#39;'))
end

---@param title string
---@param message string
---@param extra? string
---@return string
function M.html_page(title, message, extra)
  return table.concat({
    '<!doctype html>',
    '<html lang="en">',
    '<head>',
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<title>' .. M.html_escape(title) .. '</title>',
    '<style>',
    'body{font-family:ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;',
    'background:#101014;color:#e7e7ea;display:grid;place-items:center;min-height:100vh;margin:0}',
    'main{max-width:34rem;padding:2.5rem;border:1px solid #2d2d35;border-radius:1rem;background:#17171c}',
    'h1{font-size:1.35rem;margin:0 0 .75rem}p{line-height:1.55;color:#b8b8c2;margin:0}',
    'code{background:#24242b;padding:.15rem .35rem;border-radius:.3rem}',
    '</style>',
    '</head>',
    '<body><main><h1>' .. M.html_escape(title) .. '</h1><p>' .. message .. '</p></main>',
    extra or '',
    '</body></html>',
  }, '\n')
end

---@param message string
---@return string
function M.success_html(message)
  return M.html_page('Authentication complete', message or 'You can close this window and return to Neovim.')
end

---@param message string
---@return string
function M.error_html(message)
  return M.html_page('Authentication failed', M.html_escape(message))
end

---@param token_path string
---@return string
function M.implicit_capture_html(token_path)
  local script = table.concat({
    '<script>',
    '(function(){',
    '  var hash = window.location.hash ? window.location.hash.substring(1) : "";',
    '  if (!hash) {',
    '    document.querySelector("p").textContent = "No token was returned by the provider.";',
    '    return;',
    '  }',
    '  fetch(' .. vim.json.encode(token_path) .. ' + "?" + hash, {cache: "no-store"})',
    '    .then(function(){',
    '      document.querySelector("h1").textContent = "Authentication complete";',
    '      document.querySelector("p").textContent = "You can close this window and return to Neovim.";',
    '    })',
    '    .catch(function(err){',
    '      document.querySelector("p").textContent = "Could not deliver the token: " + err;',
    '    });',
    '})();',
    '</script>',
  }, '\n')
  return M.html_page('Finishing authentication', 'Waiting for the provider response…', script)
end

---@param headers string
---@return table<string, string>
local function parse_headers(headers)
  local result = {}
  for line in headers:gmatch('[^\r\n]+') do
    local name, value = line:match('^([^:]+):%s*(.*)$')
    if name then
      result[name:lower()] = value
    end
  end
  return result
end

---@param self bruno.OAuthServer
---@param client table
local function close_client(self, client)
  for index, candidate in ipairs(self.clients) do
    if candidate == client then
      table.remove(self.clients, index)
      break
    end
  end
  pcall(function()
    client:read_stop()
  end)
  pcall(function()
    client:close()
  end)
end

---@param self bruno.OAuthServer
---@param client table
---@param response table
local function send_response(self, client, response)
  local status = response.status or 200
  local reason = status == 200 and 'OK'
    or (status == 204 and 'No Content' or (status == 302 and 'Found' or (status == 404 and 'Not Found' or 'Error')))
  local body = response.body or ''
  local content_type = response.content_type or 'text/html; charset=utf-8'
  local header_lines = {
    'HTTP/1.1 ' .. tostring(status) .. ' ' .. reason,
    'Content-Type: ' .. content_type,
    'Content-Length: ' .. tostring(#body),
    'Cache-Control: no-store',
    'Connection: close',
  }
  for name, value in pairs(response.headers or {}) do
    header_lines[#header_lines + 1] = tostring(name) .. ': ' .. tostring(value)
  end
  header_lines[#header_lines + 1] = ''
  header_lines[#header_lines + 1] = body
  local payload = table.concat(header_lines, '\r\n')

  pcall(function()
    client:write(payload, function()
      close_client(self, client)
    end)
  end)
end

---@param self bruno.OAuthServer
---@param client table
local function handle_client(self, client)
  local chunks = {}

  client:read_start(function(err, data)
    if self.stopped then
      close_client(self, client)
      return
    end
    if err then
      close_client(self, client)
      return
    end
    if data then
      chunks[#chunks + 1] = data
    end

    local raw = table.concat(chunks)
    if #raw > 1 << 20 then
      close_client(self, client)
      return
    end

    local header_end = raw:find('\r\n\r\n', 1, true)
    if not header_end then
      return
    end

    local header_text = raw:sub(1, header_end - 1)
    local body = raw:sub(header_end + 4)
    local first_line = header_text:match('^([^\r\n]+)')
    if not first_line then
      close_client(self, client)
      return
    end

    local method, target = first_line:match('^(%u+)%s+(%S+)')
    if not method or not target then
      send_response(self, client, { status = 400, body = M.error_html('Malformed request') })
      return
    end

    local headers = parse_headers(header_text)
    local content_length = tonumber(headers['content-length'] or '0') or 0
    if content_length > 0 and #body < content_length then
      return
    end

    pcall(function()
      client:read_stop()
    end)

    local path, query = target:match('^([^?]*)%??(.*)$')
    local request = {
      method = method,
      path = path or target,
      query = query,
      params = url_util.parse_query(query),
      headers = headers,
      body = body,
    }

    local ok, response = pcall(self.handler, request)
    if not ok then
      send_response(self, client, {
        status = 500,
        body = M.error_html('Internal error while handling the OAuth2 callback.'),
      })
      return
    end

    send_response(self, client, response or { status = 404, body = M.error_html('Not found') })
  end)
end

---Start a loopback HTTP server. Only loopback hosts are accepted.
---@param opts { host: string, port: integer, path?: string }
---@param handler fun(req: bruno.OAuthServerRequest): bruno.OAuthServerResponse
---@return bruno.OAuthServer? server
---@return string? err
function M.listen(opts, handler)
  local host = opts.host or '127.0.0.1'
  if host ~= '127.0.0.1' and host ~= 'localhost' and host ~= '::1' then
    return nil, 'OAuth2 callback server only supports loopback addresses'
  end

  local tcp = vim.uv.new_tcp()
  if not tcp then
    return nil, 'could not create a TCP handle'
  end

  ---@type bruno.OAuthServer?
  local server

  local ok, err = pcall(function()
    local bound = tcp:bind(host, opts.port)
    if bound ~= 0 and bound ~= true then
      error('could not bind ' .. host .. ':' .. tostring(opts.port) .. ': ' .. tostring(bound))
    end
    local listening = tcp:listen(128, function(accept_err)
      if accept_err then
        return
      end
      local client = vim.uv.new_tcp()
      if not client then
        return
      end
      local accepted = pcall(function()
        tcp:accept(client)
      end)
      if not accepted then
        pcall(function()
          client:close()
        end)
        return
      end
      if server and not server.stopped then
        server.clients[#server.clients + 1] = client
        handle_client(server, client)
      else
        pcall(function()
          client:close()
        end)
      end
    end)
    if listening ~= 0 and listening ~= true then
      error('could not listen on ' .. host .. ':' .. tostring(opts.port) .. ': ' .. tostring(listening))
    end
  end)

  if not ok then
    pcall(function()
      tcp:close()
    end)
    return nil, tostring(err)
  end

  ---@type bruno.OAuthServer
  server = setmetatable({
    host = host,
    port = opts.port,
    path = opts.path or '/callback',
    tcp = tcp,
    clients = {},
    timer = nil,
    stopped = false,
    handler = handler,
  }, Server)

  M._last_server = server
  return server, nil
end

function Server:port_number()
  local sockname = self.tcp:getsockname()
  if type(sockname) == 'table' and sockname.port then
    return sockname.port
  end
  return self.port
end

---@param ms integer
---@param callback fun()
function Server:set_timeout(ms, callback)
  self:clear_timeout()
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  self.timer = timer
  timer:start(ms, 0, function()
    vim.schedule(function()
      if self.stopped then
        return
      end
      self:stop()
      callback()
    end)
  end)
end

function Server:clear_timeout()
  if self.timer then
    pcall(function()
      self.timer:stop()
    end)
    pcall(function()
      self.timer:close()
    end)
    self.timer = nil
  end
end

function Server:stop()
  if self.stopped then
    return
  end
  self.stopped = true
  self:clear_timeout()

  for _, client in ipairs(self.clients) do
    pcall(function()
      client:read_stop()
    end)
    pcall(function()
      client:close()
    end)
  end
  self.clients = {}

  pcall(function()
    self.tcp:close()
  end)

  if M._last_server == self then
    M._last_server = nil
  end
end

---@type bruno.OAuthServer?
M._last_server = nil

return M
