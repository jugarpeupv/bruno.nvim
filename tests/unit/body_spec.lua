local body = require('bruno.ui.body')

describe('ui.body', function()
  it('detects JSON and image responses', function()
    truthy(body.is_json({ data = { a = 1 }, headers = {} }))
    truthy(body.is_json({ data = '{"a":1}', headers = {} }))
    truthy(body.is_json({ data = '{}', headers = { ['content-type'] = 'application/json' } }))
    falsy(body.is_json({ data = 'plain', headers = { ['content-type'] = 'text/plain' } }))

    truthy(body.is_image({ headers = { ['content-type'] = 'image/png' } }))
    falsy(body.is_image({ headers = { ['content-type'] = 'application/json' } }))
  end)

  it('renders hex and binary views', function()
    local hex = body.hex_lines('AB')
    eq(1, #hex)
    match(hex[1], '^00000000  41 42')
    match(hex[1], '|AB|')

    local binary = body.binary_lines('A')
    eq(1, #binary)
    eq('01000001', binary[1])

    -- Large bodies must not hit Lua's maximum number of return values.
    local large = body.binary_lines(string.rep('\255', 5000))
    truthy(#large > 0)
    eq(64, #large[1])
  end)

  it('filters JSON with jq', function()
    if vim.fn.executable('jq') ~= 1 then
      return
    end

    local filtered, err = body.jq('{"a":1,"b":2}', '.a')
    eq(nil, err)
    eq('1', filtered)

    local invalid, invalid_err = body.jq('{"a":1}', '.a |')
    eq(nil, invalid)
    truthy(invalid_err ~= '')

    local same, same_err = body.jq('', '.a')
    eq('', same)
    eq(nil, same_err)
  end)
end)
