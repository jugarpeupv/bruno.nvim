-- Development spec for lazy.nvim.
--
-- Add this directory to your plugin list, for example:
--   require('lazy').setup({ { import = 'plugins' } })
-- and place this file in ~/.config/nvim/lua/plugins/bruno-dev.lua, or copy the
-- table below into your plugins file.
return {
  dir = vim.fn.expand('~/projects/bruno.nvim'),
  name = 'bruno',
  ft = { 'bruno' },
  opts = {},
}
