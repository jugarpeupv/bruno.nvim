local env = require('bruno.env')
local parsers = require('bruno.parsers')
local state = require('bruno.state')
local log = require('bruno.utils.log')

local fixtures = vim.fn.getcwd() .. '/tests/fixtures'
local bru_root = fixtures .. '/bru-collection'
local yml_root = fixtures .. '/yml-collection'

describe('environment selection', function()
  it('auto-selects the only environment', function()
    require('bruno').setup({ notify = false, default_env = nil })
    state.reset()
    env.reset()
    eq('Local', env.ensure(bru_root))
    eq('Local', state.get_env(bru_root))
    eq(false, state.is_env_configured(bru_root))
  end)

  it('does not auto-select when the user explicitly chose the default', function()
    require('bruno').setup({ notify = false, default_env = nil })
    state.reset()
    env.reset()
    env.clear(bru_root)
    eq(true, state.is_env_configured(bru_root))
    eq(nil, env.ensure(bru_root))
  end)

  it('honours default_env', function()
    require('bruno').setup({ notify = false, default_env = 'Local' })
    state.reset()
    env.reset()
    eq('Local', env.ensure(yml_root))
    eq('Local', state.get_env(yml_root))
  end)

  it('keeps an explicit selection', function()
    require('bruno').setup({ notify = false, default_env = nil })
    state.reset()
    env.reset()
    env.set(bru_root, 'Local')
    eq('Local', env.ensure(bru_root))
    eq(true, state.is_env_configured(bru_root))
  end)

  it('logs the auto-selected environment only once', function()
    require('bruno').setup({ notify = false, default_env = nil })
    state.reset()
    env.reset()
    log.clear()

    local function occurrences()
      local count = 0
      for _, entry in ipairs(log.entries()) do
        if entry:find('auto-selected environment "Local"', 1, true) then
          count = count + 1
        end
      end
      return count
    end

    eq('Local', env.ensure(bru_root))
    eq(1, occurrences())

    env.ensure(bru_root)
    eq(1, occurrences())
  end)
end)

describe('environment API', function()
  it('exposes the selected environment and collection', function()
    require('bruno').setup({ notify = false, default_env = nil })
    state.reset()
    env.reset()
    state.last_request = parsers.parse_request(bru_root .. '/requests/simple.bru')

    local bruno = require('bruno')
    eq('Local', bruno.current_environment())
    eq('Local', bruno.get_env())
    eq('fixture-bru', bruno.current_collection().name)
    eq('Local', bruno.status().environment)
    eq('fixture-bru', bruno.status().collection)
  end)
end)
