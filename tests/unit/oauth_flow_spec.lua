local parsers = require('bruno.parsers')
local store = require('bruno.oauth2.store')
local oauth2 = require('bruno.oauth2')
local mock_oauth = require('tests.support.mock_oauth')

local root = vim.fn.getcwd() .. '/tests/fixtures'

describe('oauth2 authorization code flow', function()
  it('opens the browser, receives the callback and exchanges the code', function()
    local mock = mock_oauth.start()
    local callback_port = mock_oauth.free_port()

    require('bruno').setup({
      notify = false,
      oauth2 = {
        cache = true,
        open_browser = true,
        browser_cmd = { 'curl', '-sS', '-L' },
        callback_timeout = 5000,
        token_timeout = 5000,
      },
    })

    local store_path = vim.fn.tempname() .. '-oauth2.json'
    store.set_path(store_path)

    local request = parsers.parse_request(root .. '/bru-collection/requests/oauth2.bru')
    local config = request.auth.config
    config.authorization_url = mock.url .. '/authorize'
    config.access_token_url = mock.url .. '/token'
    config.refresh_token_url = mock.url .. '/token'
    config.callback_url = ('http://127.0.0.1:%d/callback'):format(callback_port)
    config.state = nil
    config.pkce = true
    config.credentials_placement = 'body'
    config.auto_refresh_token = true

    local done = false
    local token
    local err
    oauth2.login(request, {}, function(value, failure)
      token = value
      err = failure
      done = true
    end)

    vim.wait(8000, function()
      return done
    end)

    truthy(done, 'login timed out')
    truthy(token, err)
    eq('mock-access-token', token.access_token)
    eq('mock-refresh-token', token.refresh_token)
    truthy(token.expires_at)

    local authorize = mock.get_authorize()
    truthy(authorize)
    eq({ 'code' }, authorize.response_type)
    eq({ 'S256' }, authorize.code_challenge_method)
    eq({ 'client-id' }, authorize.client_id)
    truthy(authorize.state)
    truthy(authorize.code_challenge)

    eq(1, #mock.requests)
    local exchange = mock.requests[1].body
    eq({ 'authorization_code' }, exchange.grant_type)
    eq({ 'auth-code-123' }, exchange.code)
    truthy(exchange.code_verifier)
    eq({ 'client-id' }, exchange.client_id)
    eq({ 'client-secret' }, exchange.client_secret)

    -- Force expiry and verify that the refresh token is used.
    token.expires_at = os.time() - 10
    local _, key = oauth2.config(request, nil)
    store.set(key, token)

    done = false
    oauth2.ensure_token(request, {}, function(value, failure)
      token = value
      err = failure
      done = true
    end)

    vim.wait(8000, function()
      return done
    end)

    truthy(done, 'refresh timed out')
    truthy(token, err)
    eq(2, #mock.requests)
    eq({ 'refresh_token' }, mock.requests[2].body.grant_type)
    eq({ 'mock-refresh-token' }, mock.requests[2].body.refresh_token)

    mock.stop()
    store.set_path(nil)
    os.remove(store_path)
  end)

  it('clears every cached token', function()
    local store_path = vim.fn.tempname() .. '-oauth2.json'
    store.set_path(store_path)
    store.set('one', { access_token = 'a' })
    store.set('two', { access_token = 'b' })

    oauth2.clear()

    local remaining = store.load()
    eq(0, vim.tbl_count(remaining))

    store.set_path(nil)
    os.remove(store_path)
  end)

  it('falls back to the loopback server for an unresolved callback URL', function()
    local mock = mock_oauth.start()
    local callback_port = mock_oauth.free_port()
    local default_callback_url = ('http://127.0.0.1:%d/callback'):format(callback_port)

    require('bruno').setup({
      notify = false,
      oauth2 = {
        cache = true,
        open_browser = true,
        browser_cmd = { 'curl', '-sS', '-L' },
        callback_timeout = 5000,
        token_timeout = 5000,
        default_callback_url = default_callback_url,
      },
    })

    local store_path = vim.fn.tempname() .. '-oauth2.json'
    store.set_path(store_path)

    local request = parsers.parse_request(root .. '/bru-collection/requests/oauth2.bru')
    local config = request.auth.config
    config.authorization_url = mock.url .. '/authorize'
    config.access_token_url = mock.url .. '/token'
    config.refresh_token_url = mock.url .. '/token'
    config.callback_url = '{{AUTH_CALLBACK_URL}}'
    config.state = nil
    config.pkce = true
    config.credentials_placement = 'body'

    local done = false
    local token
    local err
    oauth2.login(request, {}, function(value, failure)
      token = value
      err = failure
      done = true
    end)

    vim.wait(8000, function()
      return done
    end)

    truthy(done, 'login timed out')
    truthy(token, err)

    local authorize = mock.get_authorize()
    truthy(authorize)
    eq({ default_callback_url }, authorize.redirect_uri)

    mock.stop()
    store.set_path(nil)
    os.remove(store_path)
  end)

  it('supports client credentials', function()
    local mock = mock_oauth.start({
      token_response = { access_token = 'client-token', expires_in = 3600, token_type = 'Bearer' },
    })
    require('bruno').setup({
      notify = false,
      oauth2 = {
        cache = true,
        open_browser = false,
        callback_timeout = 5000,
        token_timeout = 5000,
      },
    })
    local store_path = vim.fn.tempname() .. '-oauth2.json'
    store.set_path(store_path)

    local request = parsers.parse_request(root .. '/bru-collection/oauth-folder/inherit.bru')
    local auth = parsers.resolve_auth(request)
    truthy(auth)
    local config = vim.deepcopy(auth.config)
    config.access_token_url = mock.url .. '/token'
    request.auth = { mode = 'oauth2', config = config }

    local done = false
    local token
    local err
    oauth2.ensure_token(request, {}, function(value, failure)
      token = value
      err = failure
      done = true
    end)
    vim.wait(5000, function()
      return done
    end)

    truthy(done)
    truthy(token, err)
    eq('client-token', token.access_token)
    eq(1, #mock.requests)
    eq({ 'client_credentials' }, mock.requests[1].body.grant_type)
    eq({ 'folder-client' }, mock.requests[1].body.client_id)
    eq({ 'folder-secret' }, mock.requests[1].body.client_secret)

    mock.stop()
    store.set_path(nil)
    os.remove(store_path)
  end)
end)
