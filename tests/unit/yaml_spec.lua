local yaml = require('bruno.parsers.yaml')

describe('parsers.yaml', function()
  it('parses nested mappings and block sequences', function()
    local doc = yaml.parse([[
info:
  name: Example
  tags:
    - one
    - two
http:
  method: GET
  headers:
    - name: Accept
      value: application/json
]])
    eq('Example', doc.info.name)
    eq({ 'one', 'two' }, doc.info.tags)
    eq('GET', doc.http.method)
    eq({ { name = 'Accept', value = 'application/json' } }, doc.http.headers)
  end)

  it('parses literal block scalars', function()
    local doc = yaml.parse([[
body:
  type: json
  data: |-
    {
      "hello": "world"
    }
]])
    eq('json', doc.body.type)
    match(doc.body.data, '"hello"')
    match(doc.body.data, '"world"')
    falsy(doc.body.data:find('\n$', 1, true), 'chomping indicator must remove the trailing newline')
  end)

  it('parses folded scalars', function()
    local doc = yaml.parse([[
text: >
  hello
  world
]])
    eq('hello world\n', doc.text)
  end)

  it('parses flow collections and quoted values', function()
    local doc = yaml.parse([[
list: [one, "two, three", 3]
map: {a: 1, b: "x # y"}
quoted: 'it''s fine'
]])
    eq({ 'one', 'two, three', 3 }, doc.list)
    eq(1, doc.map.a)
    eq('x # y', doc.map.b)
    eq("it's fine", doc.quoted)
  end)

  it('ignores comments outside quoted scalars', function()
    local doc = yaml.parse([[
# top-level comment
name: value # inline comment
url: "http://example.com/#fragment"
]])
    eq('value', doc.name)
    eq('http://example.com/#fragment', doc.url)
  end)

  it('returns an empty table for an empty document', function()
    eq({}, yaml.parse(''))
    eq({}, yaml.parse('# only a comment\n'))
  end)
end)
