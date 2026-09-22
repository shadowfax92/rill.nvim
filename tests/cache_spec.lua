local H = require("tests.helpers")
local model = require("rill.model")
local cache = require("rill.cache")

local function fixture(id)
  local old = { "before context", "old value", "after context", "tail" }
  local new = { "before context", "new value", "after context", "tail" }
  local file = model.parse({
    id = id,
    path = id .. ".lua",
    status = "M",
    patch = "@@ -2 +2 @@\n-old value\n+new value\n",
  })
  H.ok(model.hydrate(file, old, new))
  file.sources = {
    old = { lines = old, text = table.concat(old, "\n") .. "\n", identity = "blob:old", label = "old" },
    new = { lines = new, text = table.concat(new, "\n") .. "\n", identity = "blob:new", label = "new" },
  }
  return file, old, new
end

local function addresses(file, layout)
  local result = {}
  for _, row in ipairs(model.project(file, layout)) do
    if row.kind == "code" then
      result[#result + 1] = { old = row.old, new = row.new, change = row.change }
    end
  end
  return result
end

return {
  eviction_uses_recent_access_and_keeps_patch_coordinates = function()
    local first, old, new = fixture("first")
    local second = fixture("second")
    local policy = cache.new()
    local size = policy:measure(first)
    policy.limit = size + 64
    policy:touch(first)
    policy:touch(second)
    policy:touch(first)
    second.syntax = { old = { [2] = { { 0, 3, "@keyword", 100 } } }, new = {} }
    second.source_error = "stale prior error"
    local old_unified, old_split = addresses(second, "unified"), addresses(second, "split")
    local stats = policy:prune({ first, second })
    H.eq(1, stats.evicted)
    H.eq(second, stats.evicted_files[1])
    H.ok(first.sources)
    H.eq(nil, second.sources)
    H.eq(nil, second.old_source)
    H.eq(nil, second.new_source)
    H.eq(nil, second.syntax)
    H.eq(nil, second.source_error)
    H.eq(false, second.hydrated)
    H.eq(nil, second.disposed)
    H.eq(old_unified, addresses(second, "unified"))
    H.eq(old_split, addresses(second, "split"))
    H.ok(model.hydrate(second, old, new), "eviction must permit future hydration")
    H.ok(model.expand_all(second))
    H.eq(5, #addresses(second, "unified"))
    H.eq(0, stats.pinned_overflow)
  end,

  visible_and_expanded_sources_are_pinned_until_collapsed = function()
    local visible, expanded, cold = fixture("visible"), fixture("expanded"), fixture("cold")
    H.ok(model.expand(expanded, "gap:1", "top", 1))
    local policy = cache.new(0)
    local before = addresses(expanded, "unified")
    local stats = policy:prune({ visible, expanded, cold }, { [visible] = true })
    H.eq(1, stats.evicted)
    H.ok(visible.sources)
    H.ok(expanded.sources)
    H.eq(nil, cold.sources)
    H.ok(stats.pinned_overflow > 0)
    H.eq(stats.retained_bytes, stats.pinned_overflow)
    H.eq(before, addresses(expanded, "unified"))
    H.ok(model.collapse(expanded))
    stats = policy:prune({ visible, expanded, cold }, { visible = true })
    H.eq(1, stats.evicted)
    H.eq(nil, expanded.sources)
    H.ok(visible.sources, "stable metadata IDs can protect a file")
  end,

  pending_consumers_and_highlight_jobs_prevent_eviction = function()
    local waiter, expansion, syntax, job =
      fixture("waiter"), fixture("expansion"), fixture("syntax"), fixture("job")
    waiter.source_waiters = {}
    expansion.pending_expansion = true
    syntax.syntax_loading = true
    job._highlight_jobs = { syntax = { active = true } }
    local files = { waiter, expansion, syntax, job }
    local policy = cache.new(0)
    H.eq(0, policy:prune(files).evicted)
    for _, file in ipairs(files) do
      H.ok(file.sources)
    end
    waiter.source_waiters, expansion.pending_expansion = nil, nil
    syntax.syntax_loading = false
    job._highlight_jobs.syntax.active = false
    H.eq(4, policy:prune(files).evicted)
  end,

  untracked_capture_is_counted_before_hydration_and_released = function()
    local source = { lines = { "new content" }, text = "new content\n", identity = "untracked" }
    local file = model.parse({
      id = "untracked",
      path = "new.lua",
      status = "?",
      untracked = true,
      patch = "@@ -0,0 +1 @@\n+new content\n",
      _new_source = source,
    })
    local policy = cache.new(0)
    H.ok(policy:measure(file) >= #source.text)
    local before = addresses(file, "unified")
    local stats = policy:prune({ file })
    H.eq(1, stats.evicted)
    H.eq(0, stats.retained_bytes)
    H.eq(nil, file.meta._new_source)
    H.eq(before, addresses(file, "unified"))
  end,

  accounting_reuses_shared_arrays_and_updates_after_publication = function()
    local file = fixture("accounting")
    local policy = cache.new()
    local original = policy:measure(file)
    H.eq(original, policy:measure(file))
    -- Hydration uses separate list tables. Aliasing those lists should drop their
    -- array overhead while retaining all original source text/string accounting.
    file.old_source, file.new_source = file.sources.old.lines, file.sources.new.lines
    local shared = policy:measure(file)
    H.ok(shared < original)
    file.syntax = { old = { [2] = { { 0, 3, "@keyword", 100 } } }, new = {} }
    H.ok(policy:measure(file) > shared)
    local stats = policy:prune({ file, file })
    H.eq(policy:measure(file), stats.retained_bytes, "duplicate view references count one file")
    H.eq(0, stats.evicted)
  end,

  empty_or_zero_expansion_does_not_pin_unused_sources = function()
    local file = fixture("zero")
    H.ok(model.expand(file, "gap:1", "top", 0))
    H.eq(1, cache.new(0):prune({ file }).evicted)
  end,
}
