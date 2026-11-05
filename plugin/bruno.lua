if vim.g.loaded_bruno_nvim == 1 then
  return
end
vim.g.loaded_bruno_nvim = 1

require('bruno').setup()
