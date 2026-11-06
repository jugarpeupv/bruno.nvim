local parsers = require('bruno.parsers')
local runner = require('bruno.runner')
local session = require('bruno.session_vars')

local root = vim.fn.getcwd() .. '/tests/fixtures'

---@return bruno.RunResult
local function result_with(data)
  return {
    results = { { response = { status = 200, data = data } } },
    raw = '',
    data = {},
    summary = {},
    stdout = '',
    stderr = '',
    code = 0,
    env = 'Local',
  }
end

describe('session_vars', function()
  it('extracts simple bru.setVar assignments from the response', function()
    session.reset()
    local vars = session.extract(
      [[
        if (res.getStatus() === 200) {
          bru.setVar("BRUNO_ACCESS_TOKEN", res.getBody().accessToken);
          bru.setVar("BRUNO_REFRESH_TOKEN", res.getBody().refreshToken);
        }
      ]],
      { status = 200, data = { accessToken = 'access-123', refreshToken = 'refresh-456' } }
    )

    eq('access-123', vars.BRUNO_ACCESS_TOKEN)
    eq('refresh-456', vars.BRUNO_REFRESH_TOKEN)
    session.reset()
  end)

  it('detects authentication variables and masks them', function()
    truthy(session.is_sensitive('BRUNO_ACCESS_TOKEN'))
    truthy(session.is_sensitive('BRUNO_REFRESH_TOKEN'))
    truthy(session.is_sensitive('BRUNO_ADMIN_PASSWORD'))
    truthy(session.is_sensitive('api_key'))
    falsy(session.is_sensitive('BRUNO_CUSTOMER_ID'))
    eq('********', session.display_value('BRUNO_ACCESS_TOKEN', 'secret'))
    eq('42', session.display_value('BRUNO_CUSTOMER_ID', '42'))
  end)

  it('remembers variables per collection and environment', function()
    session.reset()
    local request = {
      root = '/tmp/bruno-session-test',
      path = '/tmp/bruno-session-test/login.yml',
      script = { post = 'bru.setVar("TOKEN", res.getBody().token);' },
    }

    session.remember(request, 'Local', result_with({ token = 'abc' }))

    eq('abc', session.get(request.root, 'Local').TOKEN)
    eq(nil, session.get(request.root, 'prod').TOKEN)
    eq(nil, session.get('/tmp/other', 'Local').TOKEN)

    session.forget(request.root)
    eq(nil, session.get(request.root, 'Local').TOKEN)
    session.reset()
  end)

  it('injects remembered variables into the bru command', function()
    session.reset()
    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')

    session.remember(
      { root = request.root, path = request.path, script = { post = 'bru.setVar("TOKEN", res.getBody().token);' } },
      'Local',
      result_with({ token = 'abc' })
    )

    local args = session.args(request, 'Local')
    eq({ '--env-var', 'TOKEN=abc' }, args)

    local command = runner.build_command(request, 'Local', {})
    truthy(vim.tbl_contains(command, '--env-var'))
    truthy(vim.tbl_contains(command, 'TOKEN=abc'))

    session.reset()
  end)
end)
