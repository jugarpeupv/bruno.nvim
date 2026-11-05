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

---@param value any
---@return string
local function body_to_string(value)
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

---@param request bruno.Request
---@param env? string
---@param running boolean
---@param error? string
---@return string[]
function M.request_tab(request, env, running, error)
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
  local headers = key_value_lines(request.headers, ': ')
  for _, line in ipairs(headers) do
    lines[#lines + 1] = line
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
    raw_block(lines, content)
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

  if request.script and (request.script.pre or request.script.post) then
    if request.script.pre then
      section(lines, 'PRE-REQUEST SCRIPT')
      raw_block(lines, request.script.pre)
    end
    if request.script.post then
      section(lines, 'POST-RESPONSE SCRIPT')
      raw_block(lines, request.script.post)
    end
  end

  if request.tests then
    section(lines, 'TESTS')
    raw_block(lines, request.tests)
  end

  if request.docs then
    section(lines, 'DOCS')
    raw_block(lines, request.docs)
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

  script_section(lines, 'TESTS', request.tests, phases.tests, collect_tests(result, 'testResults'))

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
---@return string[]
function M.body_tab(result, running, error)
  local lines = {}

  if running then
    return { 'Waiting for the response…' }
  end
  if error then
    section(lines, 'ERROR')
    lines[#lines + 1] = error
    return lines
  end
  if not result then
    return { 'Run the request to see the response body.' }
  end

  local first = result.results[1]
  if not first then
    return { 'The Bruno CLI did not return any result.' }
  end

  local response = response_of(first) or {}
  local status = present(response.status) and response.status or '—'
  local status_text = present(response.statusText) and tostring(response.statusText) or ''
  local status_line = tostring(status) .. (status_text ~= '' and (' ' .. status_text) or '')
  local body = body_to_string(response.data)

  section(lines, #result.results > 1 and ('RESPONSE (1 of ' .. #result.results .. ')') or 'RESPONSE')
  kv(lines, 'Status', status_line)
  kv(lines, 'Time', M.ms(response.responseTime or response.duration))
  kv(lines, 'Size', M.bytes(response.size or #body))
  kv(lines, 'URL', response.url or (request_of(first) or {}).url)

  if present(first.error) then
    section(lines, 'ERROR')
    lines[#lines + 1] = tostring(first.error)
  end

  section(lines, 'BODY')
  if body == '' then
    lines[#lines + 1] = '  (empty)'
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

---@param result? bruno.RunResult
---@param request bruno.Request
---@return string[]
function M.headers_tab(result, request)
  local lines = {}
  local first = result and result.results[1]
  local req = request_of(first)
  local res = response_of(first)

  section(lines, 'REQUEST HEADERS')
  local request_headers = req and sorted_headers(req.headers) or {}
  if #request_headers == 0 then
    for _, entry in ipairs(request.headers or {}) do
      if entry.enabled then
        request_headers[#request_headers + 1] = { name = entry.name, value = entry.value }
      end
    end
  end
  if #request_headers == 0 then
    lines[#lines + 1] = '  (none)'
  else
    for _, header in ipairs(request_headers) do
      lines[#lines + 1] = '  ' .. header.name .. ': ' .. header.value
    end
  end

  section(lines, 'RESPONSE HEADERS')
  local response_headers = res and sorted_headers(res.headers) or {}
  if #response_headers == 0 then
    lines[#lines + 1] = '  (none)'
  else
    for _, header in ipairs(response_headers) do
      lines[#lines + 1] = '  ' .. header.name .. ': ' .. header.value
    end
  end

  return lines
end

---@param tests? bruno.TestResult[]
---@param lines string[]
local function test_lines(tests, lines)
  for _, test in ipairs(tests or {}) do
    local marker = test.status == 'pass' and '✓' or (test.status == 'skipped' and '•' or '✗')
    lines[#lines + 1] = string.format('  %s %s', marker, test.description or '(unnamed test)')
    if present(test.error) then
      for _, line in ipairs(vim.split(tostring(test.error), '\n', { plain = true })) do
        lines[#lines + 1] = '      ' .. line
      end
    end
  end
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

---@param result? bruno.RunResult
---@param running boolean
---@param error? string
---@return string[]
function M.tests_tab(result, running, error)
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

  for index, item in ipairs(result.results) do
    if index > 1 then
      lines[#lines + 1] = ''
    end
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
    section(lines, 'RESULT ' .. index .. ': ' .. name)
    kv(lines, 'Status', item.status or '—')
    kv(lines, 'Runner', present(item.error) and item.error or '(no runner error)')

    local tests = {}
    vim.list_extend(tests, item.testResults or {})
    vim.list_extend(tests, item.preRequestTestResults or {})
    vim.list_extend(tests, item.postResponseTestResults or {})
    if #tests > 0 then
      lines[#lines + 1] = ''
      lines[#lines + 1] = '  TESTS'
      test_lines(tests, lines)
    end

    if #(item.assertionResults or {}) > 0 then
      lines[#lines + 1] = ''
      lines[#lines + 1] = '  ASSERTIONS'
      assertion_lines(item.assertionResults, lines)
    end

    if #tests == 0 and #(item.assertionResults or {}) == 0 then
      lines[#lines + 1] = '  (no tests or assertions)'
    end
  end

  return lines
end

---@param result? bruno.RunResult
---@param running boolean
---@param error? string
---@return string[]
function M.timeline_tab(result, running, error)
  local lines = {}

  if running then
    return { 'Request in progress…' }
  end
  if error then
    section(lines, 'ERROR')
    lines[#lines + 1] = error
    return lines
  end
  if not result then
    return { 'Run the request to see timing information.' }
  end

  for index, item in ipairs(result.results) do
    if index > 1 then
      lines[#lines + 1] = ''
    end
    local req = request_of(item) or {}
    local res = response_of(item) or {}
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
    local status_text = present(res.statusText) and (' ' .. tostring(res.statusText)) or ''

    section(lines, 'REQUEST ' .. index .. ': ' .. name)
    kv(lines, 'Method', req.method)
    kv(lines, 'URL', req.url)
    kv(lines, 'Status', tostring(present(res.status) and res.status or '—') .. status_text)
    kv(lines, 'Response', M.ms(res.responseTime or res.duration))
    kv(lines, 'Run', M.ms(item.runDuration and item.runDuration * 1000))
    kv(lines, 'Size', M.bytes(res.size))
    kv(lines, 'Tests', string.format('%d', #(item.testResults or {})))
    kv(lines, 'Assertions', string.format('%d', #(item.assertionResults or {})))
  end

  if result.summary then
    local summary = result.summary or {}
    section(lines, 'SUMMARY')
    kv(lines, 'Requests', summary.totalRequests or '—')
    kv(lines, 'Passed', summary.passedRequests or '—')
    kv(lines, 'Failed', summary.failedRequests or '—')
    kv(lines, 'Skipped', summary.skippedRequests or '—')
    kv(lines, 'Tests', string.format('%s/%s', summary.passedTests or 0, summary.totalTests or 0))
    kv(lines, 'Assertions', string.format('%s/%s', summary.passedAssertions or 0, summary.totalAssertions or 0))
  end

  return lines
end

---@param result? bruno.RunResult
---@param running boolean
---@param error? string
---@return string[]
function M.raw_tab(result, running, error)
  if running then
    return { 'Waiting for raw output…' }
  end
  if error then
    return vim.split(error, '\n', { plain = true })
  end
  if not result then
    return { 'Run the request to see the raw Bruno CLI output.' }
  end
  if result.raw == '' then
    return { '(empty raw output)' }
  end

  local decoded = Json.decode(result.raw)
  local language = decoded == nil and 'text' or 'json'
  local lines = { '```' .. language }
  vim.list_extend(lines, vim.split(Json.pretty_string(result.raw), '\n', { plain = true }))
  lines[#lines + 1] = '```'
  return lines
end

return M
