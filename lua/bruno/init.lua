local config = require('bruno.config')
local log = require('bruno.utils.log')
local parsers = require('bruno.parsers')
local state = require('bruno.state')

local M = {}

local commands_registered = false

---@return bruno.Request?
local function current_request()
  local path = parsers.current_request_path()
  if path then
    local ok, request = pcall(parsers.parse_request, path)
    if ok then
      state.set_request(request)
      return request
    end
  end
  return state.last_request
end

---Open the tabbed workbench.
---@param opts? { request?: bruno.Request, focus?: boolean }
---@return integer?
function M.open(opts)
  return require('bruno.ui').open(opts)
end

---Close the workbench window.
function M.close()
  require('bruno.ui').close()
end

---Toggle the workbench: focus it if visible, close it if focused, open it otherwise.
---@return boolean
function M.toggle()
  return require('bruno.ui').toggle()
end

---Run a request. Accepts an explicit path, a parsed request, or uses the current one.
---@param request? bruno.Request|string
---@param opts? bruno.RunOptions
---@return boolean
function M.run(request, opts)
  return require('bruno.runner').run(request, opts)
end

---Replay the last request.
---@param opts? bruno.RunOptions
---@return boolean
function M.replay(opts)
  return require('bruno.runner').replay(opts)
end

---Cancel the running request.
---Cancel the running request.
function M.cancel()
  require('bruno.runner').cancel()
end

---Switch environment for the current collection.
---@param name? string
function M.env(name)
  local env_mod = require('bruno.env')
  local root = env_mod.current_root()
  if not root then
    log.notify('Bruno: no collection detected. Run :BrunoDetect to inspect detection.', 'warn')
    return
  end

  if not name or name == '' then
    require('bruno.ui').pick_env()
    return
  end

  local available = env_mod.choices(root, true)
  local found = false
  for _, environment in ipairs(available) do
    if environment.name == name then
      found = true
      break
    end
  end

  if not found then
    log.notify('Bruno: unknown environment: ' .. name, 'warn')
    return
  end

  env_mod.set(root, name)
  log.notify('Bruno environment: ' .. name, 'info')
  if require('bruno.ui').buf then
    require('bruno.ui').render(require('bruno.ui').buf)
  end
end

---Pick a request from the detected collection(s).
function M.pick_request()
  require('bruno.ui').pick_request()
end

---Acquire/login an OAuth2 token for the current request.
function M.auth()
  require('bruno.ui').auth()
end

---Clear the cached OAuth2 token for the current request.
function M.auth_clear()
  require('bruno.ui').auth_clear()
end

---Remove every cached OAuth2 token.
function M.clear_tokens()
  return require('bruno.oauth2').clear()
end

---Print OAuth2 status for the current request.
function M.auth_status()
  local request = current_request()
  if not request then
    log.notify('Bruno: no request selected', 'warn')
    return
  end
  local oauth2 = require('bruno.oauth2')
  local env = require('bruno.env').ensure(request.root)
  local status = oauth2.status(request, env)
  if not status.oauth2 then
    log.notify('Bruno: this request does not use OAuth2 authentication', 'info')
    return
  end
  local lines = {
    'grant_type: ' .. tostring(status.grant_type),
    'source: ' .. tostring(status.source),
    'has_token: ' .. tostring(status.has_token),
    'expired: ' .. tostring(status.expired),
    'remaining: ' .. tostring(status.remaining),
  }
  log.notify(table.concat(lines, '\n'), 'info')
end

---Copy the current request as a cURL command.
function M.copy_curl()
  require('bruno.ui').copy_curl()
end

---Select a workbench tab.
---@param name? string|integer
function M.tab(name)
  local ui = require('bruno.ui')
  if not name or name == '' then
    local tabs = config.get().ui.tabs
    vim.ui.select(tabs, { prompt = 'Bruno tab' }, function(choice)
      if choice then
        ui.select_tab(choice)
      end
    end)
    return
  end

  local index = tonumber(name)
  if index then
    ui.select_tab(index)
  else
    ui.select_tab(name)
  end
end

---Return the current request (or the last one).
---@return bruno.Request?
function M.current_request()
  return current_request()
end

---Show the previous execution in the workbench history.
function M.prev_response()
  require('bruno.ui').prev_response()
end

---Show the next execution in the workbench history.
function M.next_response()
  require('bruno.ui').next_response()
end

---Detect the collection for a working directory (cached by cwd).
---@param opts? { cwd?: string, force?: boolean }
---@return bruno.Detection
function M.detect_collection(opts)
  if opts and opts.force then
    state.clear_collections()
    require('bruno.requests').clear()
  end
  return require('bruno.detect').detect(opts)
end

---Force a fresh collection detection for a working directory (or cwd).
---@param opts? { cwd?: string }
---@return bruno.Detection
function M.refresh_detection(opts)
  state.clear_collections()
  require('bruno.requests').clear()
  require('bruno.env').reset()
  return require('bruno.detect').refresh(opts)
end

---Return the active collection (current request first, then detected cwd).
---@return bruno.Collection?
function M.current_collection()
  local root = require('bruno.env').current_root()
  if not root then
    return nil
  end
  local collection = state.get_collection(root)
  if not collection then
    collection = parsers.collection(root)
    state.set_collection(collection)
  end
  return collection
end

---Return the currently selected environment, or nil when none is selected.
---Useful for statusline/lualine integrations.
---@param opts? { notify?: boolean }
---@return string?
function M.current_environment(opts)
  return require('bruno.env').current(opts)
end

---Alias for `current_environment`.
---@param opts? { notify?: boolean }
---@return string?
function M.get_env(opts)
  return M.current_environment(opts)
end

---Return a compact status table for statusline integrations.
---@param opts? { notify?: boolean }
---@return { collection: string?, root: string?, environment: string? }
function M.status(opts)
  local collection = M.current_collection()
  return {
    collection = collection and collection.name or nil,
    root = collection and collection.root or nil,
    environment = M.current_environment(opts),
  }
end

---Return the last run result.
---@return bruno.RunResult?
function M.last_result()
  return state.last_result
end

---@param opts? bruno.Config
---@return bruno.Config
function M.setup(opts)
  local options = config.setup(opts)

  require('bruno.ui').setup()
  pcall(vim.treesitter.language.register, 'markdown', 'bruno_ui')
  require('bruno.ts_injections').setup()

  vim.filetype.add({
    extension = {
      bru = 'bruno',
    },
  })

  if commands_registered then
    return options
  end
  commands_registered = true

  local function command(name, callback, command_opts)
    vim.api.nvim_create_user_command(name, callback, command_opts or {})
  end

  command('Bruno', function()
    M.open()
  end, { desc = 'Bruno: open the request workbench' })

  command('BrunoOpen', function()
    M.open()
  end, { desc = 'Bruno: open the request workbench' })

  command('BrunoToggle', function()
    M.toggle()
  end, { desc = 'Bruno: toggle/focus the request workbench' })

  command('BrunoDetect', function(args)
    local detect = require('bruno.detect')
    local detection
    if args.bang then
      detection = M.refresh_detection()
    else
      detection = M.detect_collection()
    end
    local lines = detect.describe(detection)
    vim.api.nvim_echo({ { table.concat(lines, '\n'), 'None' } }, true, {})
    for _, line in ipairs(lines) do
      log.info(line)
    end
  end, { bang = true, desc = 'Bruno: detect/refresh collection for cwd' })

  command('BrunoRun', function(args)
    if args.args and args.args ~= '' then
      M.run(vim.fn.expand(args.args))
    else
      local request = current_request()
      M.run(request)
    end
  end, { nargs = '?', complete = 'file', desc = 'Bruno: run request' })

  command('BrunoReplay', function()
    M.replay()
  end, { desc = 'Bruno: replay last request' })

  command('BrunoCancel', function()
    M.cancel()
  end, { desc = 'Bruno: cancel the running request' })

  command('BrunoEnv', function(args)
    M.env(args.args ~= '' and args.args or nil)
  end, {
    nargs = '?',
    desc = 'Bruno: select environment',
    complete = function()
      local root = require('bruno.env').current_root()
      if not root then
        return {}
      end
      local names = {}
      for _, environment in ipairs(parsers.list_environments(root)) do
        names[#names + 1] = environment.name
      end
      return names
    end,
  })

  command('BrunoRequests', function()
    M.pick_request()
  end, { desc = 'Bruno: pick a request' })

  command('BrunoAuth', function(args)
    local action = args.args ~= '' and args.args or 'login'
    if action == 'login' then
      M.auth()
    elseif action == 'clear' then
      M.auth_clear()
    elseif action == 'status' then
      M.auth_status()
    else
      log.notify('Bruno: unknown auth action: ' .. action, 'warn')
    end
  end, {
    nargs = '?',
    desc = 'Bruno: OAuth2 login/clear/status',
    complete = function()
      return { 'login', 'clear', 'status' }
    end,
  })

  command('BrunoAuthClear', function()
    M.auth_clear()
  end, { desc = 'Bruno: clear cached OAuth2 token' })

  command('BrunoClearTokens', function()
    M.clear_tokens()
    log.notify('Bruno: OAuth2 token cache cleared', 'info')
  end, { desc = 'Bruno: clear every cached OAuth2 token' })

  command('BrunoAuthStatus', function()
    M.auth_status()
  end, { desc = 'Bruno: show OAuth2 status' })

  command('BrunoCopy', function()
    M.copy_curl()
  end, { desc = 'Bruno: copy request as cURL' })

  command('BrunoCopyCurl', function()
    M.copy_curl()
  end, { desc = 'Bruno: copy request as cURL' })

  -- Compatibility aliases from the SugarHashira/bruno.nvim command surface.
  command('BrunoSearch', function()
    M.pick_request()
  end, { desc = 'Bruno: search requests' })

  command('BrunoInspect', function()
    local request = current_request()
    M.open({ request = request })
    M.tab('request')
  end, { desc = 'Bruno: inspect the current request' })

  command('BrunoToggleView', function()
    local ui = require('bruno.ui')
    if not ui.buf then
      M.open()
    end
    ui.next_tab(1)
  end, { desc = 'Bruno: cycle workbench tabs' })

  command('BrunoStats', function()
    local request = current_request()
    M.open({ request = request })
    M.tab('timeline')
  end, { desc = 'Bruno: show request/response stats' })

  command('BrunoClose', function()
    M.close()
  end, { desc = 'Bruno: close the workbench' })

  command('BrunoTab', function(args)
    M.tab(args.args ~= '' and args.args or nil)
  end, {
    nargs = '?',
    desc = 'Bruno: select workbench tab',
    complete = function()
      return config.get().ui.tabs
    end,
  })

  vim.keymap.set('n', '<Plug>(bruno-run)', function()
    M.run(current_request())
  end, { desc = 'Bruno: run request' })
  vim.keymap.set('n', '<Plug>(bruno-open)', function()
    M.open()
  end, { desc = 'Bruno: open workbench' })
  vim.keymap.set('n', '<Plug>(bruno-requests)', function()
    M.pick_request()
  end, { desc = 'Bruno: pick request' })

  return options
end

return M
