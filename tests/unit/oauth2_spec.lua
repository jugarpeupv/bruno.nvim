local oauth2 = require('bruno.oauth2')
local parsers = require('bruno.parsers')
local pkce = require('bruno.oauth2.pkce')
local store = require('bruno.oauth2.store')

local root = vim.fn.getcwd() .. '/tests/fixtures'

describe('oauth2.pkce', function()
  it('matches the RFC 7636 S256 vector', function()
    local verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
    eq('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', pkce.challenge(verifier, 'S256'))
  end)

  it('generates url-safe verifiers', function()
    local verifier = pkce.verifier()
    match(verifier, '^[A-Za-z0-9_-]+$')
    truthy(#verifier >= 43)
  end)

  it('round-trips base64url', function()
    local value = 'hello\0world'
    eq(value, pkce.base64url_decode(pkce.base64url(value)))
  end)
end)

describe('oauth2.store', function()
  local path = vim.fn.tempname() .. '-oauth2.json'

  it('stores, reads and deletes tokens', function()
    store.set_path(path)
    eq(false, store.is_expired({ access_token = 'x', expires_at = os.time() + 3600 }))
    eq(true, store.is_expired({ access_token = 'x', expires_at = os.time() - 1 }))

    local token = { access_token = 'a', refresh_token = 'r', expires_at = os.time() + 100 }
    eq(true, store.set('key', token))
    eq(token.access_token, store.get('key').access_token)
    eq(true, store.delete('key'))
    eq(nil, store.get('key'))
    store.set_path(nil)
    os.remove(path)
  end)
end)

describe('oauth2.token_from_response', function()
  it('computes expiry from expires_in', function()
    local token = oauth2.token_from_response({ access_token = 'a', expires_in = '3600' })
    truthy(token.expires_at)
    truthy(token.expires_at > os.time())
    eq(3600, token.expires_in)
  end)

  it('preserves refresh tokens when the response does not include one', function()
    local token = oauth2.token_from_response({ access_token = 'new' }, { refresh_token = 'old' })
    eq('new', token.access_token)
    eq('old', token.refresh_token)
  end)

  it('derives expiry from a JWT exp claim', function()
    local header = pkce.base64url('{"alg":"none"}')
    local payload = pkce.base64url('{"exp":2000000000}')
    local token = oauth2.token_from_response({ access_token = header .. '.' .. payload .. '.' })
    eq(2000000000, token.expires_at)
  end)
end)

describe('oauth2.config', function()
  it('interpolates variables from the environment and request', function()
    local request = parsers.parse_request(root .. '/bru-collection/requests/oauth2.bru')
    request.auth.config.client_id = '{{clientId}}'
    table.insert(request.vars.req, {
      name = 'clientId',
      value = 'resolved-client',
      enabled = true,
    })
    local config = oauth2.config(request, 'Local')
    eq('resolved-client', config.client_id)
    eq('Bearer', config.token_header_prefix)
  end)
end)

describe('oauth2.inject', function()
  local inject = require('bruno.oauth2.inject')
  local file = root .. '/bru-collection/requests/oauth2.bru'
  local request = parsers.parse_request(file)
  local config = oauth2.config(request, 'Local')
  local token = { access_token = 'new-token', refresh_token = 'refresh', expires_at = os.time() + 3600 }

  it('injects a bearer header into .bru requests', function()
    local path, err = inject.build(request, token, config)
    truthy(path, err)
    local content = table.concat(vim.fn.readfile(path), '\n')
    match(content, 'auth: none')
    falsy(content:find('auth:oauth2', 1, true))
    match(content, 'Authorization: Bearer new%-token')
    local stat = vim.uv.fs_stat(path)
    truthy(stat)
    eq(384, bit.band(stat.mode, 511))
    inject.cleanup(path)
    eq(0, vim.fn.filereadable(path))
  end)

  it('injects a bearer header into .yml requests', function()
    local yml_file = root .. '/yml-collection/requests/oauth2.yml'
    local yml_request = parsers.parse_request(yml_file)
    local yml_config = oauth2.config(yml_request, 'Local')
    local path, err = inject.build(yml_request, token, yml_config)
    truthy(path, err)
    local content = table.concat(vim.fn.readfile(path), '\n')
    match(content, 'Authorization')
    match(content, 'Bearer new%-token')
    falsy(content:find('type: oauth2', 1, true))
    inject.cleanup(path)
  end)

  it('can place the token in the URL query', function()
    local url_config = vim.deepcopy(config)
    url_config.token_placement = 'url'
    url_config.token_query_key = 'access_token'
    local path, err = inject.build(request, token, url_config)
    truthy(path, err)
    local content = table.concat(vim.fn.readfile(path), '\n')
    match(content, 'access_token=new%-token')
    inject.cleanup(path)
  end)

  it('uses the id token when configured', function()
    local id_config = vim.deepcopy(config)
    id_config.token_source = 'id_token'
    local path, err = inject.build(request, { access_token = 'access', id_token = 'identity' }, id_config)
    truthy(path, err)
    local content = table.concat(vim.fn.readfile(path), '\n')
    match(content, 'Bearer identity')
    inject.cleanup(path)
  end)
end)
