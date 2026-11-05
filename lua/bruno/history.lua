local M = {}

---@class bruno.HistoryEntry
---@field request bruno.Request
---@field result? bruno.RunResult
---@field error? string
---@field env? string

---@type bruno.HistoryEntry[]
local entries = {}

---@type integer 1-based index of the entry currently shown in the workbench.
local index = 0

---@return integer
function M.count()
  return #entries
end

---@return integer
function M.position()
  return index
end

---@return bruno.HistoryEntry?
function M.current()
  return entries[index]
end

---@param position integer
---@return bruno.HistoryEntry?
function M.get(position)
  return entries[position]
end

---Make sure the history has a first entry, so a freshly opened workbench shows
---`Request: 1/1` before anything has been run.
---@param request bruno.Request
function M.seed(request)
  if #entries > 0 then
    return
  end
  entries[1] = { request = request }
  index = 1
end

---Append a new execution and select it.
---@param request bruno.Request
---@param result bruno.RunResult
---@param env? string
---@return integer position
function M.record(request, result, env)
  entries[#entries + 1] = { request = request, result = result, env = env }
  index = #entries
  return index
end

---Append a failed execution and select it.
---@param request bruno.Request?
---@param error string
---@return integer position
function M.record_error(request, error)
  if not request then
    return index
  end
  entries[#entries + 1] = { request = request, error = error }
  index = #entries
  return index
end

---@param delta integer
---@return bruno.HistoryEntry?
function M.move(delta)
  if #entries == 0 then
    index = 0
    return nil
  end
  index = math.max(1, math.min(#entries, index + delta))
  return entries[index]
end

---Select the last execution for a request path.
---@param path string
---@return bruno.HistoryEntry?
---@return integer? position
function M.select_last_for(path)
  for position = #entries, 1, -1 do
    local entry = entries[position]
    if entry.request and entry.request.path == path then
      index = position
      return entry, position
    end
  end
  return nil, nil
end

---Select the entry that contains a given result object.
---@param result bruno.RunResult
---@return bruno.HistoryEntry?
---@return integer? position
function M.select_result(result)
  for position = #entries, 1, -1 do
    if entries[position].result == result then
      index = position
      return entries[position], position
    end
  end
  return nil, nil
end

---@param path string
---@return boolean
function M.has_request(path)
  for _, entry in ipairs(entries) do
    if entry.request and entry.request.path == path then
      return true
    end
  end
  return false
end

function M.reset()
  entries = {}
  index = 0
end

return M
