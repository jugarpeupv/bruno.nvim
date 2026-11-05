local url = require('bruno.utils.url')

describe('utils.url', function()
  it('parses a complete URL', function()
    local parsed = url.parse('https://user:pass@example.com:8443/api/v1?x=1&x=2#frag')
    eq('https', parsed.scheme)
    eq('example.com', parsed.host)
    eq(8443, parsed.port)
    eq('/api/v1', parsed.path)
    eq('x=1&x=2', parsed.query)
    eq('frag', parsed.fragment)
    eq('user:pass', parsed.userinfo)
  end)

  it('builds a URL back to its original form', function()
    local raw = 'https://example.com:8443/api/v1?x=1#frag'
    eq(raw, url.build(url.parse(raw)))
  end)

  it('parses query parameters with duplicates', function()
    local query = url.parse_query('x=1&x=2&empty=&flag')
    eq({ '1', '2' }, query.x)
    eq({ '' }, query.empty)
    eq({ '' }, query.flag)
  end)

  it('appends query parameters before the fragment', function()
    eq('https://example.com/a?x=1&y=2#f', url.append_query('https://example.com/a?x=1#f', 'y', '2'))
  end)

  it('encodes form values with plus for spaces', function()
    eq('hello+world%21', url.form_encode('hello world!'))
  end)

  it('encodes reserved characters in query components', function()
    eq('http%3A%2F%2Fexample.com%2Fcallback%3Fx%3D1', url.component('http://example.com/callback?x=1'))
  end)

  it('encodes ordered pairs', function()
    eq('a=1&b=hello+world', url.encode_pairs({ { 'a', '1' }, { 'b', 'hello world' } }))
  end)
end)
