local parsers = require('bruno.parsers')
local runner = require('bruno.runner')

local root = vim.fn.getcwd() .. '/tests/fixtures'

describe('runner.normalize_output', function()
  it('accepts the legacy object shape', function()
    local results, summary = runner.normalize_output({
      results = { { status = 'pass' } },
      summary = { totalRequests = 1 },
    })
    eq(1, #results)
    eq(1, summary.totalRequests)
  end)

  it('accepts the CLI iteration array shape', function()
    local results, summary = runner.normalize_output({
      { results = { { status = 'pass' }, { status = 'fail' } }, summary = { totalRequests = 2 } },
      { results = { { status = 'pass' } }, summary = { totalRequests = 1 } },
    })
    eq(3, #results)
    eq(2, summary.totalRequests)
  end)

  it('returns empty results for empty output', function()
    local results = runner.normalize_output({})
    eq(0, #results)
  end)
end)

describe('runner.summary_message', function()
  it('uses the CLI summary when available', function()
    eq(
      'Bruno: 2 request(s), 1 passed, 1 failed',
      runner.summary_message({}, { totalRequests = 2, passedRequests = 1, failedRequests = 1 })
    )
  end)

  it('falls back to counting result statuses', function()
    eq('Bruno: 2 request(s), 1 passed', runner.summary_message({ { status = 'pass' }, { status = 'fail' } }))
  end)
end)

describe('runner.build_command', function()
  it('constructs a bru run command', function()
    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local command = runner.build_command(request, 'Local', { '--insecure' })
    eq('bru', command[1])
    eq('run', command[2])
    eq('requests/simple.bru', command[3])
    eq('--env', command[8])
    eq('Local', command[9])
    eq('--insecure', command[#command])
  end)
end)

describe('runner.run', function()
  it('forwards the resolved environment to bru run', function()
    require('bruno').setup({ notify = false, default_env = nil, ui = { auto_open = false } })
    require('bruno.state').reset()
    require('bruno.env').reset()

    local request = parsers.parse_request(root .. '/bru-collection/requests/simple.bru')
    local original_system = vim.system
    local original_executable = vim.fn.executable
    local captured
    local done = false
    local run_error

    vim.fn.executable = function()
      return 1
    end
    vim.system = function(command, _, callback)
      captured = command
      vim.fn.writefile({ '[]' }, command[5])
      vim.schedule(function()
        callback({ code = 0, signal = 0, stdout = '', stderr = '' })
      end)
      return {
        kill = function() end,
      }
    end

    local ok, err = pcall(function()
      runner.run(request, {
        silent = true,
        on_done = function(_, failure)
          run_error = failure
          done = true
        end,
      })
      vim.wait(3000, function()
        return done
      end)
    end)

    vim.system = original_system
    vim.fn.executable = original_executable

    if not ok then
      error(err, 0)
    end

    truthy(done, 'runner did not finish')
    eq(nil, run_error)

    local environment_index
    for index, argument in ipairs(captured or {}) do
      if argument == '--env' then
        environment_index = index
        break
      end
    end
    truthy(environment_index, 'bru run did not receive --env')
    eq('Local', captured[environment_index + 1])
    eq('Local', require('bruno.state').last_result.env)
    eq(captured, require('bruno.state').last_result.command)
  end)
end)
