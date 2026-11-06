local parsers = require('bruno.parsers')

local root = vim.fn.getcwd() .. '/tests/fixtures'

describe('ui.workbench', function()
  it('renders request tabs and response tabs', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = false },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()
    local ui = require('bruno.ui')
    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local bufnr = ui.open({ request = request })
    truthy(bufnr)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[1], '%[Request%]')
    match(lines[2], 'POST')
    match(lines[2], 'http://127%.0%.0%.1:8765/users')
    match(lines[3], '^Request: %d+/%d+ · Selected env: Local')
    match(lines[5], '^## REQUEST')
    eq('', vim.wo[ui.win].winbar)

    local env_mod = require('bruno.env')
    env_mod.clear(request.root)
    ui.render(bufnr)
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[3], '^Request: %d+/%d+ · Selected env: none')
    env_mod.set(request.root, 'Local')
    ui.render(bufnr)
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[3], '^Request: %d+/%d+ · Selected env: Local')

    ui.select_tab('body')
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(table.concat(lines, '\n'), 'Run the request to see the response body')

    local result = {
      request = request,
      raw = '{"results":[]}',
      data = {},
      results = {
        {
          name = 'Simple Request',
          status = 'pass',
          request = {
            method = 'POST',
            url = 'http://127.0.0.1:8765/users',
            headers = { ['Content-Type'] = 'application/json' },
          },
          response = {
            status = 200,
            statusText = 'OK',
            headers = { ['content-type'] = 'application/json' },
            data = { ok = true },
            responseTime = 12,
            size = 11,
          },
          testResults = { { description = 'ok', status = 'pass' } },
          assertionResults = {},
        },
      },
      summary = {
        totalRequests = 1,
        passedRequests = 1,
        failedRequests = 0,
        totalTests = 1,
        passedTests = 1,
        totalAssertions = 0,
        passedAssertions = 0,
      },
      stdout = '',
      stderr = '',
      code = 0,
      env = 'Local',
    }

    ui.show_result(result)
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[2], '200 OK')
    local rendered = table.concat(lines, '\n')
    match(rendered, '"ok": true')
    match(rendered, '```json')

    ui.select_tab('tests')
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(table.concat(lines, '\n'), '✓ ok')

    ui.select_tab('headers')
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(table.concat(lines, '\n'), 'Content%-Type')

    ui.select_tab('timeline')
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(table.concat(lines, '\n'), 'SUMMARY')

    ui.select_tab('raw')
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local raw_lines = table.concat(lines, '\n')
    match(raw_lines, '```json')
    match(raw_lines, 'results')
    eq('bruno_ui', vim.bo[bufnr].filetype)
    eq('markdown', vim.bo[bufnr].syntax)

    local next_buf = ui.buf
    ui.next_tab(1)
    truthy(ui.buf == next_buf)
    eq('bruno_ui', vim.bo[bufnr].filetype)
    eq('markdown', vim.bo[bufnr].syntax)

    require('bruno.state').set_request(request)
    vim.cmd('wincmd p')
    truthy(vim.api.nvim_get_current_win() ~= ui.win)
    ui.toggle()
    eq(ui.win, vim.api.nvim_get_current_win())
    ui.toggle()
    falsy(ui.win)
    ui.toggle()
    truthy(ui.win)
    eq(ui.win, vim.api.nvim_get_current_win())

    local final_buf = ui.buf
    ui.destroy()
    eq(false, vim.api.nvim_buf_is_valid(final_buf))
  end)

  it('highlights response values consistently with the title bar', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = false },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()

    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local ui = require('bruno.ui')
    local bufnr = ui.open({ request = request })
    truthy(bufnr)

    local result = {
      request = request,
      raw = '{"results":[]}',
      data = {},
      results = {
        {
          name = 'Simple Request',
          status = 'pass',
          request = { method = 'POST', url = 'http://127.0.0.1:8765/users', headers = {} },
          response = {
            status = 200,
            statusText = 'OK',
            headers = { ['content-type'] = 'application/json' },
            data = { ok = true },
            responseTime = 12,
            size = 11,
            url = 'http://127.0.0.1:8765/users',
          },
          testResults = {},
          assertionResults = {},
        },
      },
      summary = {},
      stdout = '',
      stderr = '',
      code = 0,
      env = 'Local',
    }

    ui.show_result(result)
    ui.select_tab('body')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local namespace = vim.api.nvim_get_namespaces()['bruno-ui']

    local function row_starting(prefix)
      for index, line in ipairs(lines) do
        if line:find(prefix, 1, true) == 1 or line:find('  ' .. prefix, 1, true) then
          return index - 1
        end
      end
      error('missing line: ' .. prefix)
    end

    local function hl_at(row, text)
      local line = lines[row + 1]
      local col = assert(line:find(text, 1, true)) - 1
      for _, mark in
        ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, { row, 0 }, { row, -1 }, { details = true }))
      do
        local details = mark[4]
        if col >= mark[3] and col < details.end_col then
          return details.hl_group
        end
      end
    end

    local status_row = row_starting('Status:')
    eq('BrunoOk', hl_at(status_row, '200 OK'))

    local time_row = row_starting('Time:')
    eq('BrunoOk', hl_at(time_row, '12 ms'))

    local size_row = row_starting('Size:')
    eq('BrunoOk', hl_at(size_row, '11 B'))

    local url_row = row_starting('URL:')
    eq('BrunoUrl', hl_at(url_row, 'http://127.0.0.1:8765/users'))

    ui.select_tab('timeline')
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local method_row = row_starting('Method:')
    eq('BrunoMethod', hl_at(method_row, 'POST'))
    local timeline_url_row = row_starting('URL:')
    eq('BrunoUrl', hl_at(timeline_url_row, 'http://127.0.0.1:8765/users'))

    ui.destroy()
  end)

  it('opens the tab under the cursor with <CR>', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = false },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()

    local parsers = require('bruno.parsers')
    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local ui = require('bruno.ui')
    local bufnr = ui.open({ request = request })
    truthy(bufnr)

    local mapping = vim.fn.maparg('<CR>', 'n', false, true)
    truthy(mapping.callback, '<CR> mapping is missing')

    local tabline = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    local body_col = assert(tabline:find('Body', 1, true)) - 1
    vim.api.nvim_win_set_cursor(ui.win, { 1, body_col })
    mapping.callback()
    eq('body', ui.state(bufnr).tab)

    local request_col = assert(tabline:find('Request', 1, true)) - 1
    vim.api.nvim_win_set_cursor(ui.win, { 1, request_col })
    mapping.callback()
    eq('request', ui.state(bufnr).tab)

    truthy(vim.fn.maparg('ge', 'n', false, true).callback, 'ge environment mapping is missing')

    ui.destroy()
  end)

  it('keeps an execution history and navigates it with ( and )', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = false },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()

    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local ui = require('bruno.ui')
    local bufnr = ui.open({ request = request })
    truthy(bufnr)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[3], 'Request: 1/1')

    local function result(status, body)
      return {
        request = request,
        raw = '{}',
        data = {},
        results = {
          {
            name = 'Simple Request',
            status = 'pass',
            request = { method = 'POST', url = 'http://127.0.0.1:8765/users', headers = {} },
            response = {
              status = status,
              statusText = 'OK',
              headers = { ['content-type'] = 'application/json' },
              data = { run = body },
              responseTime = 10,
              size = 10,
              url = 'http://127.0.0.1:8765/users',
            },
            testResults = {},
            assertionResults = {},
          },
        },
        summary = {},
        stdout = '',
        stderr = '',
        code = 0,
        env = 'Local',
      }
    end

    ui.show_result(result(200, 1))
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[3], 'Request: 2/2')

    ui.show_result(result(201, 2))
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[3], 'Request: 3/3')
    ui.select_tab('body')
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(table.concat(lines, '\n'), '"run": 2')

    ui.prev_response()
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[3], 'Request: 2/3')
    match(table.concat(lines, '\n'), '200 OK')
    match(table.concat(lines, '\n'), '"run": 1')

    ui.prev_response()
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[3], 'Request: 1/3')
    match(lines[2], 'not run yet')

    ui.next_response()
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    match(lines[3], 'Request: 2/3')

    ui.destroy()
  end)

  it('groups lifecycle script output in Scripts and raw output in Verbose', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = false },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()

    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local ui = require('bruno.ui')
    local bufnr = ui.open({ request = request })
    truthy(bufnr)

    local stdout = table.concat({
      'PRE-CONSOLE-LOG',
      'PRE-CONSOLE-INFO',
      'requests/hello (200 OK) - 12 ms',
      'Pre-Request Tests',
      '   ✓ pre passes',
      'POST-CONSOLE-LOG',
      'Post-Response Tests',
      '   ✕ post passes',
      '      expected 200 to equal 201',
      'TEST-CONSOLE-LOG',
      'Tests',
      '   ✓ tests pass',
      '',
      '📊 Execution Summary',
      '│ Requests │ 1 │',
      'Wrote json results to /tmp/out.json',
    }, '\n')

    local result = {
      request = request,
      raw = '{}',
      data = {},
      results = {
        {
          name = 'Simple Request',
          status = 'pass',
          request = { method = 'POST', url = 'http://127.0.0.1:8765/users', headers = {} },
          response = {
            status = 200,
            statusText = 'OK',
            headers = {},
            data = {},
            responseTime = 12,
            size = 2,
          },
          preRequestTestResults = { { description = 'pre passes', status = 'pass' } },
          postResponseTestResults = {
            { description = 'post passes', status = 'fail', error = 'expected 200 to equal 201' },
          },
          testResults = { { description = 'tests pass', status = 'pass' } },
          assertionResults = {},
        },
      },
      summary = {},
      stdout = stdout,
      stderr = 'POST-CONSOLE-WARN',
      code = 0,
      env = 'Local',
      command = { 'bru', 'run', 'requests/simple.bru', '--env', 'Local' },
    }

    require('bruno.state').env_before = { baseUrl = 'http://127.0.0.1:8765', token = 'old' }
    ui.show_result(result)
    ui.select_tab('scripts')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local text = table.concat(lines, '\n')
    match(text, '## PRE%-REQUEST SCRIPT')
    match(text, 'PRE%-CONSOLE%-LOG')
    match(text, 'PRE%-CONSOLE%-INFO')
    match(text, 'pre passes')
    match(text, '## AFTER%-RESPONSE SCRIPT')
    match(text, 'POST%-CONSOLE%-LOG')
    match(text, 'post passes')
    match(text, '## TESTS')
    match(text, 'TEST%-CONSOLE%-LOG')
    match(text, 'tests pass')
    match(text, '## STDERR')
    match(text, 'POST%-CONSOLE%-WARN')

    match(text, '## ENVIRONMENT VARIABLES')
    match(text, '```diff')
    match(text, '%- token = old')
    match(text, '%+ token = env%-token')
    match(text, '%+ apiKey')

    ui.select_tab('verbose')
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    text = table.concat(lines, '\n')
    match(text, '## CLI OUTPUT')
    match(text, 'Command:')
    match(text, 'bru run requests/simple%.bru %-%-env Local')
    match(text, 'PRE%-CONSOLE%-LOG')
    match(text, 'POST%-CONSOLE%-LOG')
    match(text, 'TEST%-CONSOLE%-LOG')
    match(text, 'Execution Summary')

    ui.destroy()
  end)

  it('counts an auto-opened first run as 1/1', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = true },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()
    require('bruno.history').reset()

    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local ui = require('bruno.ui')

    ui.before_run(request)
    local lines = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
    match(lines[3], '^Selected env: Local')

    ui.show_result({
      request = request,
      raw = '{}',
      data = {},
      results = {
        {
          name = 'Simple Request',
          status = 'pass',
          request = { method = 'POST', url = 'http://127.0.0.1:8765/users', headers = {} },
          response = {
            status = 200,
            statusText = 'OK',
            headers = {},
            data = {},
            responseTime = 1,
            size = 2,
          },
          testResults = {},
          assertionResults = {},
        },
      },
      summary = {},
      stdout = '',
      stderr = '',
      code = 0,
      env = 'Local',
    })

    lines = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
    match(lines[3], '^Request: 1/1 · Selected env: Local')

    ui.destroy()
  end)

  it('lands on the configured default_tab when auto-opened for the first run', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = true, default_tab = 'headers' },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()

    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local ui = require('bruno.ui')

    ui.before_run(request)
    local bufnr = ui.buf
    truthy(bufnr)
    eq('headers', ui.state(bufnr).tab)

    ui.show_result({
      request = request,
      raw = '{}',
      data = {},
      results = {
        {
          name = 'Simple Request',
          status = 'pass',
          request = { method = 'POST', url = 'http://127.0.0.1:8765/users', headers = {} },
          response = {
            status = 200,
            statusText = 'OK',
            headers = {},
            data = {},
            responseTime = 1,
            size = 2,
          },
          testResults = {},
          assertionResults = {},
        },
      },
      summary = {},
      stdout = '',
      stderr = '',
      code = 0,
      env = 'Local',
    })

    eq('headers', ui.state(bufnr).tab)

    ui.destroy()
  end)

  it('keeps the current tab when re-running', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = false },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()

    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local ui = require('bruno.ui')
    local bufnr = ui.open({ request = request })
    truthy(bufnr)

    ui.select_tab('headers')
    eq('headers', ui.state(bufnr).tab)

    ui.before_run(request)
    eq('headers', ui.state(bufnr).tab)

    ui.show_result({
      request = request,
      raw = '{}',
      data = {},
      results = {
        {
          name = 'Simple Request',
          status = 'pass',
          request = { method = 'POST', url = 'http://127.0.0.1:8765/users', headers = {} },
          response = {
            status = 200,
            statusText = 'OK',
            headers = {},
            data = {},
            responseTime = 1,
            size = 2,
          },
          testResults = {},
          assertionResults = {},
        },
      },
      summary = {},
      stdout = '',
      stderr = '',
      code = 0,
      env = 'Local',
    })

    eq('headers', ui.state(bufnr).tab)

    ui.destroy()
  end)

  it('folds Markdown section headings', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = false },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()

    local parsers = require('bruno.parsers')
    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local ui = require('bruno.ui')
    local bufnr = ui.open({ request = request })
    eq('bruno_ui', vim.bo[bufnr].filetype)
    eq('markdown', vim.treesitter.language.get_lang('bruno_ui'))

    if not pcall(vim.treesitter.language.add, 'markdown') then
      ui.destroy()
      return
    end

    vim.api.nvim_win_set_cursor(ui.win, { 5, 0 })
    vim.cmd('normal! za')
    eq(5, vim.fn.foldclosed(5))
    vim.cmd('normal! za')
    eq(-1, vim.fn.foldclosed(5))
    ui.destroy()
  end)

  it('inspects variables and focuses the hover window', function()
    require('bruno').setup({
      notify = false,
      default_env = nil,
      ui = { auto_open = false },
    })
    require('bruno.state').reset()
    require('bruno.env').reset()

    local ui = require('bruno.ui')
    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local bufnr = ui.open({ request = request })
    truthy(bufnr)

    local target_line
    local target_col
    for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      local start_col = line:find('{{baseUrl}}', 1, true)
      if start_col then
        target_line = index
        target_col = start_col - 1
        break
      end
    end
    truthy(target_line, 'could not find {{baseUrl}} in the workbench')
    vim.api.nvim_win_set_cursor(ui.win, { target_line, target_col })

    local hover = require('bruno.ui.hover')
    local hover_win = hover.show(request)
    truthy(hover_win)
    eq(ui.win, vim.api.nvim_get_current_win())

    local hover_buf = vim.api.nvim_win_get_buf(hover_win)
    local hover_text = table.concat(vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false), '\n')
    match(hover_text, '{{baseUrl}}')
    match(hover_text, 'Environment: Local')
    match(hover_text, 'http://127%.0%.0%.1:8765')

    hover.show(request)
    eq(hover_win, vim.api.nvim_get_current_win())
    hover.close()
    falsy(hover.is_open())

    vim.api.nvim_set_current_win(ui.win)
    ui.destroy()
  end)
end)
