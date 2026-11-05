local config = require('bruno.config')
local fs = require('bruno.utils.fs')
local log = require('bruno.utils.log')
local parsers = require('bruno.parsers')
local state = require('bruno.state')

local M = {}

---@type table<string, boolean>
local announced = {}

---@type table<string, { name: string, path: string }[]>
local choices_cache = {}

---@param root string
---@param name string
---@param reason string
local function announce(root, name, reason)
  local key = root .. '\0' .. name
  if announced[key] then
    return
  end
  announced[key] = true
  log.info(string.format('Bruno: %s environment "%s" for %s', reason, name, fs.basename(root)))
end

---Return the working root for the current request or detected collection.
---@return string?
function M.current_root()
  local path = parsers.current_request_path()
  if path then
    local root = fs.find_collection_root(path)
    if root then
      return root
    end
  end

  if state.last_request and state.last_request.root then
    return state.last_request.root
  end

  return require('bruno.detect').detect().root
end

---Ensure that a collection has an environment selected.
---
---Selection order:
---1. an environment explicitly selected by the user;
---2. `config.default_env`, when set;
---3. the only environment of the collection, when exactly one exists.
---@param root string
---@param opts? { notify?: boolean }
---@return string? environment
function M.ensure(root, opts)
  opts = opts or {}
  if not root or root == '' then
    return nil
  end

  local environments = M.choices(root)
  local selected = state.get_env(root)
  if selected and selected ~= '' then
    for _, environment in ipairs(environments) do
      if environment.name == selected then
        return selected
      end
    end

    state.set_env(root, nil, false)
    if opts.notify ~= false then
      local key = root .. '\0missing-selected'
      if not announced[key] then
        announced[key] = true
        log.notify(string.format('Bruno: selected environment "%s" no longer exists in %s', selected, root), 'warn')
      end
    end
  end
  if state.is_env_configured(root) then
    return nil
  end

  local default = config.get().default_env

  if default and default ~= '' then
    for _, environment in ipairs(environments) do
      if environment.name == default then
        state.set_env(root, default, false)
        if opts.notify ~= false then
          announce(root, default, 'selected default')
        end
        return default
      end
    end
    if opts.notify ~= false then
      local key = root .. '\0default-missing'
      if not announced[key] then
        announced[key] = true
        log.warn(string.format('Bruno: default_env "%s" not found in %s', default, root))
      end
    end
  end

  if #environments == 1 then
    local name = environments[1].name
    state.set_env(root, name, false)
    if opts.notify ~= false then
      announce(root, name, 'auto-selected')
    end
    return name
  end

  return nil
end

---Select an environment explicitly.
---@param root string
---@param name string?
function M.set(root, name)
  choices_cache[root] = nil
  state.set_env(root, name, true)
end

---Clear the selected environment and mark the collection as explicitly using
---the default one.
---@param root string
function M.clear(root)
  choices_cache[root] = nil
  state.set_env(root, nil, true)
end

---@param root string
---@param force? boolean
---@return { name: string, path: string }[]
function M.choices(root, force)
  if not force and choices_cache[root] then
    return choices_cache[root]
  end
  local environments = parsers.list_environments(root)
  choices_cache[root] = environments
  return environments
end

---@param root string
---@return string?
function M.selected(root)
  return state.get_env(root)
end

---Return the selected environment for the current request/collection.
---@param opts? { notify?: boolean }
---@return string?
function M.current(opts)
  local root = M.current_root()
  if not root then
    return nil
  end
  return M.ensure(root, opts)
end

---Reset cached announcements and environment choices (used by `:BrunoDetect!`).
function M.reset()
  announced = {}
  choices_cache = {}
end

---Reset the "already announced" set.
function M.reset_announcements()
  announced = {}
end

return M
