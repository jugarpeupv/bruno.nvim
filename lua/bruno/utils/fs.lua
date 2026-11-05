local M = {}

local METADATA_FILES = {
  ['folder.bru'] = true,
  ['collection.bru'] = true,
  ['folder.yml'] = true,
  ['folder.yaml'] = true,
  ['opencollection.yml'] = true,
  ['opencollection.yaml'] = true,
}

---@param path string
---@return string
function M.normalize(path)
  if path == '' then
    return path
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

---@param path string
---@return boolean
function M.is_bru(path)
  return vim.fn.fnamemodify(path, ':e') == 'bru'
end

---@param path string
---@return boolean
function M.is_yml(path)
  local ext = vim.fn.fnamemodify(path, ':e'):lower()
  return ext == 'yml' or ext == 'yaml'
end

---@param path string
---@return boolean
function M.is_metadata_file(path)
  return METADATA_FILES[vim.fn.fnamemodify(path, ':t')] == true
end

---@param path string
---@return boolean
function M.is_request_file(path)
  if path == nil or path == '' or M.is_metadata_file(path) then
    return false
  end
  return M.is_bru(path) or M.is_yml(path)
end

---@param path string
---@return string|nil
function M.read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return table.concat(lines, '\n')
end

---Write a file with conservative permissions.
---@param path string
---@param content string
---@param mode? integer
---@return boolean ok
---@return string? err
function M.write_file(path, content, mode)
  if mode then
    local fd, open_err = vim.uv.fs_open(path, 'w', mode)
    if not fd then
      return false, tostring(open_err)
    end
    local ok, write_err = pcall(vim.uv.fs_write, fd, content, -1)
    pcall(vim.uv.fs_close, fd)
    if not ok then
      return false, tostring(write_err)
    end
    pcall(vim.uv.fs_chmod, path, mode)
    return true, nil
  end

  local normalized = content
  if normalized:sub(-1) == '\n' then
    normalized = normalized:sub(1, -2)
  end
  local ok, err = pcall(vim.fn.writefile, vim.split(normalized, '\n', { plain = true }), path)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

---@param path string
---@return boolean
function M.exists(path)
  return vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1
end

---@param path string
---@return string|nil
function M.find_collection_root(path)
  local dir = vim.fn.isdirectory(path) == 1 and M.normalize(path) or M.normalize(vim.fn.fnamemodify(path, ':h'))

  while dir ~= '' and dir ~= '/' do
    if vim.fn.filereadable(dir .. '/bruno.json') == 1 then
      return dir
    end
    if
      vim.fn.filereadable(dir .. '/opencollection.yml') == 1
      or vim.fn.filereadable(dir .. '/opencollection.yaml') == 1
    then
      return dir
    end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then
      break
    end
    dir = parent
  end

  return nil
end

---@param path string
---@return bruno.Format?
function M.detect_format(path)
  if M.is_bru(path) then
    return 'bru'
  end
  if M.is_yml(path) then
    return 'yml'
  end
  return nil
end

---@param path string
---@return string
function M.basename(path)
  return vim.fn.fnamemodify(path, ':t')
end

---@param path string
---@return string
function M.basename_no_ext(path)
  return vim.fn.fnamemodify(path, ':t:r')
end

---@param path string
---@return string
function M.dirname(path)
  return vim.fn.fnamemodify(path, ':p:h')
end

---@param root string
---@param path string
---@return string
function M.relpath(root, path)
  local rel = vim.fs.relpath(root, path)
  return rel or path
end

---Create a hidden temporary sibling of `path`.
---@param path string
---@return string
function M.sibling_tempname(path)
  local dir = M.dirname(path)
  local ext = vim.fn.fnamemodify(path, ':e')
  local random = vim.fn
    .sha256(table.concat({
      tostring(vim.uv.hrtime()),
      tostring(math.random()),
      path,
    }, ':'))
    :sub(1, 16)
  return dir .. '/.bruno-nvim-' .. random .. '.' .. ext
end

---@param path string
function M.unlink(path)
  pcall(vim.uv.fs_unlink, path)
end

---@param path string
---@return boolean
function M.mkdir(path)
  if vim.fn.isdirectory(path) == 1 then
    return true
  end
  local ok = pcall(vim.fn.mkdir, path, 'p')
  return ok and vim.fn.isdirectory(path) == 1
end

---Walk up from `dir` and yield directories until the filesystem root.
---@param dir string
---@return string[]
function M.ancestors(dir)
  local result = {}
  local current = M.normalize(dir)
  while current ~= '' and current ~= '/' do
    table.insert(result, current)
    local parent = vim.fn.fnamemodify(current, ':h')
    if parent == current then
      break
    end
    current = parent
  end
  return result
end

---@param dir string
---@param names string[]
---@return string?
function M.find_up(dir, names)
  for _, ancestor in ipairs(M.ancestors(dir)) do
    for _, name in ipairs(names) do
      local candidate = ancestor .. '/' .. name
      if vim.fn.filereadable(candidate) == 1 then
        return candidate
      end
    end
  end
  return nil
end

return M
