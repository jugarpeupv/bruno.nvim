local fs = require('bruno.utils.fs')
local json = require('bruno.utils.json')
local url = require('bruno.utils.url')
local yaml = require('bruno.parsers.yaml')

local M = {}

---@param value any
---@return string
local function scalar_to_string(value)
  return url.value_to_string(value)
end

---@param list any
---@return bruno.KeyValue[]
function M.normalize_key_values(list)
  if type(list) ~= 'table' then
    return {}
  end

  local result = {}
  for _, item in ipairs(list) do
    if type(item) == 'table' then
      local name = item.name or item.key or item.parameter
      if name == nil then
        name = ''
      end
      result[#result + 1] = {
        name = scalar_to_string(name),
        value = scalar_to_string(item.value),
        enabled = item.disabled ~= true and item.enabled ~= false,
        description = item.description and scalar_to_string(item.description) or nil,
      }
    elseif item ~= nil then
      result[#result + 1] = {
        name = scalar_to_string(item),
        value = '',
        enabled = true,
      }
    end
  end

  return result
end

---@param additional? table
---@param key string
---@return bruno.OAuth2AdditionalParam[]
local function normalize_additional(additional, key)
  local list = additional and additional[key]
  if type(list) ~= 'table' then
    return {}
  end

  local result = {}
  for _, item in ipairs(list) do
    if type(item) == 'table' and item.name then
      local placement = item.placement
      local send_in
      if placement == 'header' then
        send_in = 'headers'
      elseif placement == 'query' or placement == 'queryparams' then
        send_in = 'queryparams'
      elseif placement == 'body' then
        send_in = 'body'
      else
        send_in = 'headers'
      end
      result[#result + 1] = {
        name = scalar_to_string(item.name),
        value = scalar_to_string(item.value),
        enabled = item.disabled ~= true and item.enabled ~= false,
        send_in = send_in,
      }
    end
  end

  return result
end

---@param flow? string
---@return bruno.GrantType
local function grant_type_from_flow(flow)
  if flow == 'client_credentials' then
    return 'client_credentials'
  end
  if flow == 'resource_owner_password_credentials' or flow == 'password' then
    return 'password'
  end
  if flow == 'implicit' then
    return 'implicit'
  end
  return 'authorization_code'
end

---@param auth any
---@return boolean
local function pkce_enabled(auth)
  if type(auth) ~= 'table' then
    return false
  end
  local pkce = auth.pkce
  if type(pkce) == 'boolean' then
    return pkce
  end
  if type(pkce) == 'table' then
    return pkce.disabled ~= true
  end
  return false
end

---@param auth table
---@return bruno.OAuth2Config
local function parse_oauth2(auth)
  local credentials = auth.credentials or {}
  local resource_owner = auth.resourceOwner or {}
  local token_config = auth.tokenConfig or {}
  local settings = auth.settings or {}
  local placement = token_config.placement or {}
  local additional = auth.additionalParameters or {}

  local authorization_params = normalize_additional(additional, 'authorizationRequest')
  local token_params = normalize_additional(additional, 'accessTokenRequest')
  local refresh_params = normalize_additional(additional, 'refreshTokenRequest')

  ---@type bruno.OAuth2Config
  local config = {
    grant_type = grant_type_from_flow(auth.flow),
    client_id = credentials.clientId ~= nil and scalar_to_string(credentials.clientId) or nil,
    client_secret = credentials.clientSecret ~= nil and scalar_to_string(credentials.clientSecret) or nil,
    username = resource_owner.username ~= nil and scalar_to_string(resource_owner.username) or nil,
    password = resource_owner.password ~= nil and scalar_to_string(resource_owner.password) or nil,
    authorization_url = auth.authorizationUrl ~= nil and scalar_to_string(auth.authorizationUrl) or nil,
    access_token_url = auth.accessTokenUrl ~= nil and scalar_to_string(auth.accessTokenUrl) or nil,
    refresh_token_url = auth.refreshTokenUrl ~= nil and scalar_to_string(auth.refreshTokenUrl) or nil,
    callback_url = auth.callbackUrl ~= nil and scalar_to_string(auth.callbackUrl) or nil,
    scope = auth.scope ~= nil and scalar_to_string(auth.scope) or nil,
    state = auth.state ~= nil and scalar_to_string(auth.state) or nil,
    pkce = pkce_enabled(auth),
    credentials_placement = credentials.placement ~= nil and scalar_to_string(credentials.placement) or nil,
    credentials_id = token_config.id ~= nil and scalar_to_string(token_config.id) or nil,
    token_source = token_config.source ~= nil and scalar_to_string(token_config.source) or 'access_token',
    token_placement = placement.header ~= nil and 'header' or (placement.query ~= nil and 'url' or nil),
    token_header_prefix = placement.header ~= nil and scalar_to_string(placement.header) or nil,
    token_query_key = placement.query ~= nil and scalar_to_string(placement.query) or nil,
    auto_fetch_token = settings.autoFetchToken ~= false,
    auto_refresh_token = settings.autoRefreshToken == true,
  }

  if #authorization_params > 0 or #token_params > 0 or #refresh_params > 0 then
    config.additional_params = {
      authorization = #authorization_params > 0 and authorization_params or nil,
      token = #token_params > 0 and token_params or nil,
      refresh = #refresh_params > 0 and refresh_params or nil,
    }
  end

  return config
end

---@param auth any
---@return bruno.Auth
function M.parse_auth(auth)
  if type(auth) == 'string' then
    local mode = auth:lower()
    if mode == 'inherit' or mode == 'none' then
      return { mode = mode, config = {} }
    end
    return { mode = mode, config = {} }
  end

  if type(auth) ~= 'table' then
    return { mode = 'none', config = {} }
  end

  local mode = (auth.type or auth.mode or 'none'):lower()
  if mode == 'oauth2' then
    return { mode = 'oauth2', config = parse_oauth2(auth) }
  end

  return { mode = mode, config = auth }
end

---@param body any
---@return bruno.Body
local function parse_body(body)
  if body == nil then
    return { mode = 'none' }
  end

  if type(body) == 'string' then
    return { mode = 'text', content = body }
  end

  if type(body) ~= 'table' then
    return { mode = 'none' }
  end

  local mode = body.type or 'none'
  if mode == 'none' then
    return { mode = 'none' }
  end

  if mode == 'form-urlencoded' or mode == 'multipart-form' then
    return { mode = mode, entries = M.normalize_key_values(body.data) }
  end

  if mode == 'file' then
    return { mode = mode, entries = M.normalize_key_values(body.data) }
  end

  if type(body.data) == 'table' then
    return { mode = mode, content = json.pretty(body.data) }
  end

  return { mode = mode, content = body.data ~= nil and scalar_to_string(body.data) or '' }
end

---@param scripts any
---@return bruno.Script
---@return string?
---@return table[]
local function parse_scripts(scripts)
  local script = {}
  local tests
  local assertions = {}

  if type(scripts) == 'table' then
    for _, item in ipairs(scripts) do
      if type(item) == 'table' then
        local code = item.code and scalar_to_string(item.code) or ''
        if item.type == 'before-request' or item.type == 'pre-request' then
          script.pre = code
        elseif item.type == 'after-response' or item.type == 'post-response' then
          script.post = code
        elseif item.type == 'tests' then
          tests = code
        end
      end
    end
  end

  local runtime_assertions = scripts and scripts.assertions
  if type(runtime_assertions) == 'table' then
    for _, item in ipairs(runtime_assertions) do
      assertions[#assertions + 1] = item
    end
  end

  return script, tests, assertions
end

---@param doc table
---@param key string
---@return string?
local function docs_to_string(doc, key)
  local docs = doc[key]
  if type(docs) == 'string' then
    return docs
  end
  if type(docs) == 'table' then
    return docs.content and scalar_to_string(docs.content) or nil
  end
  return nil
end

---@param path string
---@param raw string
---@return bruno.Request
function M.parse_request(path, raw)
  raw = raw or fs.read_file(path) or ''
  local doc = yaml.parse(raw) or {}
  local info = type(doc.info) == 'table' and doc.info or {}
  local http = type(doc.http) == 'table' and doc.http or {}
  local runtime = type(doc.runtime) == 'table' and doc.runtime or {}

  if type(doc.graphql) == 'table' then
    http = doc.graphql
  end

  local request_type = info.type or 'http'
  local method = http.method
  if not method or method == '' then
    method = request_type == 'graphql' and 'POST' or 'GET'
  end
  method = scalar_to_string(method):upper()

  local params = {}
  local path_params = {}
  if type(http.params) == 'table' then
    for _, item in ipairs(http.params) do
      local normalized = M.normalize_key_values({ item })[1]
      if normalized then
        if type(item) == 'table' and item.type == 'path' then
          path_params[#path_params + 1] = normalized
        else
          params[#params + 1] = normalized
        end
      end
    end
  end

  local runtime_scripts = runtime.scripts
  if type(runtime_scripts) == 'table' and type(runtime_scripts.assertions) == 'table' then
    -- Defensive: support an assertions list nested under scripts.
  end

  local script, tests, assertions = parse_scripts(runtime.scripts)
  if type(runtime.assertions) == 'table' then
    for _, item in ipairs(runtime.assertions) do
      assertions[#assertions + 1] = item
    end
  end

  local vars_req = M.normalize_key_values(runtime.variables)
  local vars_res = {}
  if type(runtime.actions) == 'table' then
    for _, action in ipairs(runtime.actions) do
      if type(action) == 'table' and action.type == 'set-variable' then
        local variable = action.variable or {}
        vars_res[#vars_res + 1] = {
          name = variable.name and scalar_to_string(variable.name) or '',
          value = action.selector and action.selector.expression and scalar_to_string(action.selector.expression) or '',
          enabled = true,
        }
      end
    end
  end

  local auth_source = http.auth
  if auth_source == nil and runtime.auth ~= nil then
    auth_source = runtime.auth
  end

  local body = parse_body(http.body)
  if request_type == 'graphql' and type(http.body) == 'table' and http.body.query then
    local query = scalar_to_string(http.body.query)
    local variables = http.body.variables
    if variables ~= nil and variables ~= vim.NIL then
      if type(variables) == 'table' then
        variables = json.pretty(variables)
      else
        variables = scalar_to_string(variables)
      end
      if variables ~= '' then
        query = query .. '\n\n# variables\n' .. variables
      end
    end
    body = { mode = 'graphql', content = query }
  end

  ---@type bruno.Request
  local request = {
    path = fs.normalize(path),
    relpath = '',
    root = '',
    format = 'yml',
    name = info.name and scalar_to_string(info.name) or fs.basename_no_ext(path),
    type = scalar_to_string(request_type),
    method = method,
    url = http.url ~= nil and scalar_to_string(http.url) or '',
    params = params,
    path_params = path_params,
    headers = M.normalize_key_values(http.headers),
    body = body,
    auth = M.parse_auth(auth_source),
    script = script,
    tests = tests,
    docs = docs_to_string(doc, 'docs'),
    assertions = assertions,
    vars = { req = vars_req, res = vars_res },
    raw = raw,
  }

  return request
end

---@param path string
---@return table<string, string>
function M.parse_env(path)
  local raw = fs.read_file(path) or ''
  local doc = yaml.parse(raw) or {}
  local result = {}

  if type(doc.variables) == 'table' then
    for _, item in ipairs(doc.variables) do
      if type(item) == 'table' and item.name then
        local name = scalar_to_string(item.name)
        if item.disabled ~= true then
          result[name] = item.value ~= nil and scalar_to_string(item.value) or ''
        end
      end
    end
  end

  return result
end

---@param path string
---@return bruno.Auth?
function M.parse_folder_auth(path)
  local raw = fs.read_file(path)
  if not raw then
    return nil
  end
  local doc = yaml.parse(raw) or {}
  local auth_source = type(doc.request) == 'table' and doc.request.auth or nil
  if auth_source == nil and type(doc.runtime) == 'table' then
    auth_source = doc.runtime.auth
  end
  local auth = M.parse_auth(auth_source)
  if auth.mode == 'none' or auth.mode == 'inherit' then
    return nil
  end
  auth.source = path
  return auth
end

---@param path string
---@return table<string, string>
function M.parse_collection_vars(path)
  local raw = fs.read_file(path) or ''
  local doc = yaml.parse(raw) or {}
  local variables = type(doc.request) == 'table' and doc.request.variables or nil
  local result = {}
  for _, item in ipairs(M.normalize_key_values(variables)) do
    if item.enabled then
      result[item.name] = item.value
    end
  end
  return result
end

---@param path string
---@return string?
function M.collection_name(path)
  local raw = fs.read_file(path) or ''
  local doc = yaml.parse(raw) or {}
  local info = type(doc.info) == 'table' and doc.info or {}
  return info.name and scalar_to_string(info.name) or nil
end

M._internal = {
  parse_oauth2 = parse_oauth2,
  parse_body = parse_body,
  parse_scripts = parse_scripts,
}

return M
