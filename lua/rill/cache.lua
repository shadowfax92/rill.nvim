--- Bounds retained full-file sources independently of the review's patch budget.
--- Collapsed hunks own their source-addressed cells, so their projections survive
--- source eviction. Expanded context and active async consumers pin their sources.
local M = {}
local Cache = {}
Cache.__index = Cache

local DEFAULT_LIMIT = 32 * 1024 * 1024

local function expanded(file)
  for _, gap in pairs(file.expansion or {}) do
    if gap.all or (gap.top or 0) > 0 or (gap.bottom or 0) > 0 then
      return true
    end
  end
  return false
end

local function pinned(file, protected)
  if protected[file] or (file.meta and protected[file.meta.id]) then
    return true
  end
  if expanded(file) or file.pending_expansion or file.source_waiters then
    return true
  end
  if file.syntax_loading or file.words_loading then
    return true
  end
  for _, job in pairs(file._highlight_jobs or {}) do
    if job.active then
      return true
    end
  end
  return false
end

-- These are conservative LuaJIT allocation estimates, not an allocator census.
-- Count strings and aliased source arrays once within each file: hydration copies
-- the line arrays, but the immutable line strings remain shared. Capture arrays
-- use a fixed per-span allowance to avoid walking every capture field on prune.
local function retained_size(file)
  local total, tables, strings = 0, {}, {}
  local function text(value)
    if type(value) == "string" and not strings[value] then
      strings[value] = true
      total = total + #value + 32
    end
  end
  local function lines(value)
    if type(value) ~= "table" or tables[value] then
      return
    end
    tables[value] = true
    total = total + 64 + #value * 16
    for _, line in ipairs(value) do
      text(line)
    end
  end
  local function source(value)
    if type(value) ~= "table" or tables[value] then
      return
    end
    tables[value] = true
    total = total + 256
    text(value.text)
    text(value.identity)
    text(value.label)
    lines(value.lines)
  end
  if file.sources then
    total = total + 96
    source(file.sources.old)
    source(file.sources.new)
  end
  source(file.meta and file.meta._new_source)
  lines(file.old_source)
  lines(file.new_source)
  if file.syntax then
    total = total + 96
    for _, side in pairs(file.syntax) do
      if type(side) == "table" and not tables[side] then
        tables[side] = true
        total = total + 64
        for _, spans in pairs(side) do
          if type(spans) == "table" and not tables[spans] then
            tables[spans] = true
            total = total + 96 + #spans * 192
          end
        end
      end
    end
  end
  return total
end

local function evict(file)
  file.sources, file.old_source, file.new_source = nil, nil, nil
  file.hydrated, file.source_error, file.syntax = false, nil, nil
  if file.meta then
    -- Untracked files initially retain the bytes used to synthesize their patch.
    -- Releasing that snapshot matters even before hydration. A later load reads
    -- the worktree again, and model.hydrate rejects changes against the patch.
    file.meta._new_source = nil
  end
  -- Do not dispose the file: hunks, word spans, source addresses, and future
  -- highlighting remain valid. Active jobs were pinned before reaching here.
end

function M.new(limit)
  limit = limit == nil and DEFAULT_LIMIT or limit
  assert(
    type(limit) == "number" and limit >= 0 and limit < math.huge,
    "Source cache limit must be a nonnegative finite byte count"
  )
  return setmetatable({
    limit = limit,
    clock = 0,
    -- A session refresh owns file lifetime; LRU bookkeeping must not retain old
    -- documents after the view has released them.
    recency = setmetatable({}, { __mode = "k" }),
    measurements = setmetatable({}, { __mode = "k" }),
  }, Cache)
end

function Cache:touch(file)
  self.clock = self.clock + 1
  self.recency[file] = self.clock
end

function Cache:measure(file)
  local remembered = self.measurements[file]
  local untracked = file.meta and file.meta._new_source
  -- Sources and syntax are published atomically and then treated as immutable.
  -- Reference checks make repeated scrolling/pruning O(number of cached files),
  -- rather than repeatedly traversing every full source and syntax capture.
  if
    remembered
    and remembered.sources == file.sources
    and remembered.old == file.old_source
    and remembered.new == file.new_source
    and remembered.syntax == file.syntax
    and remembered.untracked == untracked
  then
    return remembered.bytes
  end
  local bytes = retained_size(file)
  self.measurements[file] = {
    sources = file.sources,
    old = file.old_source,
    new = file.new_source,
    syntax = file.syntax,
    untracked = untracked,
    bytes = bytes,
  }
  return bytes
end

--- Evict least recently used eligible sources and report any intentionally pinned
--- overflow in bytes. Call after source waiters settle; visible/opening files are
--- protected by a set keyed by file objects (or stable metadata IDs).
function Cache:prune(files, protected)
  protected = protected or {}
  local retained, candidates, seen = 0, {}, {}
  for index, file in ipairs(files) do
    if not seen[file] then
      seen[file] = true
      local bytes = self:measure(file)
      retained = retained + bytes
      if bytes > 0 and not pinned(file, protected) then
        candidates[#candidates + 1] =
          { file = file, bytes = bytes, used = self.recency[file] or 0, order = index }
      end
    end
  end
  table.sort(candidates, function(a, b)
    return a.used == b.used and a.order < b.order or a.used < b.used
  end)
  local evicted = {}
  for _, candidate in ipairs(candidates) do
    if retained <= self.limit then
      break
    end
    evict(candidate.file)
    self.measurements[candidate.file] = nil
    retained = retained - candidate.bytes
    evicted[#evicted + 1] = candidate.file
  end
  return {
    retained_bytes = retained,
    evicted = #evicted,
    evicted_files = evicted,
    pinned_overflow = math.max(0, retained - self.limit),
  }
end

return M
