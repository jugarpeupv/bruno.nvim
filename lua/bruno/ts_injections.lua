local M = {}

-- Bruno OpenCollection (.yml) `scripts` entries store request/response hooks
-- as `{ type: <hook>, code: <js> }`. Highlight `code` as JavaScript instead of
-- a plain string when its sibling `type` is one of the known hook names.
--
-- This is also shipped as `after/queries/yaml/injections.scm`, but relying on
-- that file alone is fragile: Neovim memoizes the merged injections query the
-- first time it is requested, and each buffer's parser caches that query at
-- creation time. If a `.yml` buffer's Treesitter parser is created before
-- bruno.nvim is loaded (e.g. lazy-loaded by a different filetype), it never
-- picks up the extension. Registering it explicitly here, and refreshing any
-- already-open YAML buffers, makes this deterministic instead of dependent on
-- load order.
local QUERY = [[
;extends

(block_mapping
  (block_mapping_pair
    key: (flow_node (plain_scalar (string_scalar) @_type_key))
    value: (flow_node (plain_scalar (string_scalar) @_type_value))
    (#eq? @_type_key "type"))
  (block_mapping_pair
    key: (flow_node (plain_scalar (string_scalar) @_code_key))
    value: (block_node (block_scalar) @injection.content)
    (#eq? @_code_key "code"))
  (#any-of? @_type_value "before-request" "pre-request" "after-response" "post-response" "tests")
  (#set! injection.language "javascript")
  (#offset! @injection.content 0 1 0 0))

(block_mapping
  (block_mapping_pair
    key: (flow_node (plain_scalar (string_scalar) @_type_key))
    value: (flow_node (plain_scalar (string_scalar) @_type_value))
    (#eq? @_type_key "type"))
  (block_mapping_pair
    key: (flow_node (plain_scalar (string_scalar) @_code_key))
    value: (flow_node (plain_scalar (string_scalar) @injection.content))
    (#eq? @_code_key "code"))
  (#any-of? @_type_value "before-request" "pre-request" "after-response" "post-response" "tests")
  (#set! injection.language "javascript"))
]]

local YAML_FILETYPES = { yaml = true, yml = true }

---Force a buffer's already-created Treesitter parser to pick up the current
---(possibly just-registered) injection query.
---
---`vim.treesitter.get_parser`/`vim.treesitter.start` cache the parser per
---buffer and the parser caches its injection query at creation time, so
---`vim.treesitter.stop`/`start` alone reuse the same stale query object.
---Overwriting the private field and invalidating is the only reliable way to
---make an already-parsed buffer notice a newly registered injection query.
---@param buf integer
local function refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'yaml')
  if not ok or not parser then
    return
  end
  -- Intentionally reaching into a private field: there is no public API to
  -- force an already-created LanguageTree to pick up a newly registered
  -- injection query (`vim.treesitter.stop`/`start` reuse the cached parser).
  ---@diagnostic disable-next-line: invisible
  parser._injection_query = vim.treesitter.query.get('yaml', 'injections')
  parser:invalidate(true)
  pcall(parser.parse, parser, true)
end

---Register the YAML injection extension and refresh any `.yml`/`.yaml`
---buffers that are already open, so they do not keep using a stale query
---cached before this plugin loaded.
function M.setup()
  local ok = pcall(vim.treesitter.query.set, 'yaml', 'injections', QUERY)
  if not ok then
    return
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and YAML_FILETYPES[vim.bo[buf].filetype] then
      refresh(buf)
    end
  end
end

return M
