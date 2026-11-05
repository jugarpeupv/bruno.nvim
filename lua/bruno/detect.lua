local fs = require('bruno.utils.fs')

local M = {}

local MARKERS = {
  'bruno.json',
  'opencollection.yml',
  'opencollection.yaml',
}

local EXCLUDED_DIRS = {
  ['.git'] = true,
  ['.hg'] = true,
  ['.svn'] = true,
  ['.cache'] = true,
  ['.venv'] = true,
  ['node_modules'] = true,
  ['target'] = true,
  ['dist'] = true,
  ['build'] = true,
  ['vendor'] = true,
  ['venv'] = true,
}

local MAX_DEPTH = 10
local MAX_DIRS = 20000

---@type table<string, bruno.Detection>
local cache = {}

---@param path string
---@return boolean
function M.is_collection_root(path)
  for _, marker in ipairs(MARKERS) do
    if vim.fn.filereadable(path .. '/' .. marker) == 1 then
      return true
    end
  end
  return false
end

---@param name string
---@return boolean
local function excluded(name)
  if EXCLUDED_DIRS[name] then
    return true
  end
  return name:sub(1, 1) == '.'
end

---@param start string
---@return { path: string, depth: integer }[]
local function scan_down(start)
  local found = {}
  local queue = { { path = start, depth = 0 } }
  local head = 1
  local visited = 0

  while head <= #queue do
    local item = queue[head]
    head = head + 1
    visited = visited + 1
    if visited > MAX_DIRS then
      break
    end

    if M.is_collection_root(item.path) then
      found[#found + 1] = item
    elseif item.depth < MAX_DEPTH then
      local ok, iterator = pcall(vim.fs.dir, item.path)
      if ok and type(iterator) == 'function' then
        for name, kind in iterator do
          if kind == 'directory' and not excluded(name) then
            queue[#queue + 1] = {
              path = fs.normalize(item.path .. '/' .. name),
              depth = item.depth + 1,
            }
          end
        end
      end
    end
  end

  table.sort(found, function(a, b)
    if a.depth ~= b.depth then
      return a.depth < b.depth
    end
    return a.path < b.path
  end)

  return found
end

---Detect collection roots for a working directory.
---
---If the directory is inside a collection, the nearest ancestor with a
---`bruno.json` / `opencollection.yml` is used. Otherwise the directory is
---searched recursively (BFS, shallow first), pruning dependency/build folders.
---@param opts? { cwd?: string, force?: boolean }
---@return bruno.Detection
function M.detect(opts)
  opts = opts or {}
  local cwd = fs.normalize(opts.cwd or vim.fn.getcwd())

  local cached = cache[cwd]
  if not opts.force and cached then
    if not cached.root or M.is_collection_root(cached.root) then
      local result = vim.deepcopy(cached)
      result.cached = true
      return result
    end
    cache[cwd] = nil
  end

  local roots = {}
  local source = 'none'
  local root = fs.find_collection_root(cwd)

  if root then
    roots = { root }
    source = 'upward'
  else
    local found = scan_down(cwd)
    for _, item in ipairs(found) do
      roots[#roots + 1] = item.path
    end
    if #roots > 0 then
      root = roots[1]
      source = 'downward'
    end
  end

  ---@type bruno.Detection
  local detection = {
    cwd = cwd,
    root = root,
    roots = roots,
    source = source,
    cached = false,
    scanned_at = os.time(),
  }

  cache[cwd] = detection
  return vim.deepcopy(detection)
end

---Clear the detection cache.
---@param cwd? string
function M.clear(cwd)
  if cwd then
    cache[fs.normalize(cwd)] = nil
  else
    cache = {}
  end
end

---Force a fresh detection for a cwd (or the current one).
---@param opts? { cwd?: string }
---@return bruno.Detection
function M.refresh(opts)
  opts = opts or {}
  local cwd = fs.normalize(opts.cwd or vim.fn.getcwd())
  M.clear(cwd)
  return M.detect({ cwd = cwd, force = true })
end

---@param detection bruno.Detection
---@return string[]
function M.describe(detection)
  local parsers = require('bruno.parsers')
  local env = require('bruno.env')
  local lines = {}

  if not detection.root then
    lines[#lines + 1] = 'Bruno: no collection found under ' .. detection.cwd
    lines[#lines + 1] = 'Bruno: create bruno.json / opencollection.yml or refresh with :BrunoDetect!'
    return lines
  end

  local collection = parsers.collection(detection.root)
  local environments = env.choices(detection.root, true)
  local names = {}
  for _, environment in ipairs(environments) do
    names[#names + 1] = environment.name
  end
  local selected = env.ensure(detection.root, { notify = false })

  lines[#lines + 1] = 'Bruno collection: ' .. detection.root
  lines[#lines + 1] = 'Bruno name: ' .. collection.name
  lines[#lines + 1] = 'Bruno format: ' .. collection.format
  lines[#lines + 1] = 'Bruno environments: ' .. (#names > 0 and table.concat(names, ', ') or '(none)')
  lines[#lines + 1] = 'Bruno selected environment: ' .. (selected or '(none)')
  lines[#lines + 1] = 'Bruno detection: '
    .. detection.source
    .. (detection.cached and ' (cached)' or ' (scanned)')
    .. ' from '
    .. detection.cwd

  if #detection.roots > 1 then
    lines[#lines + 1] = 'Bruno other collections:'
    for index = 2, #detection.roots do
      lines[#lines + 1] = '  - ' .. detection.roots[index]
    end
  end

  return lines
end

return M
