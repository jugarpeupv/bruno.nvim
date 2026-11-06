local fs = require('bruno.utils.fs')
local Json = require('bruno.utils.json')
local log = require('bruno.utils.log')
local parsers = require('bruno.parsers')
local state = require('bruno.state')

local M = {}

---@class bruno.RunOptions
---@field env? string
---@field extra_args? string[]
---@field silent? boolean
---@field on_done? fun(result: bruno.RunResult?, err: string?)

---@param data any
---@return bruno.Result[]
---@return table?
function M.normalize_output(data)
  local results = {}
  local summary

  if type(data) ~= 'table' then
    return results, nil
  end

  if type(data.results) == 'table' then
    for _, result in ipairs(data.results) do
      results[#results + 1] = result
    end
    summary = data.summary
    return results, summary
  end

  if vim.islist(data) then
    for _, iteration in ipairs(data) do
      if type(iteration) == 'table' then
        if type(iteration.results) == 'table' then
          for _, result in ipairs(iteration.results) do
            results[#results + 1] = result
          end
        end
        if not summary and type(iteration.summary) == 'table' then
          summary = iteration.summary
        end
      end
    end
  end

  return results, summary
end

---@param request bruno.Request
---@param env? string
---@param extra_args? string[]
---@return string[] command
---@return string output_path
---@return string root
function M.build_command(request, env, extra_args)
  local config = require('bruno.config').get()
  local output_path = vim.fn.tempname() .. '.json'
  local command = {
    config.cli,
    'run',
    fs.relpath(request.root, request.path),
    '--output',
    output_path,
    '--format',
    'json',
  }

  if env and env ~= '' then
    table.insert(command, '--env')
    table.insert(command, env)
  end

  local session = require('bruno.session_vars')
  vim.list_extend(command, session.args(request, env))

  for _, arg in ipairs(config.cli_args or {}) do
    table.insert(command, arg)
  end
  for _, arg in ipairs(extra_args or {}) do
    table.insert(command, arg)
  end

  return command, output_path, request.root
end

---@param results bruno.Result[]
---@param summary? table
---@return string
function M.summary_message(results, summary)
  if summary and summary.totalRequests then
    return string.format(
      'Bruno: %d request(s), %d passed, %d failed',
      summary.totalRequests or 0,
      summary.passedRequests or 0,
      summary.failedRequests or 0
    )
  end
  if #results == 0 then
    return 'Bruno: no requests were executed'
  end
  local passed = 0
  for _, result in ipairs(results) do
    if result.status == 'pass' then
      passed = passed + 1
    end
  end
  return string.format('Bruno: %d request(s), %d passed', #results, passed)
end

---@param request bruno.Request
---@param staged_path string
---@param opts bruno.RunOptions
---@param env? string
local function execute(request, staged_path, opts, env)
  local config = require('bruno.config').get()
  local ui = require('bruno.ui')
  local output_path = vim.fn.tempname() .. '.json'

  local command = {
    config.cli,
    'run',
    fs.relpath(request.root, staged_path),
    '--output',
    output_path,
    '--format',
    'json',
  }

  if env and env ~= '' then
    table.insert(command, '--env')
    table.insert(command, env)
  end
  local session = require('bruno.session_vars')
  vim.list_extend(command, session.args(request, env))
  for _, arg in ipairs(config.cli_args or {}) do
    table.insert(command, arg)
  end
  for _, arg in ipairs(opts.extra_args or {}) do
    table.insert(command, arg)
  end

  state.last_command = command
  state.running = true
  state.env_before = parsers.request_vars(request, env)
  ui.before_run(request)

  vim.api.nvim_exec_autocmds('User', {
    pattern = 'BrunoRequestStarted',
    data = { request = request, command = command },
  })

  local function finish(result, err)
    state.running = false
    state.job = nil
    fs.unlink(output_path)
    if staged_path ~= request.path then
      fs.unlink(staged_path)
    end

    if err then
      state.last_error = err
      state.last_result = nil
      ui.show_error(err)
      log.error(err)
      vim.api.nvim_exec_autocmds('User', {
        pattern = 'BrunoRequestFinished',
        data = { request = request, error = err },
      })
      if opts.on_done then
        opts.on_done(nil, err)
      end
      return
    end

    state.set_result(result)
    require('bruno.session_vars').remember(request, env, result)
    ui.show_result(result)
    if not opts.silent then
      log.info(M.summary_message(result.results, result.summary))
    end
    vim.api.nvim_exec_autocmds('User', {
      pattern = 'BrunoRequestFinished',
      data = { request = request, result = result },
    })
    if opts.on_done then
      opts.on_done(result, nil)
    end
  end

  local timeout = config.timeout and config.timeout > 0 and config.timeout or nil
  local ok, job = pcall(vim.system, command, {
    cwd = request.root,
    text = true,
    timeout = timeout,
  }, function(res)
    vim.schedule(function()
      local raw = ''
      if vim.fn.filereadable(output_path) == 1 then
        raw = fs.read_file(output_path) or ''
      end

      if res.code ~= 0 and (raw == '' or raw == '[]') then
        local detail = vim.trim(res.stderr or '')
        if detail == '' then
          detail = vim.trim(res.stdout or '')
        end
        if detail == '' then
          detail = 'bru exited with code ' .. tostring(res.code)
        end
        finish(nil, 'Bruno run failed: ' .. detail)
        return
      end

      local data, decode_err = Json.decode(raw)
      if not data then
        finish(nil, 'could not parse Bruno CLI output: ' .. tostring(decode_err))
        return
      end

      local results, summary = M.normalize_output(data)
      if #results == 0 and res.code ~= 0 then
        local detail = vim.trim(res.stderr or '')
        finish(nil, 'Bruno run failed: ' .. (detail ~= '' and detail or tostring(res.code)))
        return
      end

      finish({
        request = request,
        raw = raw,
        data = data,
        results = results,
        summary = summary,
        stdout = res.stdout or '',
        stderr = res.stderr or '',
        code = res.code,
        env = env,
        command = command,
      }, nil)
    end)
  end)

  if not ok then
    finish(nil, 'could not start the Bruno CLI: ' .. tostring(job))
    return
  end

  state.job = job
end

---Run a request through the Bruno CLI.
---@param request? bruno.Request|string
---@param opts? bruno.RunOptions
---@return boolean started
function M.run(request, opts)
  opts = opts or {}
  local ui = require('bruno.ui')
  local config = require('bruno.config').get()

  if type(request) == 'string' then
    local ok, parsed = pcall(parsers.parse_request, request)
    if not ok then
      log.notify('Bruno: could not read request: ' .. tostring(parsed), 'error')
      return false
    end
    request = parsed
  end

  if not request then
    local current = parsers.current_request_path()
    if current then
      request = parsers.parse_request(current)
    else
      request = state.last_request
    end
  end

  if not request then
    log.notify('Bruno: no request selected. Open a .bru/.yml request or use :BrunoRequests', 'warn')
    return false
  end

  if vim.fn.executable(config.cli) ~= 1 then
    log.notify('Bruno: CLI executable not found: ' .. config.cli, 'error')
    return false
  end

  state.set_request(request)

  local env_mod = require('bruno.env')
  local env = opts.env
  if env and env ~= '' then
    env_mod.set(request.root, env)
  else
    env = env_mod.ensure(request.root)
  end
  local auth = parsers.resolve_auth(request)

  if auth and config.oauth2.enabled ~= false then
    local oauth2 = require('bruno.oauth2')
    oauth2.ensure_token(request, { env = env }, function(token, err, oauth_config)
      if not oauth_config then
        execute(request, request.path, opts, env)
        return
      end
      if not token then
        vim.schedule(function()
          state.last_error = err
          state.last_result = nil
          ui.show_error('OAuth2 authentication failed: ' .. tostring(err))
          log.notify('Bruno: OAuth2 authentication failed: ' .. tostring(err), 'error')
        end)
        return
      end

      local inject = require('bruno.oauth2.inject')
      local staged, stage_err = inject.build(request, token, oauth_config)
      if not staged then
        vim.schedule(function()
          state.last_error = stage_err
          state.last_result = nil
          ui.show_error('OAuth2 token injection failed: ' .. tostring(stage_err))
          log.notify('Bruno: could not prepare the authenticated request: ' .. tostring(stage_err), 'error')
        end)
        return
      end

      execute(request, staged, opts, env)
    end)
  else
    if auth then
      log.notify('Bruno: OAuth2 support is disabled; running the request without a token', 'warn')
    end
    execute(request, request.path, opts, env)
  end

  return true
end

---Re-run the last request.
---@param opts? bruno.RunOptions
---@return boolean started
function M.replay(opts)
  if not state.last_request then
    log.notify('Bruno: no request has been run yet', 'warn')
    return false
  end
  return M.run(state.last_request, opts)
end

---Cancel the currently running CLI process.
function M.cancel()
  if state.job then
    state.job:kill('sigint')
    state.job = nil
  end
  state.running = false
end

return M
