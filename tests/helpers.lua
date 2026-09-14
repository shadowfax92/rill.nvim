local M = {}

function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      (message or "values differ")
        .. "\nexpected: "
        .. vim.inspect(expected)
        .. "\nactual: "
        .. vim.inspect(actual),
      2
    )
  end
end

function M.ok(value, message)
  assert(value, message or "expected truthy value")
  return value
end

function M.await(start, timeout)
  local done, err, result = false, nil, nil
  start(function(e, value)
    err, result, done = e, value, true
  end)
  assert(
    vim.wait(timeout or 10000, function()
      return done
    end, 10),
    "async operation timed out"
  )
  assert(not err, tostring(err))
  return result
end

function M.command(args, cwd)
  local result = vim.system(args, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, result.stderr or "command failed")
  return vim.trim(result.stdout or "")
end

function M.repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  M.command({ "git", "init", "-q", "-b", "main" }, root)
  M.command({ "git", "config", "user.email", "rill@example.invalid" }, root)
  M.command({ "git", "config", "user.name", "Rill Tests" }, root)
  return root
end

function M.write(root, path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(root .. "/" .. path, ":h"), "p")
  vim.fn.writefile(lines, root .. "/" .. path)
end

function M.commit(root, message)
  M.command({ "git", "add", "--all" }, root)
  M.command({ "git", "commit", "-qm", message or "fixture" }, root)
  return M.command({ "git", "rev-parse", "HEAD" }, root)
end

return M
