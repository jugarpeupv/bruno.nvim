local Json = require('bruno.utils.json')
local log = require('bruno.utils.log')
local parsers = require('bruno.parsers')
local pkce = require('bruno.oauth2.pkce')
local store = require('bruno.oauth2.store')
local url_util = require('bruno.utils.url')

local M = {}

---@alias bruno.OAuthCallback fun(token: bruno.Token?, err: string?, config: bruno.OAuth2Config?)

---@type table<string, { callbacks: bruno.OAuthCallback[] }>
local pending = {}

---@param value? string
---@return string
local function base64_basic(value)
  return vim.base64.encode(value or '')
end

---@param config bruno.OAuth2Config
---@param vars table<string, string>
---@return bruno.OAuth2Config
local function interpolate_config(config, vars)
  local resolved = vim.deepcopy(config)

  local fields = {
    'client_id',
    'client_secret',
    'username',
    'password',
    'authorization_url',
    'access_token_url',
    'refresh_token_url',
    'callback_url',
    'scope',
    'state',
    'credentials_id',
    'token_header_prefix',
    'token_query_key',
  }

  for _, field in ipairs(fields) do
    local value = resolved[field]
    if type(value) == 'string' then
      resolved[field] = parsers.interpolate(value, vars)
    end
  end

  if resolved.additional_params then
    for _, list in pairs(resolved.additional_params) do
      for _, param in ipairs(list) do
        param.name = parsers.interpolate(param.name, vars)
        param.value = parsers.interpolate(param.value, vars)
      end
    end
  end

  return resolved
end

---@param config bruno.OAuth2Config
---@return bruno.OAuth2Config
local function normalize_config(config)
  local grant = (config.grant_type or 'authorization_code'):lower():gsub('%-', '_')
  if grant == 'resource_owner_password_credentials' then
    grant = 'password'
  end
  config.grant_type = grant

  local placement = (config.credentials_placement or 'basic_auth_header'):lower()
  if placement == 'header' or placement == 'basic' then
    placement = 'basic_auth_header'
  elseif placement ~= 'body' then
    placement = 'basic_auth_header'
  end
  config.credentials_placement = placement

  local token_placement = (config.token_placement or 'header'):lower()
  if token_placement == 'query' or token_placement == 'queryparams' or token_placement == 'url' then
    token_placement = 'url'
  else
    token_placement = 'header'
  end
  config.token_placement = token_placement

  if config.token_placement == 'header' and config.token_header_prefix == nil then
    config.token_header_prefix = 'Bearer'
  end
  if config.token_header_prefix == nil then
    config.token_header_prefix = ''
  end
  config.token_header_prefix = vim.trim(config.token_header_prefix)

  config.token_source = config.token_source == 'id_token' and 'id_token' or 'access_token'
  config.auto_fetch_token = config.auto_fetch_token ~= false
  config.auto_refresh_token = config.auto_refresh_token == true

  if config.state == '' then
    config.state = nil
  end
  if config.callback_url == nil or config.callback_url == '' then
    config.callback_url = require('bruno.config').get().oauth2.default_callback_url
  end

  return config
end

---@param request bruno.Request
---@param env? string
---@return bruno.OAuth2Config? config
---@return string? key
---@return bruno.Auth? auth
function M.config(request, env)
  local auth = parsers.resolve_auth(request)
  if not auth or auth.mode ~= 'oauth2' or type(auth.config) ~= 'table' then
    return nil, nil, nil
  end

  local vars = parsers.request_vars(request, env)
  local config = normalize_config(interpolate_config(auth.config, vars))
  local key = store.key(request, config, env)
  return config, key, auth
end

---@param value any
---@return string?
local function string_value(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return tostring(value)
end

---@param token table
---@param previous? bruno.Token
---@return bruno.Token
function M.token_from_response(token, previous)
  previous = previous or {}

  ---@type bruno.Token
  local result = {
    access_token = string_value(token.access_token) or previous.access_token,
    refresh_token = string_value(token.refresh_token) or previous.refresh_token,
    id_token = string_value(token.id_token) or previous.id_token,
    token_type = string_value(token.token_type) or previous.token_type,
    scope = string_value(token.scope) or previous.scope,
    obtained_at = os.time(),
    extra = token,
  }

  local expires_in = tonumber(token.expires_in)
  if expires_in then
    result.expires_in = expires_in
    result.expires_at = os.time() + expires_in
  else
    local jwt = result.access_token or result.id_token
    if jwt then
      local payload = jwt:match('^[^.]+%.([^.]+)%.')
      if payload then
        local decoded = pkce.base64url_decode(payload)
        if decoded then
          local data = Json.decode(decoded)
          local exp = type(data) == 'table' and tonumber(data.exp)
          if exp then
            result.expires_at = exp
          end
        end
      end
    end
  end

  return result
end

---@param key string
---@param token bruno.Token
---@param config bruno.OAuth2Config
local function persist(key, token, config)
  local options = require('bruno.config').get().oauth2
  if options.cache == false then
    return
  end

  local ok, err = store.set(key, token)
  if not ok then
    log.warn('could not persist OAuth2 token: ' .. tostring(err))
  end
end

---@param list? bruno.OAuth2AdditionalParam[]
---@param params { [1]: string, [2]: string }[]
---@param headers { [1]: string, [2]: string }[]
---@param endpoint string
---@return string endpoint
local function apply_additional(list, params, headers, endpoint)
  for _, param in ipairs(list or {}) do
    if param.enabled and param.name ~= '' then
      if param.send_in == 'headers' then
        headers[#headers + 1] = { param.name, param.value }
      elseif param.send_in == 'queryparams' then
        endpoint = url_util.append_query(endpoint, param.name, param.value)
      elseif param.send_in == 'body' then
        params[#params + 1] = { param.name, param.value }
      end
    end
  end
  return endpoint
end

---@param config bruno.OAuth2Config
---@param params { [1]: string, [2]: string }[]
---@param headers { [1]: string, [2]: string }[]
local function apply_client_credentials(config, params, headers)
  local placement = config.credentials_placement or 'basic_auth_header'
  local client_id = config.client_id or ''
  local client_secret = config.client_secret or ''

  if placement == 'basic_auth_header' and client_secret ~= '' then
    headers[#headers + 1] = { 'Authorization', 'Basic ' .. base64_basic(client_id .. ':' .. client_secret) }
  else
    if client_id ~= '' then
      params[#params + 1] = { 'client_id', client_id }
    end
    if client_secret ~= '' then
      params[#params + 1] = { 'client_secret', client_secret }
    end
  end
end

---@param config bruno.OAuth2Config
---@param params { [1]: string, [2]: string }[]
---@param headers { [1]: string, [2]: string }[]
---@param endpoint string
---@param token_kind 'token'|'refresh'
---@return string endpoint
local function prepare_token_request(config, params, headers, endpoint, token_kind)
  apply_client_credentials(config, params, headers)
  local additional = config.additional_params
  if additional then
    local list = token_kind == 'refresh' and additional.refresh or additional.token
    endpoint = apply_additional(list, params, headers, endpoint)
  end
  return endpoint
end

---@param config bruno.OAuth2Config
---@param previous bruno.Token
---@param callback fun(token: bruno.Token?, err: string?)
local function refresh_token(config, previous, callback)
  local endpoint = config.refresh_token_url
  if not endpoint or endpoint == '' then
    endpoint = config.access_token_url
  end
  if not endpoint or endpoint == '' then
    callback(nil, 'no refresh token URL configured')
    return
  end
  if not previous.refresh_token or previous.refresh_token == '' then
    callback(nil, 'no refresh token available')
    return
  end

  local params = {
    { 'grant_type', 'refresh_token' },
    { 'refresh_token', previous.refresh_token },
  }
  if config.scope and config.scope ~= '' then
    params[#params + 1] = { 'scope', config.scope }
  end

  local headers = {}
  endpoint = prepare_token_request(config, params, headers, endpoint, 'refresh')

  require('bruno.oauth2.client').post_form(
    endpoint,
    params,
    headers,
    require('bruno.config').get().oauth2.token_timeout,
    function(data, err)
      if not data then
        callback(nil, err or 'refresh failed')
        return
      end
      local token = M.token_from_response(data, previous)
      if not token.access_token and not token.id_token then
        callback(nil, 'refresh response did not contain an access token')
        return
      end
      callback(token, nil)
    end
  )
end

---@param config bruno.OAuth2Config
---@param grant string
---@param callback fun(token: bruno.Token?, err: string?)
local function direct_token_request(config, grant, callback)
  local endpoint = config.access_token_url
  if not endpoint or endpoint == '' then
    callback(nil, 'no access token URL configured')
    return
  end
  if grant == 'client_credentials' and (not config.client_id or config.client_id == '') then
    callback(nil, 'client_id is required for the client_credentials grant')
    return
  end
  if grant == 'password' then
    if not config.client_id or config.client_id == '' then
      callback(nil, 'client_id is required for the password grant')
      return
    end
    if not config.username or config.username == '' or not config.password or config.password == '' then
      callback(nil, 'username and password are required for the password grant')
      return
    end
  end

  local params = { { 'grant_type', grant } }
  if config.scope and config.scope ~= '' then
    params[#params + 1] = { 'scope', config.scope }
  end
  if grant == 'password' then
    params[#params + 1] = { 'username', config.username }
    params[#params + 1] = { 'password', config.password }
  end

  local headers = {}
  endpoint = prepare_token_request(config, params, headers, endpoint, 'token')

  require('bruno.oauth2.client').post_form(
    endpoint,
    params,
    headers,
    require('bruno.config').get().oauth2.token_timeout,
    function(data, err)
      if not data then
        callback(nil, err or 'token request failed')
        return
      end
      local token = M.token_from_response(data)
      if not token.access_token and not token.id_token then
        callback(nil, 'token response did not contain an access token')
        return
      end
      callback(token, nil)
    end
  )
end

---@param config bruno.OAuth2Config
---@param redirect_uri string
---@param state string
---@param challenge? string
---@param response_type 'code'|'token'
---@return string
local function build_authorize_url(config, redirect_uri, state, challenge, response_type)
  local endpoint = config.authorization_url or ''
  local params = {
    { 'response_type', response_type },
    { 'client_id', config.client_id or '' },
    { 'redirect_uri', redirect_uri },
    { 'state', state },
  }

  if config.scope and config.scope ~= '' then
    params[#params + 1] = { 'scope', config.scope }
  end

  if challenge then
    params[#params + 1] = { 'code_challenge', challenge }
    params[#params + 1] = { 'code_challenge_method', 'S256' }
  end

  local headers = {}
  for _, param in ipairs((config.additional_params or {}).authorization or {}) do
    if param.enabled and param.send_in == 'queryparams' then
      params[#params + 1] = { param.name, param.value }
    elseif param.enabled and param.send_in == 'headers' then
      headers[#headers + 1] = { param.name, param.value }
    end
  end

  if #headers > 0 then
    log.warn('OAuth2 authorization request headers are not supported when opening a browser')
  end

  local separator
  if endpoint:find('?', 1, true) then
    separator = endpoint:match('[?&]$') and '' or '&'
  else
    separator = '?'
  end
  local query = url_util.encode_pairs(params)
  return endpoint .. separator .. query
end

---@param config bruno.OAuth2Config
---@param url string
---@return boolean ok
---@return string? err
local function open_browser(config, url)
  local options = require('bruno.config').get().oauth2
  log.debug('OAuth2 authorization URL: ' .. url)
  if options.open_browser == false then
    vim.fn.setreg('+', url)
    log.notify('Bruno: open this OAuth2 URL to continue (copied to clipboard): ' .. url, 'info')
    return true, nil
  end

  if options.browser_cmd then
    local command = options.browser_cmd
    if type(command) == 'string' then
      command = vim.split(command, ' ', { trimempty = true })
    end
    local args = vim.deepcopy(command)
    args[#args + 1] = url
    local ok, err = pcall(vim.system, args, { text = true }, function(result)
      if result.code ~= 0 then
        log.warn('browser command failed: ' .. vim.trim(result.stderr or ''))
      end
    end)
    if not ok then
      return false, tostring(err)
    end
    return true, nil
  end

  local ok, err = vim.ui.open(url)
  if ok then
    return true, nil
  end
  return false, err
end

---@param value string
---@return table<string, string[]>
local function parse_callback_input(value)
  local parsed = url_util.parse(value)
  local parts = {}
  if parsed.query and parsed.query ~= '' then
    parts[#parts + 1] = parsed.query
  end
  if parsed.fragment and parsed.fragment ~= '' then
    parts[#parts + 1] = parsed.fragment
  end
  local query = table.concat(parts, '&')
  if query == '' then
    query = value
  end
  return url_util.parse_query(query)
end

---@param params table<string, string[]>
---@param name string
---@return string?
local function first_param(params, name)
  local values = params[name]
  return values and values[1] or nil
end

---@param config bruno.OAuth2Config
---@param code string
---@param redirect_uri string
---@param verifier? string
---@param callback fun(token: bruno.Token?, err: string?)
local function exchange_code(config, code, redirect_uri, verifier, callback)
  local endpoint = config.access_token_url
  if not endpoint or endpoint == '' then
    callback(nil, 'no access token URL configured')
    return
  end

  local params = {
    { 'grant_type', 'authorization_code' },
    { 'code', code },
    { 'redirect_uri', redirect_uri },
  }
  if verifier then
    params[#params + 1] = { 'code_verifier', verifier }
  end

  local headers = {}
  endpoint = prepare_token_request(config, params, headers, endpoint, 'token')

  require('bruno.oauth2.client').post_form(
    endpoint,
    params,
    headers,
    require('bruno.config').get().oauth2.token_timeout,
    function(data, err)
      if not data then
        callback(nil, err or 'token exchange failed')
        return
      end
      local token = M.token_from_response(data)
      if not token.access_token and not token.id_token then
        callback(nil, 'token response did not contain an access token')
        return
      end
      callback(token, nil)
    end
  )
end

---@param value? string
---@return boolean
local function is_unresolved_template(value)
  return type(value) == 'string' and value:find('{{', 1, true) ~= nil
end

---@param callback fun(token: bruno.Token?, err: string?)
---@param opts? { callback_url?: string }
local function authorization_code_flow(config, callback, opts)
  opts = opts or {}
  if not config.authorization_url or config.authorization_url == '' then
    callback(nil, 'no authorization URL configured')
    return
  end
  if not config.client_id or config.client_id == '' then
    callback(nil, 'client_id is required for the authorization_code grant')
    return
  end

  local redirect_uri = opts.callback_url or config.callback_url
  if redirect_uri == nil or redirect_uri == '' or is_unresolved_template(redirect_uri) then
    log.notify('Bruno: OAuth2 callback URL unresolved (' .. tostring(redirect_uri) .. '), using default', 'info')
    redirect_uri = require('bruno.config').get().oauth2.default_callback_url
  end
  log.notify('Bruno: using OAuth2 callback URL: ' .. redirect_uri, 'info')
  local parsed = url_util.parse(redirect_uri or '')
  local is_loopback = parsed.scheme == 'http'
    and (parsed.host == '127.0.0.1' or parsed.host == 'localhost' or parsed.host == '::1')

  local state = config.state and config.state ~= '' and config.state or pkce.state()
  local verifier
  local challenge
  if config.pkce then
    verifier = pkce.verifier()
    challenge = pkce.challenge(verifier, 'S256')
  end

  local authorization_url = build_authorize_url(config, redirect_uri, state, challenge, 'code')

  local function prompt_code()
    local opened, open_err = open_browser(config, authorization_url)
    if not opened then
      callback(nil, 'could not open the browser: ' .. tostring(open_err))
      return
    end
    vim.ui.input({ prompt = 'Paste the OAuth2 callback URL (or authorization code): ' }, function(input)
      if not input or input == '' then
        callback(nil, 'authorization cancelled')
        return
      end
      local params = parse_callback_input(input)
      local code = first_param(params, 'code') or input:match('^[^%s&?#]+$')
      local returned_state = first_param(params, 'state')
      if returned_state and returned_state ~= state then
        callback(nil, 'OAuth2 state mismatch')
        return
      end
      if not code or code == '' then
        callback(nil, 'no authorization code found in the callback URL')
        return
      end
      exchange_code(config, code, redirect_uri, verifier, callback)
    end)
  end

  if not is_loopback then
    -- The provider cannot redirect to our local server. Open the browser and
    -- ask the user to paste the redirected URL/code.
    prompt_code()
    return
  end

  local port = parsed.port
  if not port then
    port = parsed.scheme == 'http' and 80 or 443
  end
  local path = parsed.path ~= '' and parsed.path or '/callback'

  local server_module = require('bruno.oauth2.server')
  local done = false

  ---@type bruno.OAuthServer?
  local server_instance

  local function finish(token, err)
    if done then
      return
    end
    done = true
    if server_instance then
      server_instance:stop()
    end
    callback(token, err)
  end

  local instance, listen_err = server_module.listen({ host = parsed.host, port = port, path = path }, function(request)
    if request.path ~= path then
      return { status = 404, body = server_module.error_html('Not found') }
    end

    local error_value = first_param(request.params, 'error')
    if error_value then
      local description = first_param(request.params, 'error_description') or error_value
      vim.schedule(function()
        finish(nil, description)
      end)
      return { status = 400, body = server_module.error_html(description) }
    end

    local code = first_param(request.params, 'code')
    if not code then
      return { status = 400, body = server_module.error_html('No authorization code was returned.') }
    end

    local returned_state = first_param(request.params, 'state')
    if returned_state ~= state then
      vim.schedule(function()
        finish(nil, 'OAuth2 state mismatch')
      end)
      return { status = 400, body = server_module.error_html('OAuth2 state mismatch.') }
    end

    vim.schedule(function()
      if done then
        return
      end
      exchange_code(config, code, redirect_uri, verifier, function(token, err2)
        finish(token, err2)
      end)
    end)

    return { status = 200, body = server_module.success_html('Authorization received. You can close this window.') }
  end)

  server_instance = instance

  if not server_instance then
    -- Binding failed (port in use, privileged port, etc.). Fall back to manual input.
    log.notify(
      'Bruno: could not start OAuth2 callback server (' .. tostring(listen_err) .. '); paste the callback URL instead',
      'warn'
    )
    local opened, open_err = open_browser(config, authorization_url)
    if not opened then
      callback(
        nil,
        'could not start callback server (' .. tostring(listen_err) .. ') or open the browser: ' .. tostring(open_err)
      )
      return
    end
    vim.ui.input({ prompt = 'Paste the OAuth2 callback URL (or authorization code): ' }, function(input)
      if not input or input == '' then
        callback(nil, 'authorization cancelled')
        return
      end
      local params = parse_callback_input(input)
      local code = first_param(params, 'code') or input:match('^[^%s&?#]+$')
      local returned_state = first_param(params, 'state')
      if returned_state and returned_state ~= state then
        callback(nil, 'OAuth2 state mismatch')
        return
      end
      if not code or code == '' then
        callback(nil, 'no authorization code found in the callback URL')
        return
      end
      exchange_code(config, code, redirect_uri, verifier, callback)
    end)
    return
  end

  local timeout = require('bruno.config').get().oauth2.callback_timeout
  if timeout and timeout > 0 then
    server_instance:set_timeout(timeout, function()
      finish(nil, 'timed out waiting for the OAuth2 callback')
    end)
  end

  local opened, open_err = open_browser(config, authorization_url)
  if not opened then
    finish(nil, 'could not open the browser: ' .. tostring(open_err))
  end
end

---@param config bruno.OAuth2Config
---@param callback fun(token: bruno.Token?, err: string?)
---@param opts? { callback_url?: string }
local function implicit_flow(config, callback, opts)
  opts = opts or {}
  if not config.authorization_url or config.authorization_url == '' then
    callback(nil, 'no authorization URL configured')
    return
  end
  if not config.client_id or config.client_id == '' then
    callback(nil, 'client_id is required for the implicit grant')
    return
  end

  local redirect_uri = opts.callback_url or config.callback_url
  local parsed = url_util.parse(redirect_uri or '')
  local is_loopback = parsed.scheme == 'http'
    and (parsed.host == '127.0.0.1' or parsed.host == 'localhost' or parsed.host == '::1')
  local state = config.state and config.state ~= '' and config.state or pkce.state()
  local authorization_url = build_authorize_url(config, redirect_uri, state, nil, 'token')

  if not is_loopback then
    local opened, open_err = open_browser(config, authorization_url)
    if not opened then
      callback(nil, 'could not open the browser: ' .. tostring(open_err))
      return
    end
    vim.ui.input({ prompt = 'Paste the full OAuth2 callback URL (including #access_token=...): ' }, function(input)
      if not input or input == '' then
        callback(nil, 'authorization cancelled')
        return
      end
      local params = parse_callback_input(input)
      local returned_state = first_param(params, 'state')
      if returned_state and returned_state ~= state then
        callback(nil, 'OAuth2 state mismatch')
        return
      end
      local token = M.token_from_response({
        access_token = first_param(params, 'access_token'),
        expires_in = first_param(params, 'expires_in'),
        token_type = first_param(params, 'token_type'),
        scope = first_param(params, 'scope'),
      })
      if not token.access_token then
        callback(nil, 'no access token found in the callback URL')
        return
      end
      callback(token, nil)
    end)
    return
  end

  local port = parsed.port or (parsed.scheme == 'http' and 80 or 443)
  local path = parsed.path ~= '' and parsed.path or '/callback'
  local token_path = '/_bruno/token'
  local server_module = require('bruno.oauth2.server')
  local done = false

  ---@type bruno.OAuthServer?
  local server_instance

  local function finish(token, err)
    if done then
      return
    end
    done = true
    if server_instance then
      server_instance:stop()
    end
    callback(token, err)
  end

  local function token_from_params(params)
    return M.token_from_response({
      access_token = first_param(params, 'access_token'),
      expires_in = first_param(params, 'expires_in'),
      token_type = first_param(params, 'token_type'),
      scope = first_param(params, 'scope'),
    })
  end

  local instance, listen_err = server_module.listen({ host = parsed.host, port = port, path = path }, function(request)
    if request.path == path then
      -- Some providers return the token in the query string instead of the fragment.
      local access_token = first_param(request.params, 'access_token')
      if access_token then
        vim.schedule(function()
          finish(token_from_params(request.params), nil)
        end)
        return { status = 200, body = server_module.success_html('Authentication complete. You can close this window.') }
      end
      return { status = 200, body = server_module.implicit_capture_html(token_path) }
    end

    if request.path ~= token_path then
      return { status = 404, body = server_module.error_html('Not found') }
    end

    local error_value = first_param(request.params, 'error')
    if error_value then
      local description = first_param(request.params, 'error_description') or error_value
      vim.schedule(function()
        finish(nil, description)
      end)
      return { status = 400, body = server_module.error_html(description) }
    end

    local returned_state = first_param(request.params, 'state')
    if returned_state and returned_state ~= state then
      vim.schedule(function()
        finish(nil, 'OAuth2 state mismatch')
      end)
      return { status = 400, body = server_module.error_html('OAuth2 state mismatch.') }
    end

    local access_token = first_param(request.params, 'access_token')
    if not access_token then
      return { status = 400, body = server_module.error_html('No access token was returned.') }
    end

    vim.schedule(function()
      finish(token_from_params(request.params), nil)
    end)

    return { status = 200, body = server_module.success_html('Authentication complete. You can close this window.') }
  end)

  server_instance = instance

  if not server_instance then
    local opened, open_err = open_browser(config, authorization_url)
    if not opened then
      callback(
        nil,
        'could not start callback server (' .. tostring(listen_err) .. ') or open the browser: ' .. tostring(open_err)
      )
      return
    end
    vim.ui.input({ prompt = 'Paste the full OAuth2 callback URL (including #access_token=...): ' }, function(input)
      if not input or input == '' then
        callback(nil, 'authorization cancelled')
        return
      end
      local token = token_from_params(parse_callback_input(input))
      if not token.access_token then
        callback(nil, 'no access token found in the callback URL')
        return
      end
      callback(token, nil)
    end)
    return
  end

  local timeout = require('bruno.config').get().oauth2.callback_timeout
  if timeout and timeout > 0 then
    server_instance:set_timeout(timeout, function()
      finish(nil, 'timed out waiting for the OAuth2 callback')
    end)
  end

  local opened, open_err = open_browser(config, authorization_url)
  if not opened then
    finish(nil, 'could not open the browser: ' .. tostring(open_err))
  end
end

---@param key string
---@param token bruno.Token?
---@param err string?
---@param config bruno.OAuth2Config
local function finish_pending(key, token, err, config)
  local entry = pending[key]
  pending[key] = nil
  if not entry then
    return
  end
  for _, callback in ipairs(entry.callbacks) do
    pcall(callback, token, err, config)
  end
end

---@param config bruno.OAuth2Config
---@param callback fun(token: bruno.Token?, err: string?)
local function acquire_token(config, callback)
  log.info('acquiring OAuth2 token (' .. config.grant_type .. ')')
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'BrunoAuthStarted',
    data = { grant_type = config.grant_type },
  })

  local function on_token(token, err)
    if token then
      log.info('OAuth2 token acquired')
      vim.api.nvim_exec_autocmds('User', {
        pattern = 'BrunoAuthFinished',
        data = { token = token, error = nil },
      })
    else
      log.warn('OAuth2 token acquisition failed: ' .. tostring(err))
      vim.api.nvim_exec_autocmds('User', {
        pattern = 'BrunoAuthFinished',
        data = { token = nil, error = err },
      })
    end
    callback(token, err)
  end

  if config.grant_type == 'authorization_code' then
    authorization_code_flow(config, on_token)
  elseif config.grant_type == 'implicit' then
    implicit_flow(config, on_token)
  elseif config.grant_type == 'client_credentials' or config.grant_type == 'password' then
    direct_token_request(config, config.grant_type, on_token)
  else
    on_token(nil, 'unsupported OAuth2 grant type: ' .. tostring(config.grant_type))
  end
end

---Ensure that a usable OAuth2 token exists, refreshing or acquiring it as needed.
---@param request bruno.Request
---@param opts? { env?: string, force?: boolean, callback_url?: string }
---@param callback fun(token: bruno.Token?, err: string?, config: bruno.OAuth2Config?)
function M.ensure_token(request, opts, callback)
  opts = opts or {}
  local config, key = M.config(request, opts.env)
  if not config or not key then
    callback(nil, 'request does not use OAuth2 authentication', nil)
    return
  end

  local options = require('bruno.config').get().oauth2
  if options.enabled == false then
    callback(nil, 'OAuth2 support is disabled', config)
    return
  end

  if pending[key] then
    table.insert(pending[key].callbacks, callback)
    return
  end

  local cached = options.cache == false and nil or store.get(key)
  local expired = cached and store.is_expired(cached, options.refresh_leeway) or false

  if not opts.force and cached and not expired then
    callback(cached, nil, config)
    return
  end

  pending[key] = { callbacks = { callback } }

  local function done(token, err)
    if token then
      persist(key, token, config)
    end
    finish_pending(key, token, err, config)
  end

  if
    not opts.force
    and cached
    and expired
    and cached.refresh_token
    and cached.refresh_token ~= ''
    and config.auto_refresh_token
  then
    refresh_token(config, cached, function(token, err)
      if token then
        done(token, nil)
        return
      end
      log.warn('token refresh failed, falling back to a new authorization: ' .. tostring(err))
      if config.auto_fetch_token then
        acquire_token(config, done)
      else
        done(nil, err)
      end
    end)
    return
  end

  if not config.auto_fetch_token then
    done(nil, 'no valid OAuth2 token and auto_fetch_token is disabled')
    return
  end

  acquire_token(config, done)
end

---Force a fresh OAuth2 authorization.
---@param request bruno.Request
---@param opts? { env?: string }
---@param callback fun(token: bruno.Token?, err: string?, config: bruno.OAuth2Config?)
function M.login(request, opts, callback)
  M.ensure_token(request, vim.tbl_extend('force', opts or {}, { force = true }), callback)
end

---Remove the cached token for a request.
---@param request bruno.Request
---@param env? string
---@return boolean removed
function M.logout(request, env)
  local config, key = M.config(request, env)
  if not config or not key then
    return false
  end
  return store.delete(key)
end

---Remove every cached OAuth2 token.
---@return boolean cleared
function M.clear()
  return store.clear()
end

---Return the cached token (never starts a browser or token request).
---@param request bruno.Request
---@param env? string
---@return bruno.Token? token
---@return bruno.OAuth2Config? config
---@return string? key
function M.cached_token(request, env)
  local config, key = M.config(request, env)
  if not config or not key then
    return nil, nil, nil
  end
  if require('bruno.config').get().oauth2.cache == false then
    return nil, config, key
  end
  return store.get(key), config, key
end

---Return a human-readable status for a request's OAuth2 configuration.
---@param request bruno.Request
---@param env? string
---@return table
function M.status(request, env)
  local config, key, auth = M.config(request, env)
  if not config or not key then
    return { oauth2 = false }
  end

  local token = store.get(key)
  local options = require('bruno.config').get().oauth2
  return {
    oauth2 = true,
    source = auth and auth.source or request.path,
    key = key,
    grant_type = config.grant_type,
    token = token,
    has_token = token ~= nil and (token.access_token ~= nil or token.id_token ~= nil),
    expired = token and store.is_expired(token, options.refresh_leeway) or false,
    remaining = token and store.remaining(token) or nil,
  }
end

return M
