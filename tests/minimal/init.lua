local root = vim.fn.getcwd()
vim.opt.rtp:append(root)
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
