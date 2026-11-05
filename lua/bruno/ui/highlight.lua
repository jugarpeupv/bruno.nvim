local M = {}

M.groups = {
  BrunoTabActive = { link = 'TabLineSel', default = true },
  BrunoTabInactive = { link = 'TabLine', default = true },
  BrunoTitle = { link = 'Title', default = true },
  BrunoMethod = { link = 'Statement', default = true },
  BrunoUrl = { link = 'String', default = true },
  BrunoEnv = { link = 'DiagnosticInfo', default = true },
  BrunoKey = { link = 'Identifier', default = true },
  BrunoValue = { link = 'Normal', default = true },
  BrunoMuted = { link = 'Comment', default = true },
  BrunoOk = { link = 'DiagnosticOk', default = true },
  BrunoWarn = { link = 'DiagnosticWarn', default = true },
  BrunoError = { link = 'DiagnosticError', default = true },
  BrunoPass = { link = 'DiagnosticOk', default = true },
  BrunoFail = { link = 'DiagnosticError', default = true },
  BrunoRunning = { link = 'DiagnosticWarn', default = true },
}

function M.setup()
  for name, definition in pairs(M.groups) do
    local options = vim.deepcopy(definition)
    options.default = true
    vim.api.nvim_set_hl(0, name, options)
  end
end

return M
