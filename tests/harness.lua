local M = {
  specs = {},
  prefix = {},
  passed = 0,
  failed = 0,
  failures = {},
}

---@param name string
---@param fn fun()
function M.describe(name, fn)
  table.insert(M.prefix, name)
  local ok, err = pcall(fn)
  table.remove(M.prefix)
  if not ok then
    M.failed = M.failed + 1
    table.insert(M.failures, { name = table.concat(M.prefix, ' > ') .. ' > ' .. name, error = tostring(err) })
  end
end

---@param name string
---@param fn fun()
function M.it(name, fn)
  table.insert(M.specs, {
    name = table.concat(M.prefix, ' > ') .. ' > ' .. name,
    fn = fn,
  })
end

---@param message string
local function fail(message)
  error(message, 3)
end

---@param expected any
---@param actual any
---@param message? string
function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail(
      (message and (message .. ': ') or '') .. 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual)
    )
  end
end

---@param value any
---@param message? string
function M.truthy(value, message)
  if not value then
    fail((message and (message .. ': ') or '') .. 'expected a truthy value, got ' .. vim.inspect(value))
  end
end

---@param value any
---@param message? string
function M.falsy(value, message)
  if value then
    fail((message and (message .. ': ') or '') .. 'expected a falsy value, got ' .. vim.inspect(value))
  end
end

---@param value string
---@param pattern string
---@param message? string
function M.match(value, pattern, message)
  if type(value) ~= 'string' or not value:match(pattern) then
    fail((message and (message .. ': ') or '') .. 'expected ' .. vim.inspect(value) .. ' to match ' .. pattern)
  end
end

---@param list any[]
---@param expected any
---@param message? string
function M.contains(list, expected, message)
  for _, value in ipairs(list or {}) do
    if vim.deep_equal(value, expected) then
      return
    end
  end
  fail(
    (message and (message .. ': ') or '') .. 'expected ' .. vim.inspect(list) .. ' to contain ' .. vim.inspect(expected)
  )
end

function M.run()
  for _, spec in ipairs(M.specs) do
    local ok, err = pcall(spec.fn)
    if ok then
      M.passed = M.passed + 1
      io.write('  ✓ ' .. spec.name .. '\n')
    else
      M.failed = M.failed + 1
      table.insert(M.failures, { name = spec.name, error = tostring(err) })
      io.write('  ✗ ' .. spec.name .. '\n')
    end
  end

  io.write('\n')
  io.write(string.format('%d passed, %d failed\n', M.passed, M.failed))

  if M.failed > 0 then
    io.write('\nFailures:\n')
    for _, failure in ipairs(M.failures) do
      io.write('  ✗ ' .. failure.name .. '\n')
      for line in tostring(failure.error):gmatch('[^\n]+') do
        io.write('      ' .. line .. '\n')
      end
    end
    vim.cmd('cq')
  else
    vim.cmd('qa!')
  end
end

return M
