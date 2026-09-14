--- Source-addressed Git review data, independent of Neovim buffers and Git jobs.
--- Both layouts project this document; display offsets never become source lines.
local M = {}

-- Git may preserve CRLF in patch bodies and source snapshots. A terminal CR is
-- line-ending metadata, not a display column; retain raw source arrays separately.
local function display(text)
  return (text:gsub("\r$", ""))
end

local function lines(text)
  local result = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    result[#result + 1] = line
  end
  return result
end

local function cell(line, text)
  return { line = line, text = display(text) }
end

-- A zero-length hunk range names the line *before* its insertion point. Convert
-- that boundary once so gap arithmetic also works at BOF and deletion-only EOF.
local function first_line(start, count)
  return count == 0 and start + 1 or start
end

local function range_header(text)
  local old_start, old_count, new_start, new_count, heading =
    text:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@(.*)$")
  if not old_start then
    return nil
  end
  return {
    old_start = tonumber(old_start),
    old_count = old_count == "" and 1 or tonumber(old_count),
    new_start = tonumber(new_start),
    new_count = new_count == "" and 1 or tonumber(new_count),
    heading = display(heading):match("^%s*(.-)%s*$"),
    rows = {},
  }
end

local function parse_hunk(patch, index, hunk, ordinal)
  local old_line = first_line(hunk.old_start, hunk.old_count)
  local new_line = first_line(hunk.new_start, hunk.new_count)
  local old_end, new_end = old_line + hunk.old_count, new_line + hunk.new_count
  local previous
  index = index + 1
  while index <= #patch do
    local raw = patch[index]
    local prefix = raw:sub(1, 1)
    if raw:match("^\\ No newline at end of file") then
      if previous then
        if previous.old then
          previous.old.no_newline = true
        end
        if previous.new then
          previous.new.no_newline = true
        end
      end
    elseif old_line == old_end and new_line == new_end then
      break
    else
      local row = { kind = "code", hunk = ordinal }
      -- Only hunk counts delimit the body. In particular, source lines beginning
      -- with ---/+++/@@ in a committed patch file are never reparsed as headers.
      if prefix == " " then
        row.change = "context"
        row.old, row.new = cell(old_line, raw:sub(2)), cell(new_line, raw:sub(2))
        old_line, new_line = old_line + 1, new_line + 1
      elseif prefix == "-" then
        row.change, row.old = "delete", cell(old_line, raw:sub(2))
        old_line = old_line + 1
      elseif prefix == "+" then
        row.change, row.new = "add", cell(new_line, raw:sub(2))
        new_line = new_line + 1
      else
        return nil, "Malformed patch: unexpected line inside a hunk"
      end
      if old_line > old_end or new_line > new_end then
        return nil, "Malformed patch: hunk exceeds its source range"
      end
      hunk.rows[#hunk.rows + 1], previous = row, row
    end
    index = index + 1
  end
  if old_line ~= old_end or new_line ~= new_end then
    return nil, "Malformed patch: incomplete hunk"
  end
  return index
end

--- Parse a single metadata-owned patch; paths always come from NUL-safe Git data.
function M.parse(meta)
  local file = { meta = meta, hunks = {}, expansion = {}, hydrated = false, details = {} }
  if meta.omitted_reason or meta.binary then
    return file
  end
  local patch, index = lines(meta.patch), 1
  local old_cursor, new_cursor = 1, 1
  while index <= #patch do
    local raw = patch[index]
    local hunk = range_header(raw)
    if hunk then
      if (hunk.old_count > 0 and hunk.old_start == 0) or (hunk.new_count > 0 and hunk.new_start == 0) then
        file.error = "Malformed patch: nonempty source ranges begin at line one"
        break
      end
      local old_gap = first_line(hunk.old_start, hunk.old_count) - old_cursor
      local new_gap = first_line(hunk.new_start, hunk.new_count) - new_cursor
      if old_gap < 0 or new_gap < 0 or old_gap ~= new_gap then
        file.error = "Malformed patch: inconsistent unchanged source ranges"
        break
      end
      local next_index, err = parse_hunk(patch, index, hunk, #file.hunks + 1)
      if not next_index then
        file.error = err
        break
      end
      file.hunks[#file.hunks + 1] = hunk
      old_cursor = first_line(hunk.old_start, hunk.old_count) + hunk.old_count
      new_cursor = first_line(hunk.new_start, hunk.new_count) + hunk.new_count
      index = next_index
    else
      if
        raw:match("^old mode ")
        or raw:match("^new mode ")
        or raw:match("^new file mode ")
        or raw:match("^deleted file mode ")
      then
        file.details[#file.details + 1] = display(raw)
      end
      if raw:match("^Binary files ") or raw == "GIT binary patch" then
        file.binary = true
      end
      index = index + 1
    end
  end
  return file
end

local function gaps(file)
  local result, old_cursor, new_cursor = {}, 1, 1
  for index, hunk in ipairs(file.hunks) do
    local old_first = first_line(hunk.old_start, hunk.old_count)
    local new_first = first_line(hunk.new_start, hunk.new_count)
    result[#result + 1] = {
      key = "gap:" .. index,
      old_start = old_cursor,
      old_count = old_first - old_cursor,
      new_start = new_cursor,
      new_count = new_first - new_cursor,
    }
    old_cursor, new_cursor = old_first + hunk.old_count, new_first + hunk.new_count
  end
  result[#result + 1] = {
    key = "gap:" .. (#file.hunks + 1),
    old_start = old_cursor,
    new_start = new_cursor,
    old_count = file.hydrated and (#file.old_source - old_cursor + 1) or nil,
    new_count = file.hydrated and (#file.new_source - new_cursor + 1) or nil,
    unknown = not file.hydrated,
  }
  return result
end

local function source_context(file, gap, offset)
  local old_line, new_line = gap.old_start + offset, gap.new_start + offset
  return {
    kind = "code",
    change = "context",
    old = cell(old_line, file.old_source[old_line]),
    new = cell(new_line, file.new_source[new_line]),
  }
end

local function project_gap(file, gap, rows)
  local count = gap.new_count
  if gap.unknown then
    rows[#rows + 1] = {
      kind = "gap",
      key = gap.key,
      unknown = true,
      old_start = gap.old_start,
      new_start = gap.new_start,
      text = #file.hunks == 0 and "Load full file context" or "Load remaining context",
    }
    return
  end
  if count <= 0 then
    return
  end
  local expanded = file.expansion[gap.key] or {}
  local top = math.min(expanded.all and count or (expanded.top or 0), count)
  local bottom = math.min(expanded.bottom or 0, count - top)
  for offset = 0, top - 1 do
    rows[#rows + 1] = source_context(file, gap, offset)
  end
  local hidden = count - top - bottom
  if hidden > 0 then
    rows[#rows + 1] = {
      kind = "gap",
      key = gap.key,
      old_start = gap.old_start + top,
      old_count = hidden,
      new_start = gap.new_start + top,
      new_count = hidden,
      text = ("%d unchanged %s"):format(hidden, hidden == 1 and "line" or "lines"),
    }
  end
  for offset = count - bottom, count - 1 do
    rows[#rows + 1] = source_context(file, gap, offset)
  end
end

local function project_hunk(hunk, layout, rows)
  local index = 1
  while index <= #hunk.rows do
    local row = hunk.rows[index]
    if row.change == "context" then
      rows[#rows + 1] = {
        kind = "code",
        change = "context",
        hunk = row.hunk,
        old = row.old,
        new = row.new,
      }
      index = index + 1
    else
      local removed, added = {}, {}
      local ordinal = row.hunk
      while index <= #hunk.rows and hunk.rows[index].change ~= "context" do
        row = hunk.rows[index]
        if row.old then
          removed[#removed + 1] = row.old
        end
        if row.new then
          added[#added + 1] = row.new
        end
        index = index + 1
      end
      if layout == "split" then
        for offset = 1, math.max(#removed, #added) do
          rows[#rows + 1] = {
            kind = "code",
            hunk = ordinal,
            old = removed[offset],
            new = added[offset],
            change = removed[offset] and (added[offset] and "change" or "delete") or "add",
          }
        end
      else
        for _, old in ipairs(removed) do
          rows[#rows + 1] = { kind = "code", change = "delete", hunk = ordinal, old = old }
        end
        for _, new in ipairs(added) do
          rows[#rows + 1] = { kind = "code", change = "add", hunk = ordinal, new = new }
        end
      end
    end
  end
end

--- Build source-bearing body rows; the view adds headers and renders nil split cells as padding.
function M.project(file, layout)
  assert(layout == "unified" or layout == "split", "Expected unified or split layout")
  local rows = {}
  if file.error then
    return { { kind = "meta", text = file.error } }
  end
  if file.meta.omitted_reason then
    return { { kind = "meta", text = file.meta.omitted_reason } }
  end
  if file.binary or file.meta.binary then
    return { { kind = "meta", text = "Binary file" } }
  end
  if file.meta.old_path and file.meta.old_path ~= file.meta.path then
    rows[#rows + 1] = { kind = "meta", text = "Renamed from " .. file.meta.old_path }
  end
  for _, detail in ipairs(file.details) do
    rows[#rows + 1] = { kind = "meta", text = detail }
  end
  local context_gaps = gaps(file)
  for index, hunk in ipairs(file.hunks) do
    project_gap(file, context_gaps[index], rows)
    project_hunk(hunk, layout, rows)
  end
  project_gap(file, context_gaps[#context_gaps], rows)
  if #rows == 0 then
    rows[1] = { kind = "meta", text = "Empty file" }
  end
  return rows
end

local function copy_source(source)
  if type(source) ~= "table" then
    return nil
  end
  local copy = {}
  for index, text in ipairs(source) do
    if type(text) ~= "string" then
      return nil
    end
    copy[index] = text
  end
  return copy
end

--- Atomically install immutable source snapshots after verifying the whole diff correspondence.
--- A worktree edit can race an async source read outside a displayed hunk, so unchanged
--- gaps must also match; checking only changed lines would silently invent false context.
function M.hydrate(file, old_lines, new_lines)
  if file.error then
    return false, file.error
  end
  if file.meta.omitted_reason then
    return false, file.meta.omitted_reason
  end
  if file.binary or file.meta.binary then
    return false, "Binary files have no text context"
  end
  local old_source, new_source = copy_source(old_lines), copy_source(new_lines)
  if not old_source or not new_source then
    return false, "Source snapshots must contain text lines"
  end
  for _, hunk in ipairs(file.hunks) do
    for _, row in ipairs(hunk.rows) do
      for _, side in ipairs({ "old", "new" }) do
        local value = row[side]
        local source = side == "old" and old_source or new_source
        if value and (source[value.line] == nil or display(source[value.line]) ~= value.text) then
          return false, ("Source changed at %s line %d; refresh the review"):format(side, value.line)
        end
      end
    end
  end
  -- Validate using a candidate document so failure cannot replace a previously
  -- valid source snapshot or erase the user's expansion state.
  local candidate = {
    hunks = file.hunks,
    hydrated = true,
    old_source = old_source,
    new_source = new_source,
  }
  for _, gap in ipairs(gaps(candidate)) do
    if gap.old_count < 0 or gap.new_count < 0 or gap.old_count ~= gap.new_count then
      return false, "Source length changed; refresh the review"
    end
    for offset = 0, gap.old_count - 1 do
      local old_text, new_text = old_source[gap.old_start + offset], new_source[gap.new_start + offset]
      if old_text == nil or new_text == nil or display(old_text) ~= display(new_text) then
        return false, "Unchanged source context changed; refresh the review"
      end
    end
  end
  file.old_source, file.new_source, file.hydrated = old_source, new_source, true
  return true
end

--- Reveal context at one gap edge. Keys remain stable as rows appear/disappear.
function M.expand(file, key, edge, count)
  if not file.hydrated then
    return false, "Load full source before expanding context"
  end
  if edge ~= "top" and edge ~= "bottom" and edge ~= "all" then
    return false, "Expected top, bottom, or all expansion edge"
  end
  local selected
  for _, gap in ipairs(gaps(file)) do
    if gap.key == key then
      selected = gap
      break
    end
  end
  if not selected then
    return false, "Context gap no longer exists"
  end
  local expanded = file.expansion[key] or { top = 0, bottom = 0 }
  if edge == "all" then
    expanded.all = true
  else
    count = count or 20
    if type(count) ~= "number" or count ~= count or count < 0 or count == math.huge then
      return false, "Expansion count must be a nonnegative finite number"
    end
    expanded[edge] = math.min((expanded[edge] or 0) + math.floor(count), selected.new_count)
  end
  file.expansion[key] = expanded
  return true
end

function M.expand_all(file)
  if not file.hydrated then
    return false, "Load full source before expanding context"
  end
  for _, gap in ipairs(gaps(file)) do
    file.expansion[gap.key] = { all = true }
  end
  return true
end

function M.collapse(file)
  file.expansion = {}
  return true
end

return M
