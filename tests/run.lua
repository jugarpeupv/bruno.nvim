local root = vim.fn.getcwd()
local harness = dofile(root .. '/tests/harness.lua')

_G.describe = harness.describe
_G.it = harness.it
_G.eq = harness.eq
_G.truthy = harness.truthy
_G.falsy = harness.falsy
_G.match = harness.match
_G.contains = harness.contains

local specs = vim.fn.glob(root .. '/tests/unit/*_spec.lua', false, true)
table.sort(specs)

for _, spec in ipairs(specs) do
  dofile(spec)
end

harness.run()
