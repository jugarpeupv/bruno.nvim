local M = {}

---@type bruno.Config
M.defaults = {
  cli = 'bru',
  default_env = nil,
  cli_args = {},
  timeout = 0,
  notify = true,
  log_level = 'warn',
  ui = {
    split = 'right',
    width = 0.45,
    height = 0.35,
    auto_open = true,
    default_tab = 'request',
    result_tab = 'body',
    tabs = { 'request', 'body', 'headers', 'tests', 'scripts', 'timeline', 'raw', 'verbose' },
    keymaps = {
      next_tab = '<Tab>',
      prev_tab = '<S-Tab>',
      next_request = '}',
      prev_request = '{',
      next_response = ')',
      prev_response = '(',
      tab_1 = '1',
      tab_2 = '2',
      tab_3 = '3',
      tab_4 = '4',
      tab_5 = '5',
      tab_6 = '6',
      tab_7 = '7',
      tab_8 = '8',
      run = 'R',
      replay = 'r',
      edit_source = 'e',
      env = 'ge',
      requests = 'p',
      auth = 'a',
      auth_clear = 'A',
      copy_curl = 'c',
      yank_body = 'y',
      yank_raw = 'Y',
      help = '?',
      close = 'q',
      hover = 'K',
      select_tab = '<CR>',
    },
  },
  oauth2 = {
    enabled = true,
    cache = true,
    open_browser = true,
    browser_cmd = nil,
    callback_timeout = 120000,
    default_callback_url = 'http://127.0.0.1:53682/callback',
    token_timeout = 30000,
    refresh_leeway = 60,
  },
}

---@type bruno.Config
M.options = vim.deepcopy(M.defaults)

---Merge user options into the defaults. Calling setup more than once is safe.
---@param opts? table
---@return bruno.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})

  if M.options.ui.width < 0.1 or M.options.ui.width > 1 then
    M.options.ui.width = M.defaults.ui.width
  end
  if M.options.ui.height < 0.1 or M.options.ui.height > 1 then
    M.options.ui.height = M.defaults.ui.height
  end
  if type(M.options.ui.tabs) ~= 'table' or #M.options.ui.tabs == 0 then
    M.options.ui.tabs = vim.deepcopy(M.defaults.ui.tabs)
  end

  return M.options
end

---@return bruno.Config
function M.get()
  return M.options
end

return M
