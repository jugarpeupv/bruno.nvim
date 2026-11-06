local fs = require('bruno.utils.fs')
local Json = require('bruno.utils.json')
local log = require('bruno.utils.log')
local parsers = require('bruno.parsers')
local env_mod = require('bruno.env')
local history = require('bruno.history')
local state = require('bruno.state')
local tabs = require('bruno.ui.tabs')

local M = {}

local TAB_LABELS = {
  request = 'Request',
  response = 'Response',
  tests = 'Tests',
  scripts = 'Scripts',
  raw = 'Raw',
  logs = 'Logs',
  verbose = 'Verbose',
}

---@type table<integer, bruno.UIState>
local states = {}

---@type table<integer, boolean>
local bound = {}

---@type integer?
M.buf = nil

---@type integer?
M.win = nil

local namespace = vim.api.nvim_create_namespace('bruno-ui')
local logs_refresh_pending = false
local logs_listener_registered = false

---Return a tab name that is present in `config.ui.tabs`, falling back to the
---first tab when `name` is missing or unknown.
---@param config bruno.Config
---@param name string?
---@return string
local function valid_tab_name(config, name)
  for _, candidate in ipairs(config.ui.tabs) do
    if candidate == name then
      return name
    end
  end
  return config.ui.tabs[1] or 'request'
end

---@param bufnr integer
---@return bruno.UIState
function M.state(bufnr)
  local config = require('bruno.config').get()
  states[bufnr] = states[bufnr]
    or {
      request = nil,
      result = nil,
      tab = valid_tab_name(config, config.ui.default_tab),
      running = false,
      error = nil,
    }
  return states[bufnr]
end

---@param bufnr integer
---@return boolean
local function valid_buf(bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---@param win integer
---@return boolean
local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@return bruno.Request?
local function default_request()
  local path = parsers.current_request_path()
  if path then
    local ok, request = pcall(parsers.parse_request, path)
    if ok then
      return request
    end
  end
  local bufnr = M.buf
  if valid_buf(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
    local request = M.state(bufnr).request
    if request then
      return request
    end
  end
  if state.last_request then
    return state.last_request
  end
  return nil
end

---@return bruno.RunResult?
local function current_result()
  local bufnr = M.buf
  if valid_buf(bufnr) then
    local result = M.state(bufnr).result
    if result then
      return result
    end
  end
  return state.last_result
end

---@param lines string[]
---@return string
local function join(lines)
  return table.concat(lines, '\n')
end

---@param value any
---@return string
local function to_text(value)
  if value == nil or value == vim.NIL then
    return ''
  end
  if type(value) == 'table' then
    return Json.pretty(value)
  end
  local text = tostring(value)
  if Json.looks_like_json(text) then
    return Json.pretty_string(text)
  end
  return text
end

---@param status any
---@return string
local function status_hl(status)
  local text = tostring(status)
  local code = tonumber(text:match('^(%d+)') or '')
  if not code then
    local lowered = text:lower()
    if lowered == 'error' or lowered == 'fail' or lowered == 'failed' then
      return 'BrunoError'
    end
    if lowered == 'pass' or lowered == 'passed' then
      return 'BrunoOk'
    end
    if lowered == 'skipped' then
      return 'BrunoWarn'
    end
    return 'BrunoMuted'
  end
  if code >= 200 and code < 300 then
    return 'BrunoOk'
  end
  if code >= 300 and code < 400 then
    return 'BrunoWarn'
  end
  return 'BrunoError'
end

---@param request bruno.Request
---@return string
local function env_for(request)
  return env_mod.ensure(request.root) or ''
end

---@param bufnr integer
---@return string[]
---@return table[] spans
---@return table[] regions
local function build_tabline(bufnr)
  local config = require('bruno.config').get()
  local ui_state = M.state(bufnr)
  local active = ui_state.tab
  local labels = {}
  local spans = {}
  local regions = {}
  local cursor = 0

  for _, name in ipairs(config.ui.tabs) do
    local label = TAB_LABELS[name] or name
    local text = name == active and ('[' .. label .. ']') or label
    labels[#labels + 1] = text
    spans[#spans + 1] = {
      col = cursor,
      end_col = cursor + #text,
      hl = name == active and 'BrunoTabActive' or 'BrunoTabInactive',
    }
    regions[#regions + 1] = {
      name = name,
      col = cursor,
      end_col = cursor + #text,
    }
    cursor = cursor + #text + 2
  end

  return { table.concat(labels, '  ') }, spans, regions
end

---@param env? string
---@param request_index? integer
---@param request_total? integer
---@return string
---@return table[] spans
local function build_meta(env, request_index, request_total)
  local env_name = env and env ~= '' and env or 'none'
  local text = ''
  local spans = {}

  if request_index then
    text = string.format('Request: %d/%d', request_index, request_total or 0)
    spans[#spans + 1] = { col = 0, end_col = #text, hl = 'BrunoMuted' }
    text = text .. ' · '
  end

  local label = 'Selected env: '
  local label_start = #text
  text = text .. label .. env_name
  spans[#spans + 1] = { col = label_start, end_col = label_start + #label, hl = 'BrunoMuted' }
  spans[#spans + 1] = { col = label_start + #label, end_col = #text, hl = 'BrunoEnv' }

  return text, spans
end

---@param request? bruno.Request
---@param ui_state bruno.UIState
---@param env? string
---@return string[] lines
---@return table[] spans
local function build_title(request, ui_state, env)
  if not request then
    return { 'Bruno' }, {}
  end

  local method = request.method or 'GET'
  local target = request.url or ''
  if request.root and request.root ~= '' then
    target = parsers.resolved_url(request, env)
  end
  local text = method .. '  ' .. target
  local spans = {
    { row = 0, col = 0, end_col = #method, hl = 'BrunoMethod' },
    { row = 0, col = #method + 2, end_col = #method + 2 + #target, hl = 'BrunoUrl' },
  }

  local suffix
  local suffix_hl = 'BrunoMuted'
  if ui_state.running then
    suffix = '● running'
    suffix_hl = 'BrunoRunning'
  elseif ui_state.error then
    suffix = 'error'
    suffix_hl = 'BrunoError'
  elseif ui_state.result and ui_state.result.results[1] then
    local item = ui_state.result.results[1]
    local response = item.response or {}
    local status = response.status ~= nil and response.status ~= vim.NIL and response.status or '—'
    local status_text = response.statusText ~= nil
        and response.statusText ~= vim.NIL
        and (' ' .. tostring(response.statusText))
      or ''
    local time = response.responseTime or response.duration
    local size = response.size
    local time_text = time and string.format('%.0f ms', tonumber(time) or 0) or '—'
    local size_text = size and tabs.bytes(size) or '—'
    suffix = string.format('%s%s  ·  %s  ·  %s', tostring(status), status_text, time_text, size_text)
    suffix_hl = status_hl(status)
  else
    suffix = 'not run yet'
  end

  local lines = { text }
  if suffix and suffix ~= '' then
    lines[#lines + 1] = suffix
    spans[#spans + 1] = { row = 1, col = 0, end_col = #suffix, hl = suffix_hl }
  end
  return lines, spans
end

---@param bufnr integer
---@param env? string
---@return string[]
local function build_content(bufnr, env)
  local ui_state = M.state(bufnr)
  local request = ui_state.request
  local config = require('bruno.config').get()

  if not request then
    return {
      'No request selected.',
      '',
      'Open a .bru or .yml request and run :Bruno, or pick one with :BrunoRequests.',
    }
  end

  if ui_state.tab == 'request' then
    return tabs.request_tab(request, env, ui_state.running, ui_state.error, ui_state.result)
  elseif ui_state.tab == 'response' then
    return tabs.response_tab(ui_state.result, ui_state.running, ui_state.error)
  elseif ui_state.tab == 'tests' then
    return tabs.tests_tab(request, ui_state.result, ui_state.running, ui_state.error)
  elseif ui_state.tab == 'scripts' then
    return tabs.scripts_tab(request, ui_state.result, ui_state.running, ui_state.error)
  elseif ui_state.tab == 'raw' then
    return tabs.raw_tab(ui_state.result, ui_state.running, ui_state.error)
  elseif ui_state.tab == 'verbose' then
    local command = ui_state.result and ui_state.result.command or state.last_command
    return tabs.verbose_tab(ui_state.result, ui_state.running, ui_state.error, command)
  elseif ui_state.tab == 'logs' then
    local log = require('bruno.utils.log')
    return tabs.logs_tab(log.entries(), log.path())
  end

  return { 'Unknown tab: ' .. tostring(config.ui.tabs and ui_state.tab or '') }
end

---@param line string
---@return boolean
local function is_section(line)
  return line:match('^#+%s') ~= nil
end

---Highlight for a `key: value` row so response fields match the title bar.
---@param key string
---@param value string
---@param last_status? string
---@return string?
local function value_hl(key, value, last_status)
  if value == '' or value == '—' then
    return 'BrunoMuted'
  end

  if key == 'Status' then
    local lowered = value:lower()
    if lowered:match('^pass') then
      return 'BrunoPass'
    end
    if lowered:match('^fail') then
      return 'BrunoFail'
    end
    if lowered:match('^skip') then
      return 'BrunoMuted'
    end
    return status_hl(value)
  end

  if key == 'Method' then
    return 'BrunoMethod'
  end
  if key == 'URL' then
    return 'BrunoUrl'
  end
  if key == 'Time' or key == 'Response' or key == 'Run' or key == 'Size' then
    return last_status or 'BrunoMuted'
  end
  if key == 'Env' then
    return 'BrunoEnv'
  end
  if key == 'Error' then
    return 'BrunoError'
  end

  return nil
end

---@param bufnr integer
---@param lines string[]
---@param tab_spans table[]
---@param title_spans table[]
---@param meta_spans table[]
---@param header_len integer
local function apply_highlights(bufnr, lines, tab_spans, title_spans, meta_spans, header_len)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

  for _, span in ipairs(tab_spans) do
    vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, span.col, {
      end_col = span.end_col,
      hl_group = span.hl,
    })
  end

  for _, span in ipairs(title_spans) do
    vim.api.nvim_buf_set_extmark(bufnr, namespace, 1 + (span.row or 0), span.col, {
      end_col = span.end_col,
      hl_group = span.hl,
    })
  end

  local meta_row = header_len - 2
  for _, span in ipairs(meta_spans) do
    vim.api.nvim_buf_set_extmark(bufnr, namespace, meta_row, span.col, {
      end_col = span.end_col,
      hl_group = span.hl,
    })
  end

  local last_status
  for index = header_len + 1, #lines do
    local line = lines[index]
    local row = index - 1
    if is_section(line) then
      -- Leave headings to Markdown/Treesitter highlighting.
      last_status = nil
    else
      local key_start, key_end = line:find('^  ([%w%._%-]+)[:=]')
      if key_start then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, row, key_start + 1, {
          end_col = key_end - 1,
          hl_group = 'BrunoKey',
        })

        local key, value = line:match('^  ([%w%._%-]+):%s+(.*)$')
        if key then
          if key == 'Status' then
            local code = tostring(value):match('^(%d%d%d)')
            last_status = code and status_hl(code) or nil
          end

          local _, value_start = line:find('^  [%w%._%-]+:%s+')
          local value_group = value_hl(key, value, last_status)
          if value_group and value_start then
            vim.api.nvim_buf_set_extmark(bufnr, namespace, row, value_start, {
              end_col = #line,
              hl_group = value_group,
            })
          end
        end
      elseif line:match('%] ERROR%s') then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
          end_col = #line,
          hl_group = 'BrunoFail',
        })
      elseif line:match('%] WARN%s') then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
          end_col = #line,
          hl_group = 'BrunoWarn',
        })
      elseif line:match('%] DEBUG%s') then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
          end_col = #line,
          hl_group = 'BrunoMuted',
        })
      elseif line:match('^%s*✓') then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
          end_col = #line,
          hl_group = 'BrunoPass',
        })
      elseif line:match('^%s*✗') then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
          end_col = #line,
          hl_group = 'BrunoFail',
        })
      elseif line:match('^%s*[•→]') then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
          end_col = #line,
          hl_group = 'BrunoMuted',
        })
      end
    end
  end
end

---@param bufnr integer
---@param opts? { reset_cursor?: boolean }
function M.render(bufnr, opts)
  opts = opts or {}
  if not valid_buf(bufnr) then
    return
  end

  require('bruno.ui.hover').close()

  local config = require('bruno.config').get()
  local ui_state = M.state(bufnr)

  local valid_tab = false
  for _, name in ipairs(config.ui.tabs) do
    if name == ui_state.tab then
      valid_tab = true
      break
    end
  end
  if not valid_tab then
    ui_state.tab = config.ui.tabs[1] or 'request'
  end

  local tabline_lines, tab_spans, tab_regions = build_tabline(bufnr)
  local tabline = tabline_lines[1]
  vim.b[bufnr].bruno_tab_regions = tab_regions
  local env = ui_state.request and env_for(ui_state.request) or ''
  local title_lines, title_spans = build_title(ui_state.request, ui_state, env)
  local content = build_content(bufnr, env)
  local history_position = history.position()
  local request_total = history.count()
  local request_index = history_position >= 1 and history_position or nil
  local meta, meta_spans = build_meta(env, request_index, request_total)

  local lines = { tabline }
  vim.list_extend(lines, title_lines)
  lines[#lines + 1] = meta
  lines[#lines + 1] = ''
  local header_len = #lines
  vim.list_extend(lines, content)

  if #lines > 0 and lines[#lines] ~= '' then
    lines[#lines + 1] = ''
  end

  for index, line in ipairs(lines) do
    if line:find('%z') then
      lines[index] = line:gsub('%z', '')
    end
  end

  local cursor_win = valid_win(M.win) and M.win or 0
  local cursor_line = vim.api.nvim_win_get_cursor(cursor_win)[1]
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false

  if vim.bo[bufnr].filetype ~= 'bruno_ui' then
    vim.bo[bufnr].filetype = 'bruno_ui'
    vim.bo[bufnr].syntax = 'markdown'
  elseif vim.bo[bufnr].syntax ~= 'markdown' then
    vim.bo[bufnr].syntax = 'markdown'
  end

  apply_highlights(bufnr, lines, tab_spans, title_spans, meta_spans, header_len)

  local win = M.win
  if valid_win(win) and vim.api.nvim_win_get_buf(win) == bufnr then
    if opts.reset_cursor or cursor_line < header_len + 1 or cursor_line > #lines then
      pcall(vim.api.nvim_win_set_cursor, win, { header_len + 1, 0 })
    else
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor_line, #lines), 0 })
    end
    vim.wo[win].winbar = ''
  end
end

---@param split string
---@return integer
local function create_window(split)
  local config = require('bruno.config').get()
  if split == 'left' then
    vim.cmd('leftabove vsplit')
  elseif split == 'bottom' then
    vim.cmd('rightbelow split')
  else
    vim.cmd('rightbelow vsplit')
  end

  local win = vim.api.nvim_get_current_win()
  if split == 'bottom' then
    local height = math.floor(vim.o.lines * config.ui.height)
    vim.api.nvim_win_set_height(win, math.max(5, math.min(vim.o.lines - 3, height)))
  else
    local width = math.floor(vim.o.columns * config.ui.width)
    vim.api.nvim_win_set_width(win, math.max(20, math.min(vim.o.columns - 3, width)))
  end
  return win
end

---@param bufnr integer
local function ensure_buffer(bufnr)
  if not valid_buf(bufnr) then
    bufnr = vim.api.nvim_create_buf(false, true)
    M.buf = bufnr
    pcall(vim.api.nvim_buf_set_name, bufnr, 'bruno://workbench')
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].filetype = 'bruno_ui'
    vim.bo[bufnr].syntax = 'markdown'
    vim.b[bufnr].bruno_workbench = true
  end
end

---@param bufnr integer
local function bind_keymaps(bufnr)
  if bound[bufnr] then
    return
  end
  bound[bufnr] = true

  local config = require('bruno.config').get()
  local keymaps = config.ui.keymaps

  ---@param name string
  ---@param fn fun()
  ---@param desc string
  local function map(name, fn, desc)
    local lhs = keymaps[name]
    if lhs and lhs ~= false then
      vim.keymap.set('n', lhs, fn, {
        buffer = bufnr,
        silent = true,
        nowait = true,
        desc = desc,
      })
    end
  end

  map('next_tab', function()
    M.next_tab(1)
  end, 'Bruno: next tab')
  map('prev_tab', function()
    M.next_tab(-1)
  end, 'Bruno: previous tab')
  map('next_response', function()
    M.next_response()
  end, 'Bruno: next execution history entry')
  map('prev_response', function()
    M.prev_response()
  end, 'Bruno: previous execution history entry')

  for index = 1, #config.ui.tabs do
    map('tab_' .. index, function()
      M.select_tab(index)
    end, 'Bruno: select tab ' .. index)
  end

  map('replay', function()
    require('bruno.runner').replay()
  end, 'Bruno: replay last request')
  map('edit_source', function()
    M.edit_source()
  end, 'Bruno: edit request source')
  map('env', function()
    M.pick_env()
  end, 'Bruno: select environment')
  map('requests', function()
    M.pick_request()
  end, 'Bruno: pick request')
  map('auth', function()
    M.auth()
  end, 'Bruno: acquire OAuth2 token')
  map('auth_clear', function()
    M.auth_clear()
  end, 'Bruno: clear OAuth2 token')
  map('copy_curl', function()
    M.copy_curl()
  end, 'Bruno: copy as cURL')
  map('yank_body', function()
    M.yank_body()
  end, 'Bruno: yank response body')
  map('yank_raw', function()
    M.yank_raw()
  end, 'Bruno: yank raw result')
  map('help', function()
    M.help()
  end, 'Bruno: show help')
  map('hover', function()
    local ui_state = M.state(bufnr)
    require('bruno.ui.hover').show(ui_state.request or state.last_request)
  end, 'Bruno: inspect variable under cursor')
  vim.keymap.set('n', 'g?', function()
    M.help()
  end, { buffer = bufnr, silent = true, nowait = true, desc = 'Bruno: show help' })
  map('close', function()
    M.close()
  end, 'Bruno: close workbench')

  local select_tab_lhs = keymaps.select_tab
  if select_tab_lhs and select_tab_lhs ~= false then
    vim.keymap.set('n', select_tab_lhs, function()
      local name = M.tab_at_cursor(bufnr)
      if name then
        M.select_tab(name)
        return
      end

      local win = vim.api.nvim_get_current_win()
      local row = vim.api.nvim_win_get_cursor(win)[1]
      local next_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      if next_line then
        local col = next_line:find('%S') or 1
        pcall(vim.api.nvim_win_set_cursor, win, { row + 1, col - 1 })
      end
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = 'Bruno: open tab under cursor',
    })
  end
end

---Apply an execution-history entry to the workbench state.
---@param ui_state bruno.UIState
---@param entry bruno.HistoryEntry
local function apply_history_entry(ui_state, entry)
  ui_state.request = entry.request
  ui_state.result = entry.result
  ui_state.error = entry.error
  ui_state.running = false
end

---@param opts? { request?: bruno.Request, preserve_result?: boolean, focus?: boolean }
---@return integer? bufnr
function M.open(opts)
  opts = opts or {}
  local previous_win = vim.api.nvim_get_current_win()
  local request = opts.request or default_request()
  if not request then
    log.notify('Bruno: no request selected. Open a .bru/.yml request or use :BrunoRequests', 'warn')
    return nil
  end

  ensure_buffer(M.buf or -1)
  if not valid_buf(M.buf) then
    return nil
  end
  local bufnr = M.buf

  local ui_state = M.state(bufnr)
  if not opts.preserve_result then
    history.seed(request)
  end
  ui_state.request = request

  local entry = history.select_last_for(request.path)
  if entry then
    ui_state.request = entry.request
    ui_state.result = entry.result
    ui_state.error = entry.error
  elseif not opts.preserve_result then
    ui_state.result = nil
    ui_state.error = nil
  end

  if
    not ui_state.result
    and not entry
    and state.last_result
    and state.last_result.request
    and state.last_result.request.path == request.path
  then
    ui_state.result = state.last_result
    history.select_result(state.last_result)
  end
  if
    not ui_state.result
    and not ui_state.error
    and not entry
    and state.last_error
    and state.last_request
    and state.last_request.path == request.path
  then
    ui_state.error = state.last_error
  end
  if not opts.preserve_result and ui_state.result and ui_state.tab == 'request' then
    ui_state.tab = 'response'
  end

  if valid_win(M.win) and vim.api.nvim_win_get_buf(M.win) ~= bufnr then
    M.win = nil
  end

  if not valid_win(M.win) then
    local found_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        found_win = win
        break
      end
    end
    if found_win then
      M.win = found_win
    else
      M.win = create_window(require('bruno.config').get().ui.split)
    end
  end

  if valid_win(M.win) then
    vim.api.nvim_win_set_buf(M.win, bufnr)
    if opts.focus ~= false then
      vim.api.nvim_set_current_win(M.win)
    elseif valid_win(previous_win) and previous_win ~= M.win then
      vim.api.nvim_set_current_win(previous_win)
    end
    vim.wo[M.win].number = false
    vim.wo[M.win].relativenumber = false
    vim.wo[M.win].wrap = false
    vim.wo[M.win].signcolumn = 'no'
    vim.wo[M.win].foldcolumn = '0'
    vim.wo[M.win].cursorline = false
    vim.wo[M.win].spell = false
    vim.wo[M.win].list = false
  end

  bind_keymaps(bufnr)
  M.render(bufnr, { reset_cursor = true })

  -- Setting `foldexpr` can initialize the Treesitter fold cache before the
  -- Markdown parser is available. Re-emit FileType once so Markdown plugins
  -- and the fold cache initialize against the populated buffer.
  if vim.bo[bufnr].filetype == 'bruno_ui' and not vim.b[bufnr].bruno_fold_ready then
    vim.b[bufnr].bruno_fold_ready = true
    vim.api.nvim_exec_autocmds('FileType', { buffer = bufnr, modeline = false })
    if vim.bo[bufnr].filetype == 'bruno_ui' then
      vim.bo[bufnr].syntax = 'markdown'
    end
  end

  if valid_win(M.win) then
    if vim.wo[M.win].foldmethod ~= 'expr' or vim.wo[M.win].foldexpr ~= 'v:lua.vim.treesitter.foldexpr()' then
      vim.wo[M.win].foldmethod = 'expr'
      vim.wo[M.win].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
      vim.wo[M.win].foldenable = true
      vim.wo[M.win].foldlevel = 99
    end
  end

  if not vim.b[bufnr].bruno_ts_started then
    vim.b[bufnr].bruno_ts_started = true
    pcall(vim.treesitter.start, bufnr, 'markdown')
  end

  return bufnr
end

---@param request bruno.Request
function M.before_run(request)
  state.last_request = request
  local config = require('bruno.config').get()
  local bufnr = M.buf

  if config.ui.auto_open or (valid_buf(bufnr) and valid_win(M.win)) then
    bufnr = M.open({ request = request, preserve_result = true, focus = false }) or bufnr
  end

  if valid_buf(bufnr) then
    local ui_state = M.state(bufnr)
    ui_state.request = request
    ui_state.running = true
    ui_state.error = nil
    ui_state.result = nil
    M.render(bufnr)
  end
end

---@param result bruno.RunResult
function M.show_result(result)
  state.set_result(result)
  history.record(result.request, result, result.env)
  result.vars_before = state.env_before
  result.vars_after = parsers.request_vars(result.request, result.env)
  local bufnr = M.buf
  if valid_buf(bufnr) then
    local ui_state = M.state(bufnr)
    ui_state.request = result.request
    ui_state.result = result
    ui_state.running = false
    ui_state.error = nil
    M.render(bufnr, { reset_cursor = true })
  end
end

---@param error string
function M.show_error(error)
  state.last_error = error
  history.record_error(state.last_request, error)
  local bufnr = M.buf
  if valid_buf(bufnr) then
    local ui_state = M.state(bufnr)
    ui_state.running = false
    ui_state.error = error
    ui_state.result = nil
    M.render(bufnr)
  end
end

---@param bufnr integer
---@return string? name
function M.tab_at_cursor(bufnr)
  local win = vim.api.nvim_get_current_win()
  if not valid_buf(bufnr) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  if cursor[1] ~= 1 then
    return nil
  end

  local col = cursor[2]
  for _, region in ipairs(vim.b[bufnr].bruno_tab_regions or {}) do
    if col >= region.col and col < region.end_col then
      return region.name
    end
  end
  return nil
end

---@param index integer|string
function M.select_tab(index)
  local config = require('bruno.config').get()
  local name = index
  if type(index) == 'number' then
    name = config.ui.tabs[index]
  end
  if not name then
    return
  end

  local bufnr = M.buf
  if not valid_buf(bufnr) then
    return
  end
  M.state(bufnr).tab = name
  M.render(bufnr, { reset_cursor = true })
end

---@param delta integer
function M.next_tab(delta)
  local config = require('bruno.config').get()
  local bufnr = M.buf
  if not valid_buf(bufnr) then
    return
  end
  local ui_state = M.state(bufnr)
  local index = 1
  for position, name in ipairs(config.ui.tabs) do
    if name == ui_state.tab then
      index = position
      break
    end
  end
  index = ((index - 1 + delta) % #config.ui.tabs) + 1
  ui_state.tab = config.ui.tabs[index]
  M.render(bufnr, { reset_cursor = true })
end

---Move through the execution history (previous runs).
---@param delta integer
function M.navigate_response(delta)
  local bufnr = M.buf
  if not valid_buf(bufnr) then
    return
  end
  if history.count() == 0 then
    return
  end

  local entry = history.move(delta)
  if not entry then
    return
  end

  apply_history_entry(M.state(bufnr), entry)
  M.render(bufnr, { reset_cursor = true })
end

---Show the previous execution in the history.
function M.prev_response()
  M.navigate_response(-1)
end

---Show the next execution in the history.
function M.next_response()
  M.navigate_response(1)
end

---@return integer?
local function find_workbench_window()
  if not valid_buf(M.buf) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == M.buf then
      return win
    end
  end
  return nil
end

---Toggle the workbench: focus it if visible, close it if focused, open it otherwise.
---@return boolean handled
function M.toggle()
  local win = find_workbench_window()
  if win then
    M.win = win
    if vim.api.nvim_get_current_win() == win then
      M.close()
    else
      vim.api.nvim_set_current_win(win)
    end
    return true
  end

  return M.open({ focus = true }) ~= nil
end

---Close the workbench window without deleting its buffer.
function M.close()
  require('bruno.ui.hover').close()
  local win = find_workbench_window()
  if win then
    pcall(vim.api.nvim_win_close, win, true)
  end
  M.win = nil
end

---Destroy the workbench buffer and clear its state.
function M.destroy()
  M.close()
  if valid_buf(M.buf) then
    pcall(vim.api.nvim_buf_delete, M.buf, { force = true })
  end
  M.buf = nil
  states = {}
  bound = {}
  history.reset()
end

---Open the request source in the previous window.
function M.edit_source()
  local bufnr = M.buf
  local request = valid_buf(bufnr) and M.state(bufnr).request or state.last_request
  if not request then
    log.notify('Bruno: no request selected', 'warn')
    return
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= M.win then
      vim.api.nvim_set_current_win(win)
      break
    end
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(request.path))
end

---Pick an environment for the current collection.
function M.pick_env()
  local root = env_mod.current_root()
  if not root then
    log.notify('Bruno: no collection detected. Run :BrunoDetect to inspect detection.', 'warn')
    return
  end

  local environments = env_mod.choices(root, true)
  if #environments == 0 then
    log.notify('Bruno: no environments found in ' .. root .. '/environments', 'warn')
    return
  end

  local current = env_mod.ensure(root)
  local items = { { name = '<default>', value = '' } }
  for _, environment in ipairs(environments) do
    items[#items + 1] = { name = environment.name, value = environment.name }
  end

  vim.ui.select(items, {
    prompt = 'Bruno environment',
    format_item = function(item)
      local marker = item.value == (current or '')
      return (marker and '● ' or '  ') .. item.name
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.value == '' then
      env_mod.clear(root)
    else
      env_mod.set(root, choice.value)
    end
    log.notify('Bruno environment: ' .. (choice.value == '' and '(default)' or choice.value), 'info')
    if valid_buf(M.buf) then
      M.render(M.buf)
    end
  end)
end

---@return string[]
local function picker_roots()
  local detection = require('bruno.detect').detect()
  local roots = vim.deepcopy(detection.roots)

  local request = default_request()
  if request and request.root then
    local present = false
    for _, root in ipairs(roots) do
      if root == request.root then
        present = true
        break
      end
    end
    if not present then
      roots[#roots + 1] = request.root
    end
  end

  return roots
end

---Pick a request from the detected collection(s).
function M.pick_request()
  require('bruno.requests').clear()
  local roots = picker_roots()
  if #roots == 0 then
    log.notify('Bruno: no collection detected in ' .. vim.fn.getcwd() .. '. Run :BrunoDetect to inspect.', 'warn')
    return
  end

  local requests = parsers.list_from_roots(roots)
  if #requests == 0 then
    log.notify('Bruno: no requests found in ' .. table.concat(roots, ', '), 'warn')
    return
  end

  local multiple = #roots > 1
  vim.ui.select(requests, {
    prompt = 'Bruno request',
    format_item = function(item)
      local label = item.relpath
      if multiple then
        label = fs.basename(item.root) .. '/' .. item.relpath
      end
      return string.format('%-7s %-30s %s', item.method, item.name, label)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local ok, request = pcall(parsers.parse_request, choice.path)
    if not ok then
      log.notify('Bruno: could not read request: ' .. tostring(request), 'error')
      return
    end
    state.set_request(request)
    M.open({ request = request })
    require('bruno.runner').run(request)
  end)
end

---Acquire/login an OAuth2 token for the current request.
function M.auth()
  local request = default_request()
  if not request then
    log.notify('Bruno: no request selected', 'warn')
    return
  end

  local oauth2 = require('bruno.oauth2')
  local config = oauth2.config(request, env_for(request))
  if not config then
    log.notify('Bruno: this request does not use OAuth2 authentication', 'warn')
    return
  end

  log.notify('Bruno: acquiring OAuth2 token…', 'info')
  oauth2.login(request, { env = env_for(request) }, function(token, err)
    if token then
      log.notify('Bruno: OAuth2 token acquired', 'info')
      if valid_buf(M.buf) then
        M.render(M.buf)
      end
    else
      log.notify('Bruno: OAuth2 authentication failed: ' .. tostring(err), 'error')
    end
  end)
end

---Clear the cached OAuth2 token for the current request.
function M.auth_clear()
  local request = default_request()
  if not request then
    log.notify('Bruno: no request selected', 'warn')
    return
  end
  local oauth2 = require('bruno.oauth2')
  local removed = oauth2.logout(request, env_for(request))
  log.notify(removed and 'Bruno: OAuth2 token cleared' or 'Bruno: no cached OAuth2 token', 'info')
  if valid_buf(M.buf) then
    M.render(M.buf)
  end
end

---Copy the current request as a cURL command.
function M.copy_curl()
  local request = default_request()
  if not request then
    log.notify('Bruno: no request selected', 'warn')
    return
  end

  local oauth2 = require('bruno.oauth2')
  local token, config = oauth2.cached_token(request, env_for(request))
  if config and not token then
    log.notify('Bruno: no cached OAuth2 token; run :BrunoAuth first', 'warn')
  end
  local command = require('bruno.curl').copy(request, {
    env = env_for(request),
    token = token,
    oauth2 = config,
  })
  log.notify('Bruno: copied cURL command (' .. #command .. ' bytes)', 'info')
end

---Yank the displayed response body into the `+` register.
function M.yank_body()
  local result = current_result()
  if not result or not result.results[1] then
    log.notify('Bruno: no response body to yank', 'warn')
    return
  end
  local response = result.results[1].response or {}
  local text = to_text(response.data)
  vim.fn.setreg('+', text)
  log.notify('Bruno: response body copied', 'info')
end

---Yank the displayed raw Bruno CLI JSON into the `+` register.
function M.yank_raw()
  local result = current_result()
  if not result or result.raw == '' then
    log.notify('Bruno: no raw result to yank', 'warn')
    return
  end
  vim.fn.setreg('+', result.raw)
  log.notify('Bruno: raw result copied', 'info')
end

---Show the workbench keymap help.
function M.help()
  local config = require('bruno.config').get()
  local keymaps = config.ui.keymaps
  local lines = {
    'bruno.nvim — workbench keymaps',
    '',
    string.format('  %-8s %s', keymaps.next_tab or '—', 'next tab'),
    string.format('  %-8s %s', keymaps.prev_tab or '—', 'previous tab'),
    string.format('  %-8s %s', keymaps.next_response or '—', 'next execution in history'),
    string.format('  %-8s %s', keymaps.prev_response or '—', 'previous execution in history'),
    string.format('  %-8s %s', keymaps.select_tab or '—', 'open tab under cursor'),
    string.format('  %-8s %s', '1..' .. #config.ui.tabs, 'select tab directly'),
    '',
    string.format('  %-8s %s', keymaps.replay or '—', 'replay last request'),
    string.format('  %-8s %s', keymaps.edit_source or '—', 'edit request source'),
    string.format('  %-8s %s', keymaps.env or '—', 'select environment'),
    string.format('  %-8s %s', keymaps.requests or '—', 'pick and run a request'),
    '',
    string.format('  %-8s %s', keymaps.auth or '—', 'acquire OAuth2 token'),
    string.format('  %-8s %s', keymaps.auth_clear or '—', 'clear OAuth2 token'),
    string.format('  %-8s %s', keymaps.copy_curl or '—', 'copy as cURL'),
    string.format('  %-8s %s', keymaps.yank_body or '—', 'yank response body'),
    string.format('  %-8s %s', keymaps.yank_raw or '—', 'yank raw result'),
    string.format('  %-8s %s', keymaps.hover or '—', 'inspect {{variable}} under cursor'),
    '',
    string.format('  %-8s %s', keymaps.help or '—', 'show this help'),
    string.format('  %-8s %s', keymaps.close or '—', 'close workbench'),
  }

  local width = math.min(70, math.max(40, vim.o.columns - 8))
  local height = math.min(#lines + 2, math.max(10, vim.o.lines - 8))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'text'

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' bruno.nvim ',
    title_pos = 'center',
  })

  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', '<cmd>close<cr>', { buffer = buf, silent = true })
  vim.keymap.set('n', '?', '<cmd>close<cr>', { buffer = buf, silent = true })
  return win
end

---Refresh the Logs tab when new plugin logs are written.
function M.refresh_logs()
  local bufnr = M.buf
  if logs_refresh_pending or not valid_buf(bufnr) or M.state(bufnr).tab ~= 'logs' then
    return
  end

  logs_refresh_pending = true
  vim.schedule(function()
    logs_refresh_pending = false
    local current = M.buf
    if valid_buf(current) and M.state(current).tab == 'logs' then
      M.render(current)
    end
  end)
end

---Register highlights and UI autocommands.
function M.setup()
  require('bruno.ui.highlight').setup()

  if not logs_listener_registered then
    logs_listener_registered = true
    require('bruno.utils.log').on_change(M.refresh_logs)
  end

  local group = vim.api.nvim_create_augroup('BrunoUI', { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args)
      states[args.buf] = nil
      bound[args.buf] = nil
      if M.buf == args.buf then
        M.buf = nil
        M.win = nil
      end
    end,
  })
end

return M
