local fs = require('bruno.utils.fs')

local M = {}

---@type table<string, bruno.RequestSummary[]>
local cache = {}

---@param root string
---@param force? boolean
---@return bruno.RequestSummary[]
function M.list(root, force)
  root = fs.normalize(root)
  if not force and cache[root] then
    return cache[root]
  end
  local requests = require('bruno.parsers').list_requests(root)
  cache[root] = requests
  return requests
end

---@param root string
---@param path string
---@return integer? index
---@return integer total
function M.position(root, path)
  local requests = M.list(root)
  for index, request in ipairs(requests) do
    if request.path == path then
      return index, #requests
    end
  end
  return nil, #requests
end

---@param root string
---@param delta integer
---@param path string
---@return bruno.RequestSummary? request
---@return integer? index
---@return integer total
function M.move(root, delta, path)
  local requests = M.list(root)
  if #requests == 0 then
    return nil, nil, 0
  end

  local current
  for index, request in ipairs(requests) do
    if request.path == path then
      current = index
      break
    end
  end

  local target
  if current then
    target = ((current - 1 + delta) % #requests) + 1
  elseif delta > 0 then
    target = 1
  else
    target = #requests
  end

  return requests[target], target, #requests
end

---@param root? string
function M.clear(root)
  if root then
    cache[fs.normalize(root)] = nil
  else
    cache = {}
  end
end

return M
