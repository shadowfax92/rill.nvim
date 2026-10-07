--- Maps review coordinates to editable working files. Historical content stays
--- in the review model; this module never creates a buffer or owns a window.
local M = {}

-- Git hunk starts with zero lines refer to the preceding line. Convert them to
-- insertion boundaries before shifting unchanged regions or clamping a change.
local function map_line(hunks, line)
  local offset = 0
  for _, hunk in ipairs(hunks) do
    local a, ac, b, bc = unpack(hunk)
    a, b = ac == 0 and a + 1 or a, bc == 0 and b + 1 or b
    if line < a then
      break
    elseif ac > 0 and line < a + ac then
      return b + math.min(line - a, math.max(0, bc - 1)), false
    end
    offset = b + bc - a - ac
  end
  return line + offset, true
end

-- Context within a review hunk is exact. Runs of removed/added lines are the
-- only approximate regions; treating the entire context-bearing hunk as changed
-- would incorrectly warn for unchanged lines next to an edit.
local function review_changes(file)
  local changes = {}
  for _, hunk in ipairs(file.hunks) do
    local a = hunk.old_count == 0 and hunk.old_start + 1 or hunk.old_start
    local b = hunk.new_count == 0 and hunk.new_start + 1 or hunk.new_start
    local change
    local function flush()
      if change then
        if change[2] == 0 then
          change[1] = change[1] - 1
        end
        if change[4] == 0 then
          change[3] = change[3] - 1
        end
        changes[#changes + 1], change = change, nil
      end
    end
    for _, row in ipairs(hunk.rows) do
      if row.old and row.new then
        flush()
      else
        change = change or { a, 0, b, 0 }
        if row.old then
          change[2] = change[2] + 1
        end
        if row.new then
          change[4] = change[4] + 1
        end
      end
      if row.old then
        a = a + 1
      end
      if row.new then
        b = b + 1
      end
    end
    flush()
  end
  return changes
end

---@param file table Review model with its pinned snapshot.
---@param side 'old'|'new'
---@param line integer
---@param callback fun(reason: string?, location: table?)
---@return function cancel
function M.locate(file, side, line, callback)
  local git, snapshot = require("rill.git"), file.snapshot
  local cancelled, pending = false, {}
  local exact = true
  if side == "old" then
    line, exact = map_line(review_changes(file), line)
  end
  local function finish(err, current, reviewed)
    if cancelled then
      return
    end
    if err then
      callback(err)
      return
    end
    if reviewed then
      local hunks = vim.diff(
        table.concat(reviewed.lines, "\n") .. "\n",
        table.concat(current.lines, "\n") .. "\n",
        { result_type = "indices", algorithm = "histogram", ignore_cr_at_eol = true }
      )
      local unchanged
      line, unchanged = map_line(hunks, line)
      exact = exact and unchanged
    end
    local clamped = math.max(1, math.min(line, #current.lines))
    callback(nil, { path = current.path, line = clamped, exact = exact and clamped == line })
  end
  pending[#pending + 1] = git.working_source(snapshot, file.meta, function(err, current)
    if cancelled then
      return
    end
    if err or snapshot.right.kind == "worktree" then
      finish(err, current)
      return
    end
    pending[#pending + 1] = git.source(snapshot, file.meta, "new", function(source_err, reviewed)
      finish(source_err, current, reviewed)
    end)
  end)
  return function()
    cancelled = true
    for _, cancel in ipairs(pending) do
      cancel()
    end
  end
end

return M
