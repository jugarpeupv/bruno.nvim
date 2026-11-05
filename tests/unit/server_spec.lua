local server = require('bruno.oauth2.server')

---@return integer
local function free_port()
  local tcp = vim.uv.new_tcp()
  tcp:bind('127.0.0.1', 0)
  local port = tcp:getsockname().port
  tcp:close()
  return port
end

describe('oauth2.server', function()
  it('receives loopback callbacks', function()
    local port = free_port()
    local received
    local instance, err = server.listen({ host = '127.0.0.1', port = port, path = '/callback' }, function(request)
      received = request
      return { status = 200, body = '<h1>ok</h1>' }
    end)
    truthy(instance, err)
    instance:set_timeout(5000, function()
      received = { path = '/timeout' }
    end)

    vim.defer_fn(function()
      vim.system({ 'curl', '-sS', ('http://127.0.0.1:%d/callback?code=abc&state=xyz'):format(port) }, { text = true })
    end, 50)

    vim.wait(3000, function()
      return received ~= nil
    end)

    truthy(received)
    eq('GET', received.method)
    eq('/callback', received.path)
    eq({ 'abc' }, received.params.code)
    eq({ 'xyz' }, received.params.state)
    instance:stop()
  end)

  it('serves the implicit-flow capture page', function()
    local port = free_port()
    local instance, err = server.listen({ host = '127.0.0.1', port = port, path = '/callback' }, function()
      return { status = 200, body = server.implicit_capture_html('/_bruno/token') }
    end)
    truthy(instance, err)

    local output = ''
    vim.defer_fn(function()
      vim.system({ 'curl', '-sS', ('http://127.0.0.1:%d/callback'):format(port) }, { text = true }, function(result)
        vim.schedule(function()
          output = result.stdout or ''
        end)
      end)
    end, 50)

    vim.wait(3000, function()
      return output ~= ''
    end)

    match(output, '/_bruno/token')
    match(output, 'location%.hash')
    instance:stop()
  end)
end)
