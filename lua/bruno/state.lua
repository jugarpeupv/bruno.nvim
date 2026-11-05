local M = {
  ---@type bruno.Request?
  last_request = nil,
  ---@type bruno.RunResult?
  last_result = nil,
  ---@type string?
  last_error = nil,
  ---@type table<string, string>
  env_by_root = {},
  ---@type table<string, boolean>
  env_configured = {},
  ---@type table<string, bruno.Collection>
  collections = {},
  ---@type vim.SystemObj?
  job = nil,
  running = false,
  ---@type string[]?
  last_command = nil,
  ---@type table<string, string>?
  env_before = nil,
}

---@param request bruno.Request
function M.set_request(request)
  M.last_request = request
  M.last_error = nil
end

---@param result bruno.RunResult
function M.set_result(result)
  M.last_result = result
  M.last_error = nil
end

---@param collection bruno.Collection
function M.set_collection(collection)
  M.collections[collection.root] = collection
end

---@param root string
---@return bruno.Collection?
function M.get_collection(root)
  return M.collections[root]
end

---Clear cached collection metadata.
function M.clear_collections()
  M.collections = {}
end

---@param root string
---@param env string?
---@param explicit? boolean When `false`, keep auto-selection possible.
function M.set_env(root, env, explicit)
  if env and env ~= '' then
    M.env_by_root[root] = env
  else
    M.env_by_root[root] = nil
  end
  if explicit ~= false then
    M.env_configured[root] = true
  end
end

---@param root string
---@return boolean
function M.is_env_configured(root)
  return M.env_configured[root] == true
end

---@param root string
---@return string?
function M.get_env(root)
  return M.env_by_root[root]
end

function M.reset()
  M.last_request = nil
  M.last_result = nil
  M.last_error = nil
  M.env_by_root = {}
  M.env_configured = {}
  M.collections = {}
  M.running = false
  M.job = nil
  M.last_command = nil
  M.env_before = nil
  require('bruno.history').reset()
end

return M
