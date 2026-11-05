local M = {}

local FILETYPE = 'bruno_ui'
local MARKDOWN = 'markdown'

---@return boolean
local function loaded()
  return package.loaded['render-markdown.state'] ~= nil
end

---Make render-markdown.nvim treat `bruno_ui` as a Markdown filetype.
---@return boolean
local function ensure_filetype()
  if not loaded() then
    return false
  end

  local state = require('render-markdown.state')
  if not vim.tbl_contains(state.file_types, FILETYPE) then
    state.file_types[#state.file_types + 1] = FILETYPE
  end
  return true
end

---@param buf integer
local function attach(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= FILETYPE then
    return
  end
  if not ensure_filetype() then
    return
  end

  local manager = require('render-markdown.core.manager')
  if manager.attached(buf) then
    return
  end
  pcall(manager.attach, buf)
end

function M.attach_buffer(buf)
  attach(buf)
end

function M.setup()
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('BrunoRenderMarkdown', { clear = true }),
    pattern = FILETYPE,
    callback = function(args)
      -- Defer until the workbench has been populated and other FileType
      -- handlers have finished.
      vim.schedule(function()
        attach(args.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd('User', {
    group = 'BrunoRenderMarkdown',
    pattern = 'LazyLoad',
    callback = function(args)
      local name = type(args.data) == 'string' and args.data or ''
      if not name:find('render%-markdown') then
        return
      end

      if not ensure_filetype() then
        return
      end

      local manager = require('render-markdown.core.manager')
      local state = require('render-markdown.state')
      local current = vim.api.nvim_get_current_buf()

      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if
          buf ~= current
          and vim.api.nvim_buf_is_valid(buf)
          and vim.bo[buf].filetype == FILETYPE
          and not manager.attached(buf)
        then
          pcall(manager.attach, buf)
        end
      end

      if vim.api.nvim_buf_is_valid(current) and vim.bo[current].filetype == FILETYPE then
        if not manager.attached(current) then
          state.enabled = false
          pcall(manager.attach, current)
        end
      end
    end,
  })
end

return M
