local detect = require('bruno.detect')

---@param root string
---@param rel string
---@param content string
local function write(root, rel, content)
  local path = root .. '/' .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  vim.fn.writefile(vim.split(content, '\n', { plain = true }), path)
end

---@return string
local function tempdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

describe('collection detection', function()
  it('finds the nearest ancestor collection from cwd', function()
    local root = tempdir()
    write(root, 'bruno.json', '{"version":"1","name":"one","type":"collection"}')
    write(root, 'requests/ping.bru', 'meta { name: ping }')
    local result = detect.detect({ cwd = root .. '/requests' })
    eq(root, result.root)
    eq('upward', result.source)
    eq({ root }, result.roots)
    vim.fn.delete(root, 'rf')
  end)

  it('caches detection by cwd and supports refresh', function()
    local root = tempdir()
    write(root, 'opencollection.yml', 'opencollection: 1.0.0\ninfo:\n  name: one\n')
    local first = detect.detect({ cwd = root })
    eq(false, first.cached)
    local second = detect.detect({ cwd = root })
    eq(true, second.cached)
    eq(root, second.root)
    local forced = detect.detect({ cwd = root, force = true })
    eq(false, forced.cached)
    eq(root, forced.root)
    detect.clear()
    vim.fn.delete(root, 'rf')
  end)

  it('searches downward and skips dependency folders', function()
    local root = tempdir()
    write(root, 'api/bruno.json', '{"version":"1","name":"api","type":"collection"}')
    write(root, 'web/opencollection.yml', 'opencollection: 1.0.0\ninfo:\n  name: web\n')
    write(root, 'node_modules/pkg/bruno.json', '{"version":"1","name":"ignored","type":"collection"}')
    write(root, '.hidden/bruno.json', '{"version":"1","name":"hidden","type":"collection"}')

    local result = detect.detect({ cwd = root, force = true })
    eq('downward', result.source)
    eq(2, #result.roots)
    eq(root .. '/api', result.roots[1])
    eq(root .. '/web', result.roots[2])
    vim.fn.delete(root, 'rf')
    detect.clear()
  end)

  it('returns an empty detection when nothing is found', function()
    local root = tempdir()
    local result = detect.detect({ cwd = root, force = true })
    eq(nil, result.root)
    eq({}, result.roots)
    eq('none', result.source)
    vim.fn.delete(root, 'rf')
    detect.clear()
  end)

  it('describes the detected collection', function()
    local root = tempdir()
    write(root, 'bruno.json', '{"version":"1","name":"described","type":"collection"}')
    write(root, 'environments/Local.bru', 'vars {\n  baseUrl: http://localhost\n}\n')
    local result = detect.detect({ cwd = root, force = true })
    local lines = detect.describe(result)
    contains(lines, 'Bruno collection: ' .. root)
    contains(lines, 'Bruno name: described')
    contains(lines, 'Bruno selected environment: Local')
    vim.fn.delete(root, 'rf')
    detect.clear()
  end)
end)
