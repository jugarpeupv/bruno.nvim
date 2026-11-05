local bru = require('bruno.parsers.bru')
local fs = require('bruno.utils.fs')
local log = require('bruno.utils.log')
local yml = require('bruno.parsers.yml')

local M = {}

---@param path string
---@return bruno.Format
function M.format_for(path)
  if fs.is_yml(path) then
    return 'yml'
  end
  return 'bru'
end

---@param root string
---@param format bruno.Format
---@return string?
function M.collection_file(root, format)
  if format == 'yml' then
    local yml = root .. '/opencollection.yml'
    if vim.fn.filereadable(yml) == 1 then
      return yml
    end
    local yaml = root .. '/opencollection.yaml'
    return vim.fn.filereadable(yaml) == 1 and yaml or nil
  end
  local path = root .. '/bruno.json'
  return vim.fn.filereadable(path) == 1 and path or nil
end

---@param root string
---@return bruno.Collection
function M.collection(root)
  root = fs.normalize(root)
  local format = (
    vim.fn.filereadable(root .. '/opencollection.yml') == 1
    or vim.fn.filereadable(root .. '/opencollection.yaml') == 1
  )
      and 'yml'
    or 'bru'
  local config_path = M.collection_file(root, format) or ''
  local name = fs.basename(root)

  if format == 'bru' and vim.fn.filereadable(config_path) == 1 then
    local raw = fs.read_file(config_path) or ''
    local ok, data = pcall(vim.json.decode, raw)
    if ok and type(data) == 'table' and data.name then
      name = tostring(data.name)
    end
  elseif format == 'yml' and vim.fn.filereadable(config_path) == 1 then
    name = yml.collection_name(config_path) or name
  end

  local env_dir = root .. '/environments'
  return {
    root = root,
    name = name,
    format = format,
    config_path = config_path,
    env_dir = vim.fn.isdirectory(env_dir) == 1 and env_dir or nil,
  }
end

---@param path string
---@return bruno.Request
function M.parse_request(path)
  path = fs.normalize(path)
  local format = M.format_for(path)
  local raw = fs.read_file(path) or ''
  local request = format == 'yml' and yml.parse_request(path, raw) or bru.parse_request(path, raw)
  local root = fs.find_collection_root(path) or fs.dirname(path)

  request.format = format
  request.root = root
  request.relpath = fs.relpath(root, path)
  request.path = path
  request.raw = raw

  return request
end

---@param path string
---@return bruno.RequestSummary?
function M.parse_summary(path)
  local ok, request = pcall(M.parse_request, path)
  if not ok or not request then
    return nil
  end
  return {
    path = request.path,
    relpath = request.relpath,
    root = request.root,
    format = request.format,
    name = request.name,
    method = request.method,
    url = request.url,
    type = request.type,
  }
end

---@param root string
---@return bruno.RequestSummary[]
function M.list_requests(root)
  root = fs.normalize(root)
  local files = {}
  vim.list_extend(files, vim.fn.globpath(root, '**/*.bru', false, true))
  vim.list_extend(files, vim.fn.globpath(root, '**/*.yml', false, true))
  vim.list_extend(files, vim.fn.globpath(root, '**/*.yaml', false, true))

  local ignored = { 'node_modules', '%.git', 'environments', '%.bruno%-nvim%-' }
  local result = {}

  for _, path in ipairs(files) do
    path = fs.normalize(path)
    local rel = fs.relpath(root, path)
    local ignore = false
    for _, pattern in ipairs(ignored) do
      if rel:find(pattern) then
        ignore = true
        break
      end
    end

    if not ignore and fs.is_request_file(path) then
      local summary = M.parse_summary(path)
      if summary then
        result[#result + 1] = summary
      end
    end
  end

  table.sort(result, function(a, b)
    return a.relpath < b.relpath
  end)

  return result
end

---@param root string
---@return { name: string, path: string }[]
function M.list_environments(root)
  root = fs.normalize(root)
  local env_dir = root .. '/environments'
  if vim.fn.isdirectory(env_dir) ~= 1 then
    return {}
  end

  local files = {}
  vim.list_extend(files, vim.fn.globpath(env_dir, '*.bru', false, true))
  vim.list_extend(files, vim.fn.globpath(env_dir, '*.yml', false, true))
  vim.list_extend(files, vim.fn.globpath(env_dir, '*.yaml', false, true))

  local result = {}
  for _, path in ipairs(files) do
    path = fs.normalize(path)
    result[#result + 1] = {
      name = fs.basename_no_ext(path),
      path = path,
    }
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)

  return result
end

---@param root string
---@param name string
---@return table<string, string>
function M.load_environment(root, name)
  for _, env in ipairs(M.list_environments(root)) do
    if env.name == name then
      if fs.is_yml(env.path) then
        return yml.parse_env(env.path)
      end
      return bru.parse_env(env.path)
    end
  end
  return {}
end

---@param root string
---@return table<string, string>
function M.collection_vars(root)
  root = fs.normalize(root)
  local result = {}

  if vim.fn.filereadable(root .. '/opencollection.yml') == 1 then
    result = yml.parse_collection_vars(root .. '/opencollection.yml')
  elseif vim.fn.filereadable(root .. '/opencollection.yaml') == 1 then
    result = yml.parse_collection_vars(root .. '/opencollection.yaml')
  else
    local collection_bru = root .. '/collection.bru'
    if vim.fn.filereadable(collection_bru) == 1 then
      local raw = fs.read_file(collection_bru) or ''
      local doc = bru.parse(raw)
      local vars = doc.by_name.vars
      if vars and vars.entries then
        for _, entry in ipairs(vars.entries) do
          if entry.enabled then
            result[entry.name] = entry.value
          end
        end
      end
    end
  end

  return result
end

---Collect folder-level variables from the request directory up to the collection root.
---@param request bruno.Request
---@return table<string, string>
function M.folder_vars(request)
  local result = {}
  local current = fs.dirname(request.path)
  local root = request.root

  while current ~= '' and #current >= #root do
    local folder_yml = current .. '/folder.yml'
    local folder_yaml = current .. '/folder.yaml'
    local folder_bru = current .. '/folder.bru'

    if vim.fn.filereadable(folder_yml) == 1 or vim.fn.filereadable(folder_yaml) == 1 then
      local folder_path = vim.fn.filereadable(folder_yml) == 1 and folder_yml or folder_yaml
      local raw = fs.read_file(folder_path) or ''
      local doc = require('bruno.parsers.yaml').parse(raw) or {}
      local variables = type(doc.request) == 'table' and doc.request.variables or nil
      for _, item in ipairs(yml.normalize_key_values(variables)) do
        if item.enabled then
          result[item.name] = item.value
        end
      end
    elseif vim.fn.filereadable(folder_bru) == 1 then
      local raw = fs.read_file(folder_bru) or ''
      local doc = bru.parse(raw)
      local vars = doc.by_name.vars
      if vars and vars.entries then
        for _, entry in ipairs(vars.entries) do
          if entry.enabled then
            result[entry.name] = entry.value
          end
        end
      end
    end

    if current == root then
      break
    end
    local parent = vim.fn.fnamemodify(current, ':h')
    if parent == current then
      break
    end
    current = parent
  end

  return result
end

---@param entries bruno.KeyValue[]
---@return table<string, string>
function M.entries_to_map(entries)
  local result = {}
  for _, entry in ipairs(entries or {}) do
    if entry.enabled then
      result[entry.name] = entry.value
    end
  end
  return result
end

---Resolve {{variables}} in a string.
---@param value string
---@param vars table<string, string>
---@param depth? integer
---@return string
function M.interpolate(value, vars, depth)
  depth = depth or 0
  if depth > 10 or type(value) ~= 'string' then
    return value
  end

  local replaced = value:gsub('{{%s*([%w%._%-]+)%s*}}', function(key)
    local replacement = vars[key]
    if replacement == nil then
      return '{{' .. key .. '}}'
    end
    return M.interpolate(tostring(replacement), vars, depth + 1)
  end)

  return replaced
end

---@param request bruno.Request
---@param env_name? string
---@return table<string, string>
function M.request_vars(request, env_name)
  local vars = {}

  local function merge(next)
    vars = vim.tbl_extend('force', vars, next or {})
  end

  merge(M.collection_vars(request.root))
  merge(M.folder_vars(request))

  if env_name and env_name ~= '' then
    merge(M.load_environment(request.root, env_name))
  end

  merge(M.entries_to_map(request.vars.req or {}))

  for key, value in pairs(vars) do
    vars[key] = M.interpolate(tostring(value), vars)
  end

  return vars
end

---Resolve the effective auth, including `inherit` from folders and the collection root.
---@param request bruno.Request
---@return bruno.Auth? effective
function M.resolve_effective_auth(request)
  if request.auth.mode ~= 'none' and request.auth.mode ~= 'inherit' then
    return request.auth
  end
  if request.auth.mode ~= 'inherit' then
    return nil
  end

  local current = fs.dirname(request.path)
  local root = request.root

  while current ~= '' and #current >= #root do
    local folder_yml = current .. '/folder.yml'
    local folder_yaml = current .. '/folder.yaml'
    local folder_bru = current .. '/folder.bru'

    if vim.fn.filereadable(folder_yml) == 1 or vim.fn.filereadable(folder_yaml) == 1 then
      local auth = yml.parse_folder_auth(vim.fn.filereadable(folder_yml) == 1 and folder_yml or folder_yaml)
      if auth then
        return auth
      end
    elseif vim.fn.filereadable(folder_bru) == 1 then
      local auth = bru.parse_folder_auth(folder_bru)
      if auth then
        return auth
      end
    end

    if current == root then
      break
    end
    local parent = vim.fn.fnamemodify(current, ':h')
    if parent == current then
      break
    end
    current = parent
  end

  local collection_yml = root .. '/opencollection.yml'
  local collection_yaml = root .. '/opencollection.yaml'
  local collection_bru = root .. '/collection.bru'

  if vim.fn.filereadable(collection_yml) == 1 or vim.fn.filereadable(collection_yaml) == 1 then
    return yml.parse_folder_auth(vim.fn.filereadable(collection_yml) == 1 and collection_yml or collection_yaml)
  elseif vim.fn.filereadable(collection_bru) == 1 then
    return bru.parse_folder_auth(collection_bru)
  end

  return nil
end

---Resolve the effective OAuth2 auth, or nil when the request does not use it.
---@param request bruno.Request
---@return bruno.Auth? effective
function M.resolve_auth(request)
  local auth = M.resolve_effective_auth(request)
  if auth and auth.mode == 'oauth2' then
    return auth
  end
  return nil
end

---@param request bruno.Request
---@return boolean
function M.has_oauth2(request)
  return M.resolve_auth(request) ~= nil
end

---@param roots string[]
---@return bruno.RequestSummary[]
function M.list_from_roots(roots)
  local result = {}
  for _, root in ipairs(roots) do
    vim.list_extend(result, M.list_requests(root))
  end
  table.sort(result, function(a, b)
    return a.relpath < b.relpath
  end)
  return result
end

---@param path string
---@return boolean
function M.is_request(path)
  return fs.is_request_file(path)
end

---@return string|nil
function M.current_request_path()
  local path = vim.fn.expand('%:p')
  if M.is_request(path) then
    return path
  end
  return nil
end

---@param request bruno.Request
---@param env? string
---@return string
function M.resolved_url(request, env)
  local vars = M.request_vars(request, env)
  return M.interpolate(request.url, vars)
end

M._internal = {
  format_for = M.format_for,
  collection = M.collection,
}

return M
