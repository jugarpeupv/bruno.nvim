local M = {}

function M.check()
  local health = vim.health
  health.start('bruno.nvim')

  local config = require('bruno.config').get()

  if vim.fn.has('nvim-0.10') == 1 then
    health.ok('Neovim ' .. vim.version().major .. '.' .. vim.version().minor .. '.' .. vim.version().patch)
  else
    health.error('Neovim 0.10 or newer is required')
  end

  if vim.fn.executable(config.cli) == 1 then
    local result = vim.system({ config.cli, '--version' }, { text = true, timeout = 3000 }):wait()
    if result.code == 0 then
      health.ok(config.cli .. ': ' .. vim.trim(result.stdout or ''))
    else
      health.warn(config.cli .. ' was found but `--version` failed: ' .. vim.trim(result.stderr or ''))
    end
  else
    health.error('Bruno CLI not found: ' .. config.cli .. ' (install with `npm i -g @usebruno/cli`)')
  end

  if vim.fn.executable('curl') == 1 then
    health.ok('curl is available (used for OAuth2 token requests)')
  else
    health.error('curl is required for OAuth2 token requests')
  end

  local cache = vim.fn.stdpath('cache') .. '/bruno.nvim'
  if vim.fn.isdirectory(cache) == 1 or vim.fn.mkdir(cache, 'p') == 1 then
    health.ok('Cache directory: ' .. cache)
  else
    health.error('Could not create cache directory: ' .. cache)
  end

  local detection = require('bruno.detect').detect()
  if detection.root then
    local collection = require('bruno.parsers').collection(detection.root)
    health.ok('Collection: ' .. detection.root .. ' (' .. collection.name .. ', ' .. collection.format .. ')')
    if detection.cached then
      health.info('Detection cache: hit for ' .. detection.cwd)
    else
      health.info('Detection: ' .. detection.source .. ' from ' .. detection.cwd)
    end
    local selected = require('bruno.env').ensure(detection.root, { notify = false })
    health.info('Selected environment: ' .. (selected or '(none)'))
    local environments = require('bruno.parsers').list_environments(detection.root)
    if #environments == 0 then
      health.info('No environments found in ' .. detection.root .. '/environments')
    else
      local names = {}
      for _, environment in ipairs(environments) do
        names[#names + 1] = environment.name
      end
      health.info('Environments: ' .. table.concat(names, ', '))
    end
  else
    health.warn('No collection detected under ' .. detection.cwd .. '; run :BrunoDetect! to refresh')
  end

  local oauth_cache = require('bruno.oauth2.store').path()
  if vim.fn.filereadable(oauth_cache) == 1 then
    local stat = vim.uv.fs_stat(oauth_cache)
    if stat and (stat.mode % 64) ~= 0 then
      health.warn('OAuth2 token cache is readable by other users: ' .. oauth_cache)
    else
      health.ok('OAuth2 token cache: ' .. oauth_cache)
    end
  else
    health.info('OAuth2 token cache has not been created yet: ' .. oauth_cache)
  end
end

return M
