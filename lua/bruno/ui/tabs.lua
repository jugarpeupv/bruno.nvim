local Json = require('bruno.utils.json')
local parsers = require('bruno.parsers')

local M = {}

---@param bytes any
---@return string
function M.bytes(bytes)
  local value = tonumber(bytes)
  if not value then
    return '—'
  end
  if value < 1024 then
    return string.format('%d B', value)
  end
  if value < 1024 * 1024 then
    return string.format('%.1f KiB', value / 1024)
  end
  return string.format('%.1f MiB', value / (1024 * 1024))
end

---@param value any
---@return string
function M.ms(value)
  local number = tonumber(value)
  if not number then
    return '—'
  end
  if number < 1 then
    return string.format('%.2f ms', number)
  end
  return string.format('%.0f ms', number)
end

---@param lines string[]
---@param title string
local function section(lines, title)
  if #lines > 0 then
    lines[#lines + 1] = ''
  end
  lines[#lines + 1] = '## ' .. title
end

---@param value any
---@return boolean
local function present(value)
  return value ~= nil and value ~= vim.NIL and value ~= ''
end

---@param lines string[]
---@param key string
---@param value any
local function kv(lines, key, value)
  local text = value
  if not present(text) then
    text = '—'
  end
  lines[#lines + 1] = string.format('  %-14s %s', key .. ':', tostring(text))
end

---@param lines string[]
---@param text string?
local function raw_block(lines, text)
  if not text or text == '' then
    lines[#lines + 1] = '  (none)'
    return
  end
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    lines[#lines + 1] = line
  end
end

---@param lines string[]
---@param language string
---@param text string?
local function fenced_block(lines, language, text)
  if not text or text == '' then
    lines[#lines + 1] = '  (none)'
    return
  end
  lines[#lines + 1] = '```' .. language
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = '```'
end

---@param result? bruno.Result
---@return table<string, any>?
local function response_of(result)
  if not result or type(result.response) ~= 'table' then
    return nil
  end
  return result.response
end

---@param result? bruno.Result
---@return table<string, any>?
local function request_of(result)
  if not result or type(result.request) ~= 'table' then
    return nil
  end
  return result.request
end

---@param entries bruno.KeyValue[]
---@param separator string
---@return string[]
local function key_value_lines(entries, separator)
  local lines = {}
  for _, entry in ipairs(entries or {}) do
    local prefix = entry.enabled and '  ' or '  ~'
    lines[#lines + 1] = prefix .. entry.name .. separator .. entry.value
  end
  if #lines == 0 then
    lines[#lines + 1] = '  (none)'
  end
  return lines
end

---@param headers any
---@return { name: string, value: string }[]
local function sorted_headers(headers)
  if type(headers) ~= 'table' then
    return {}
  end
  local result = {}
  for name, value in pairs(headers) do
    if value ~= nil and value ~= vim.NIL and tostring(value) ~= '' then
      result[#result + 1] = {
        name = tostring(name),
        value = type(value) == 'table' and Json.encode(value) or tostring(value),
      }
    end
  end
  table.sort(result, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return result
end

---@param lines string[]
---@param headers any
local function header_lines(lines, headers)
  local sorted = sorted_headers(headers)
  if #sorted == 0 then
    lines[#lines + 1] = '  (none)'
    return
  end
  for _, header in ipairs(sorted) do
    lines[#lines + 1] = '  ' .. header.name .. ': ' .. header.value
  end
end

---@param request bruno.Request
---@param env? string
---@param running boolean
---@param error? string
---@param result? bruno.RunResult
---@return string[]
function M.request_tab(request, env, running, error, result)
  local lines = {}

  section(lines, 'REQUEST')
  kv(lines, 'Name', request.name)
  kv(lines, 'File', request.path)
  kv(lines, 'Format', request.format)
  kv(lines, 'Method', request.method)
  kv(lines, 'URL', request.url)
  kv(lines, 'Env', env ~= nil and env ~= '' and env or '(default)')

  local auth = parsers.resolve_effective_auth(request) or request.auth
  if auth and auth.mode ~= 'none' then
    local auth_line = auth.mode
    if auth.mode == 'oauth2' and type(auth.config) == 'table' then
      auth_line = string.format('oauth2 (%s)', auth.config.grant_type or 'authorization_code')
    end
    if auth.source and auth.source ~= request.path then
      auth_line = auth_line .. '  [' .. auth.source .. ']'
    end
    kv(lines, 'Auth', auth_line)
  end

  if running then
    kv(lines, 'State', 'running…')
  end
  if error then
    kv(lines, 'Error', error)
  end

  if env and env ~= '' then
    local resolved = parsers.resolved_url(request, env)
    if resolved ~= request.url then
      section(lines, 'RESOLVED URL')
      lines[#lines + 1] = '  ' .. resolved
    end
  end

  section(lines, 'QUERY PARAMS')
  local params = key_value_lines(request.params, ' = ')
  for _, line in ipairs(params) do
    lines[#lines + 1] = line
  end

  section(lines, 'PATH PARAMS')
  local path_params = key_value_lines(request.path_params, ' = ')
  for _, line in ipairs(path_params) do
    lines[#lines + 1] = line
  end

  section(lines, 'HEADERS')
  local sent = request_of(result and result.results[1] or nil)
  local sent_headers = sent and sorted_headers(sent.headers) or {}
  if #sent_headers > 0 then
    for _, header in ipairs(sent_headers) do
      lines[#lines + 1] = '  ' .. header.name .. ': ' .. header.value
    end
  else
    for _, line in ipairs(key_value_lines(request.headers, ': ')) do
      lines[#lines + 1] = line
    end
  end

  local body = request.body or { mode = 'none' }
  section(lines, 'BODY (' .. (body.mode or 'none') .. ')')
  if body.entries then
    for _, line in ipairs(key_value_lines(body.entries, ' = ')) do
      lines[#lines + 1] = line
    end
  else
    local content = body.content
    if body.mode == 'json' and content then
      content = Json.pretty_string(content)
    end
    if body.mode == 'json' then
      fenced_block(lines, 'json', content)
    else
      raw_block(lines, content)
    end
  end

  if request.vars and (#(request.vars.req or {}) > 0 or #(request.vars.res or {}) > 0) then
    section(lines, 'VARS')
    for _, entry in ipairs(request.vars.req or {}) do
      lines[#lines + 1] = (entry.enabled and '  ' or '  ~') .. entry.name .. ' = ' .. entry.value
    end
    for _, entry in ipairs(request.vars.res or {}) do
      lines[#lines + 1] = '  → ' .. entry.name .. ' = ' .. entry.value
    end
  end

  return lines
end

---@param headers any
---@param name string
---@return string?
local function header_lookup(headers, name)
  if type(headers) ~= 'table' then
    return nil
  end
  for key, value in pairs(headers) do
    if tostring(key):lower() == name then
      return tostring(value)
    end
  end
  return nil
end

---@param response table
---@param body string
---@return string
local function body_language(response, body)
  if type(response.data) == 'table' then
    return 'json'
  end

  local content_type = header_lookup(response.headers, 'content-type')
  if content_type then
    local lowered = content_type:lower()
    if lowered:find('json', 1, true) then
      return 'json'
    end
    if lowered:find('html', 1, true) then
      return 'html'
    end
    if lowered:find('xml', 1, true) then
      return 'xml'
    end
    if lowered:find('javascript', 1, true) or lowered:find('ecmascript', 1, true) then
      return 'javascript'
    end
  end

  if Json.looks_like_json(body) then
    return 'json'
  end

  local trimmed = body:gsub('^%s+', '')
  if trimmed:sub(1, 1) == '<' then
    local lowered = trimmed:lower()
    if lowered:find('<!doctype html', 1, true) or lowered:find('<html', 1, true) then
      return 'html'
    end
    return 'xml'
  end

  return 'text'
end

---@param text string
---@return string
local function strip_ansi(text)
  return (text:gsub('\27%[[%d;?]*[A-Za-z]', ''))
end

---@param text string?
---@return string
local function clean_output(text)
  return (strip_ansi(text or ''):gsub('\r\n', '\n'):gsub('\r', '\n'))
end

---@param lines string[]
local function trim_blank(lines)
  while #lines > 0 and lines[1]:match('^%s*$') do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match('^%s*$') do
    table.remove(lines)
  end
end

---Split the CLI stdout into pre-request, post-response, tests and other output.
---The CLI writes `console.*` output before the marker that closes each script
---phase, so the marker order is enough to attribute the lines.
---@param stdout? string
---@return table<string, string[]>
local function parse_script_output(stdout)
  local phases = { pre = {}, post = {}, tests = {}, other = {} }
  local phase = 'pre'
  local block = nil

  for _, raw in ipairs(vim.split(clean_output(stdout), '\n', { plain = true })) do
    local line = raw:gsub('%s+$', '')

    if line:find('Execution Summary', 1, true) then
      break
    elseif line:find('Wrote json results to', 1, true) then
      -- Trailing CLI noise.
    elseif line == 'Pre-Request Tests' then
      phase, block = 'pre', 'pre'
    elseif line == 'Post-Response Tests' then
      phase, block = 'post', 'post'
    elseif line == 'Tests' then
      phase, block = 'tests', 'tests'
    elseif line == 'Assertions' then
      phase, block = 'other', 'assertions'
    elseif line:match('^%S+ %(.-%) %- %d+ ms$') or line:match('^%S+ %(.-%)$') then
      -- Request result line: everything after it belongs to after-response.
      phase, block = 'post', nil
    elseif line:match('^%s*[✓✕]') then
      -- Test result lines are rendered from the JSON result instead.
    elseif block and line:match('^%s+') then
      -- Error details and result lines inside a test block.
    else
      if block then
        block = nil
        if phase == 'pre' then
          phase = 'post'
        elseif phase == 'post' then
          phase = 'tests'
        elseif phase == 'tests' then
          phase = 'other'
        end
      end
      phases[phase][#phases[phase] + 1] = line
    end
  end

  for _, name in ipairs({ 'pre', 'post', 'tests', 'other' }) do
    trim_blank(phases[name])
  end
  return phases
end

---@param lines string[]
---@param output string[]
local function append_output(lines, output)
  if #output == 0 then
    lines[#lines + 1] = '(no console output)'
    return
  end
  lines[#lines + 1] = '```text'
  vim.list_extend(lines, output)
  lines[#lines + 1] = '```'
end

---@param lines string[]
---@param code? string
local function append_script_code(lines, code)
  if not present(code) then
    lines[#lines + 1] = '(none)'
    return
  end
  lines[#lines + 1] = '```javascript'
  for _, line in ipairs(vim.split(code, '\n', { plain = true })) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = '```'
end

---@param lines string[]
---@param tests? bruno.TestResult[]
local function append_script_tests(lines, tests)
  if not tests or #tests == 0 then
    return
  end
  for _, test in ipairs(tests) do
    local marker = test.status == 'pass' and '✓' or (test.status == 'skipped' and '•' or '✗')
    lines[#lines + 1] = string.format('%s %s', marker, test.description or '(unnamed test)')
    if present(test.error) then
      for _, line in ipairs(vim.split(tostring(test.error), '\n', { plain = true })) do
        lines[#lines + 1] = '    ' .. line
      end
    end
  end
end

---@param lines string[]
---@param title string
---@param code? string
---@param output string[]
---@param tests? bruno.TestResult[]
local function script_section(lines, title, code, output, tests)
  section(lines, title)

  lines[#lines + 1] = ''
  lines[#lines + 1] = '### Script'
  append_script_code(lines, code)

  lines[#lines + 1] = ''
  lines[#lines + 1] = '### Output'
  append_output(lines, output)

  if tests and #tests > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '### Tests'
    append_script_tests(lines, tests)
  end
end

---@param result? bruno.RunResult
---@param field string
---@return bruno.TestResult[]
local function collect_tests(result, field)
  local collected = {}
  for _, item in ipairs(result and result.results or {}) do
    vim.list_extend(collected, item[field] or {})
  end
  return collected
end

---@param command? string[]
---@return string
local function command_text(command)
  if type(command) ~= 'table' or #command == 0 then
    return ''
  end
  local parts = {}
  for _, argument in ipairs(command) do
    parts[#parts + 1] = tostring(argument)
  end
  return table.concat(parts, ' ')
end

---@param vars table<string, string>?
---@return string[]
local function sorted_var_names(vars)
  local names = {}
  for name in pairs(vars or {}) do
    names[#names + 1] = tostring(name)
  end
  table.sort(names)
  return names
end

---@param value any
---@return string
local function var_value_string(value)
  if value == nil or value == vim.NIL then
    return ''
  end
  if type(value) == 'table' then
    return Json.pretty(value)
  end
  return tostring(value)
end

---Evaluate the right-hand side of a `bru.setVar(...)` / `bru.setEnvVar(...)`
---against the response. Supports `res.getStatus()` and dotted
---`res.getBody().field` access, plus string/number/boolean literals.
---@param expr string
---@param response table
---@return any
local function eval_script_expression(expr, response)
  expr = vim.trim(expr)

  local str = expr:match('^"(.*)"$') or expr:match("^'(.*)'$")
  if str ~= nil then
    return str
  end
  if expr == 'true' then
    return true
  end
  if expr == 'false' then
    return false
  end
  if expr == 'null' or expr == 'undefined' then
    return nil
  end
  local num = tonumber(expr)
  if num ~= nil then
    return num
  end

  if expr:match('^res%.getStatus%(%s*%)$') then
    return response.status
  end
  if expr:match('^res%.getBody%(%s*%)$') then
    return response.data
  end

  local chain = expr:match('^res%.getBody%(%s*%)%.(.+)$')
  if chain then
    local value = response.data
    for part in chain:gmatch('[^%.]+') do
      if type(value) ~= 'table' then
        value = nil
        break
      end
      value = value[part]
    end
    return value
  end

  return nil
end

---Parse `bru.setVar("name", value)` and `bru.setEnvVar("name", value)` from a
---script and resolve the values against the response.
---@param script string?
---@param response table
---@return table<string, string>
local function extract_script_vars(script, response)
  local result = {}
  if type(script) ~= 'string' or script == '' then
    return result
  end

  for line in script:gmatch('[^\r\n]+') do
    local name, expr = line:match('bru%.set%w+%(%s*["\']([^"\']+)["\']%s*,%s*(.+)$')
    if name and expr then
      expr = expr:gsub('%s*;%s*$', ''):gsub('%s*%)%s*$', ''):gsub('^%s+', '')
      local value = eval_script_expression(expr, response)
      if value ~= nil then
        result[name] = var_value_string(value)
      end
    end
  end

  return result
end

---@param before table<string, string>?
---@param after table<string, string>?
---@return string[]
local function vars_diff_lines(before, after)
  local names = {}
  local seen = {}
  for _, name in ipairs(sorted_var_names(before)) do
    seen[name] = true
    names[#names + 1] = name
  end
  for _, name in ipairs(sorted_var_names(after)) do
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  table.sort(names)

  local lines = {}
  for _, name in ipairs(names) do
    local old_value = before and before[name]
    local new_value = after and after[name]
    if old_value == nil and new_value ~= nil then
      lines[#lines + 1] = string.format('+ %s = %s', name, var_value_string(new_value))
    elseif new_value == nil and old_value ~= nil then
      lines[#lines + 1] = string.format('- %s', name)
    elseif var_value_string(old_value) ~= var_value_string(new_value) then
      lines[#lines + 1] = string.format('- %s = %s', name, var_value_string(old_value))
      lines[#lines + 1] = string.format('+ %s = %s', name, var_value_string(new_value))
    end
  end
  if #lines == 0 then
    lines[#lines + 1] = '(no changes)'
  end
  return lines
end

---@param result? bruno.RunResult
---@param running boolean
---@param error? string
---@param command? string[]
---@return string[]
function M.verbose_tab(result, running, error, command)
  local lines = {}
  local command_string = command_text(command)

  section(lines, 'CLI OUTPUT')
  if command_string ~= '' then
    lines[#lines + 1] = 'Command:'
    lines[#lines + 1] = '```sh'
    lines[#lines + 1] = command_string
    lines[#lines + 1] = '```'
    lines[#lines + 1] = ''
  end

  if running then
    lines[#lines + 1] = 'Waiting for CLI output…'
    return lines
  end
  if error then
    lines[#lines + 1] = 'Error:'
    lines[#lines + 1] = error
    return lines
  end
  if not result then
    lines[#lines + 1] = 'Run the request to see the CLI output.'
    return lines
  end

  lines[#lines + 1] = 'Captured CLI stdout, including every lifecycle script and console output.'
  lines[#lines + 1] = ''
  local stdout = clean_output(result.stdout)
  if stdout == '' then
    lines[#lines + 1] = '(no output)'
  else
    lines[#lines + 1] = '```text'
    for _, line in ipairs(vim.split(stdout, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = '```'
  end

  local stderr = clean_output(result.stderr)
  if stderr ~= '' then
    section(lines, 'STDERR')
    lines[#lines + 1] = '```text'
    for _, line in ipairs(vim.split(stderr, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = '```'
  end

  return lines
end

---@param request bruno.Request
---@param result? bruno.RunResult
---@param running boolean
---@param error? string
---@return string[]
function M.scripts_tab(request, result, running, error)
  local lines = {}

  if running then
    return { 'Waiting for script output…' }
  end
  if error then
    section(lines, 'ERROR')
    lines[#lines + 1] = error
    return lines
  end
  if not result then
    return { 'Run the request to see the pre-request and after-response scripts.' }
  end

  local phases = parse_script_output(result.stdout)

  script_section(
    lines,
    'PRE-REQUEST SCRIPT',
    request.script and request.script.pre,
    phases.pre,
    collect_tests(result, 'preRequestTestResults')
  )

  script_section(
    lines,
    'AFTER-RESPONSE SCRIPT',
    request.script and request.script.post,
    phases.post,
    collect_tests(result, 'postResponseTestResults')
  )

  local first = result.results[1]
  local response = first and response_of(first) or {}
  local script_vars = extract_script_vars(request.script and request.script.post, response)

  local after_vars = {}
  for name, value in pairs(result.vars_after or {}) do
    after_vars[name] = value
  end
  for name, value in pairs(script_vars) do
    after_vars[name] = value
  end

  if result.vars_before ~= nil or next(after_vars) ~= nil then
    section(lines, 'ENVIRONMENT VARIABLES')
    lines[#lines + 1] = '```diff'
    vim.list_extend(lines, vars_diff_lines(result.vars_before, after_vars))
    lines[#lines + 1] = '```'
  end

  if #phases.other > 0 then
    section(lines, 'OTHER OUTPUT')
    append_output(lines, phases.other)
  end

  local stderr = clean_output(result.stderr)
  if stderr ~= '' then
    section(lines, 'STDERR')
    lines[#lines + 1] =
      'Bruno writes console.warn/console.error to stderr, which cannot be attributed to a lifecycle phase.'
    lines[#lines + 1] = ''
    lines[#lines + 1] = '```text'
    for _, line in ipairs(vim.split(stderr, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = '```'
  end

  return lines
end

---@param entries string[]
---@param path? string
---@return string[]
function M.logs_tab(entries, path)
  local lines = {}
  section(lines, 'LOGS')
  if path and path ~= '' then
    lines[#lines + 1] = '  File: ' .. path
    lines[#lines + 1] = ''
  end

  if not entries or #entries == 0 then
    lines[#lines + 1] = '  (no logs)'
    return lines
  end

  for _, entry in ipairs(entries) do
    for _, line in ipairs(vim.split(entry, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
  end
  return lines
end

---@param result? bruno.RunResult
---@param running boolean
---@param error? string
---@param opts? { view?: 'text'|'binary'|'hex'|'image', jq?: string }
---@return string[]
function M.response_tab(result, running, error, opts)
  local lines = {}
  opts = opts or {}

  if running then
    return { 'Waiting for the response…' }
  end
  if error then
    section(lines, 'ERROR')
    lines[#lines + 1] = error
    return lines
  end
  if not result then
    return { 'Run the request to see the response.' }
  end

  local first = result.results[1]
  if not first then
    return { 'The Bruno CLI did not return any result.' }
  end

  local body_util = require('bruno.ui.body')
  local response = response_of(first) or {}
  local status = present(response.status) and response.status or '—'
  local status_text = present(response.statusText) and tostring(response.statusText) or ''
  local status_line = tostring(status) .. (status_text ~= '' and (' ' .. status_text) or '')
  local body = body_util.text(response)

  local jq_error
  if opts.jq and opts.jq ~= '' and body ~= '' then
    local filtered, err = body_util.jq(body, opts.jq)
    if filtered then
      body = filtered
    else
      jq_error = err
    end
  end

  section(lines, #result.results > 1 and ('RESPONSE (1 of ' .. #result.results .. ')') or 'RESPONSE')
  kv(lines, 'Status', status_line)
  kv(lines, 'Time', M.ms(response.responseTime or response.duration))
  kv(lines, 'Size', M.bytes(response.size or #body))
  kv(lines, 'URL', response.url or (request_of(first) or {}).url)

  section(lines, 'HEADERS')
  header_lines(lines, response.headers)

  if present(first.error) then
    section(lines, 'ERROR')
    lines[#lines + 1] = tostring(first.error)
  end

  if jq_error then
    section(lines, 'JQ ERROR')
    lines[#lines + 1] = jq_error
  end

  section(lines, 'BODY')
  local view = opts.view or 'text'
  if opts.jq and opts.jq ~= '' then
    lines[#lines + 1] = 'jq: ' .. opts.jq
    lines[#lines + 1] = ''
  end
  if body == '' then
    lines[#lines + 1] = '  (empty)'
  elseif view == 'image' then
    -- The image is drawn over the body area by image.nvim; no placeholder text.
  elseif view == 'hex' then
    lines[#lines + 1] = '```text'
    vim.list_extend(lines, body_util.hex_lines(body))
    lines[#lines + 1] = '```'
  elseif view == 'binary' then
    lines[#lines + 1] = '```text'
    vim.list_extend(lines, body_util.binary_lines(body))
    lines[#lines + 1] = '```'
  else
    local language = body_language(response, body)
    lines[#lines + 1] = '```' .. language
    for _, line in ipairs(vim.split(body, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = '```'
  end

  return lines
end

---@param assertions? bruno.AssertionResult[]
---@param lines string[]
local function assertion_lines(assertions, lines)
  for _, assertion in ipairs(assertions or {}) do
    local marker = assertion.status == 'pass' and '✓' or (assertion.status == 'skipped' and '•' or '✗')
    local label = assertion.lhsExpr or assertion.error or '(assertion)'
    lines[#lines + 1] = string.format('  %s %s', marker, label)
    if present(assertion.error) and assertion.error ~= label then
      for _, line in ipairs(vim.split(tostring(assertion.error), '\n', { plain = true })) do
        lines[#lines + 1] = '      ' .. line
      end
    end
  end
end

---@param request bruno.Request
---@param result? bruno.RunResult
---@param running boolean
---@param error? string
---@return string[]
function M.tests_tab(request, result, running, error)
  local lines = {}

  if running then
    return { 'Waiting for test results…' }
  end
  if error then
    section(lines, 'ERROR')
    lines[#lines + 1] = error
    return lines
  end
  if not result or #result.results == 0 then
    return { 'No test results yet.' }
  end

  local phases = parse_script_output(result.stdout)
  script_section(lines, 'TESTS', request and request.tests, phases.tests, collect_tests(result, 'testResults'))

  for index, item in ipairs(result.results) do
    local name = item.name
    if name == nil or name == vim.NIL or name == '' then
      name = item.path
    end
    if name == nil or name == vim.NIL or name == '' then
      name = item.filename
    end
    if name == nil or name == vim.NIL or name == '' then
      name = 'request ' .. index
    end

    local assertions = item.assertionResults or {}
    if present(item.error) or #assertions > 0 then
      if #lines > 0 then
        lines[#lines + 1] = ''
      end
      section(lines, 'RESULT ' .. index .. ': ' .. name)
      if present(item.error) then
        kv(lines, 'Runner', tostring(item.error))
      end
      if #assertions > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = '  ASSERTIONS'
        assertion_lines(assertions, lines)
      end
    end
  end

  return lines
end

---@param result? bruno.RunResult
---@param running boolean
---@param error? string
---@param opts? { jq?: string }
---@return string[]
function M.raw_tab(result, running, error, opts)
  opts = opts or {}
  if running then
    return { 'Waiting for raw output…' }
  end
  if error then
    return vim.split(error, '\n', { plain = true })
  end
  if not result then
    return { 'Run the request to see the raw Bruno CLI output.' }
  end

  local lines = {}
  if opts.jq and opts.jq ~= '' then
    lines[#lines + 1] = 'jq: ' .. opts.jq
    lines[#lines + 1] = ''
  end

  if result.raw == '' then
    lines[#lines + 1] = '(empty raw output)'
    return lines
  end

  local raw = result.raw
  if opts.jq and opts.jq ~= '' then
    local filtered, err = require('bruno.ui.body').jq(raw, opts.jq)
    if filtered then
      raw = filtered
    else
      lines[#lines + 1] = 'jq error: ' .. tostring(err)
      lines[#lines + 1] = ''
    end
  end

  local decoded = Json.decode(raw)
  local language = decoded == nil and 'text' or 'json'
  lines[#lines + 1] = '```' .. language
  vim.list_extend(lines, vim.split(Json.pretty_string(raw), '\n', { plain = true }))
  lines[#lines + 1] = '```'
  return lines
end

return M
