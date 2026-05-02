local M = {}

function M.with_tempfile(content, fn)
  local path = vim.fn.tempname()
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
  local ok, err = pcall(fn, path)
  os.remove(path)
  if not ok then error(err) end
end

function M.write_file(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

function M.read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- Replace tbl[key] with replacement; return a function that restores it.
function M.stub(tbl, key, replacement)
  local original = rawget(tbl, key)
  tbl[key] = replacement
  return function() tbl[key] = original end
end

-- Set the mtime of a file (seconds since epoch).
function M.set_mtime(path, secs)
  vim.loop.fs_utime(path, secs, secs)
end

return M
