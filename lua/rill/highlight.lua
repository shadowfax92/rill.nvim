-- Syntax belongs to the two source snapshots, not to the synthetic review buffer.
-- Cache source-coordinate captures once; the view projects only visible captures
-- during redraw. Missing parsers and expensive files keep readable plain text.
local M = {}

local function color(name, field, fallback)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and value[field] or fallback
end

local function mix(a, b, amount)
  local value = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local x, y = math.floor(a / 2 ^ shift) % 256, math.floor(b / 2 ^ shift) % 256
    value = value + math.floor(x + (y - x) * amount + 0.5) * 2 ^ shift
  end
  return value
end

function M.colors()
  local bg = color("Normal", "bg", vim.o.background == "light" and 0xfaf9f5 or 0x242424)
  local fg = color("Normal", "fg", 0xd4c7aa)
  local muted = color("Comment", "fg", 0x928374)
  local add = color("DiagnosticOk", "fg", 0x8cab70)
  local del = color("DiagnosticError", "fg", 0xe27878)
  local defs = {
    RillAdd = { bg = mix(bg, add, 0.13) },
    RillDelete = { bg = mix(bg, del, 0.13) },
    RillAddText = { bg = mix(bg, add, 0.32), bold = true },
    RillDeleteText = { bg = mix(bg, del, 0.32), bold = true },
    RillAddSign = { fg = add },
    RillDeleteSign = { fg = del },
    RillHeader = { fg = fg, bg = mix(bg, fg, 0.12), bold = true },
    RillBarKey = { fg = fg, bg = color("WinBar", "bg", bg), bold = true },
    RillBarHint = { fg = muted, bg = color("WinBar", "bg", bg) },
    RillGap = { fg = muted, bg = mix(bg, fg, 0.025) },
    RillMuted = { fg = muted },
    RillNumber = { fg = muted },
    RillPadding = { bg = mix(bg, fg, 0.025) },
    RillTreeCurrent = { fg = fg, bg = mix(bg, fg, 0.10), bold = true },
  }
  for name, attrs in pairs(defs) do
    vim.api.nvim_set_hl(0, name, attrs)
  end
end

-- Jobs coalesce callers and settle callbacks even when decoration is unavailable.
-- Their generation belongs to the immutable file snapshot; disposal invalidates
-- every scheduled continuation before destroying parser resources.
local function begin(file, kind, done)
  if file.disposed or file[kind] then
    if done then
      vim.schedule(function()
        done(file.disposed and "cancelled" or nil)
      end)
    end
    return
  end
  file._highlight_jobs = file._highlight_jobs or {}
  local existing = file._highlight_jobs[kind]
  if existing then
    if done then
      existing.callbacks[#existing.callbacks + 1] = done
    end
    return
  end
  local job = { active = true, callbacks = done and { done } or {}, timers = {} }
  file._highlight_jobs[kind], file[kind .. "_loading"] = job, true
  function job.finish(err, marks)
    if not job.active then
      return
    end
    job.active = false
    -- Deferred workers retain their coroutine and source snapshot until their
    -- timer closes. Cancel these handles when their owning file is disposed.
    for timer in pairs(job.timers) do
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    job.timers = {}
    file._highlight_jobs[kind], file[kind .. "_loading"] = nil, false
    if not file.disposed and marks then
      file[kind] = marks
    end
    local callbacks = job.callbacks
    job.callbacks = {}
    for _, callback in ipairs(callbacks) do
      vim.schedule(function()
        callback(err)
      end)
    end
  end
  return job
end

-- Tree-sitter's asynchronous parser yields, but query iteration does not. Run
-- Lua capture traversal and multi-line expansion in resumable 4ms/1024-item chunks.
-- Chaining vim.schedule() drains the entire queue before timers or input run;
-- each continuation must cross a real timer turn to make those chunks cooperative.
local function batched(job, work, finished)
  local deadline, steps
  local function checkpoint()
    steps = steps + 1
    if steps >= 1024 or vim.uv.hrtime() >= deadline then
      coroutine.yield()
    end
  end
  local thread = coroutine.create(function()
    return work(checkpoint)
  end)
  local function step()
    if not job.active then
      return
    end
    deadline, steps = vim.uv.hrtime() + 4000000, 0
    local ok, result = coroutine.resume(thread)
    if not ok then
      finished(nil, result)
    elseif coroutine.status(thread) == "dead" then
      finished(result)
    else
      local timer
      timer = vim.defer_fn(function()
        job.timers[timer] = nil
        step()
      end, 1)
      job.timers[timer] = true
    end
  end
  vim.schedule(step)
end

-- Character diffs are bounded, and offsets are converted back to bytes before
-- reaching extmarks. A UTF-8 character must never be cut at a continuation byte.
local function characters(text)
  local parts = vim.fn.split(text, "\\zs")
  local offsets = { 0 }
  for _, part in ipairs(parts) do
    offsets[#offsets + 1] = offsets[#offsets] + #part
  end
  -- An empty string must stay empty: a synthetic blank character would produce
  -- an invalid offset for a replacement between empty and nonempty source lines.
  return #parts > 0 and table.concat(parts, "\n") .. "\n" or "", offsets
end

local function word_ranges(old, new)
  if old == new or #old > 1000 or #new > 1000 then
    return {}, {}
  end
  local a, ao = characters(old)
  local b, bo = characters(new)
  local ok, changes = pcall(vim.diff, a, b, { result_type = "indices", algorithm = "histogram" })
  if not ok then
    return {}, {}
  end
  local left, right = {}, {}
  for _, hunk in ipairs(changes) do
    if hunk[2] > 0 then
      left[#left + 1] = { ao[hunk[1]], ao[hunk[1] + hunk[2]] }
    end
    if hunk[4] > 0 then
      right[#right + 1] = { bo[hunk[3]], bo[hunk[3] + hunk[4]] }
    end
  end
  return left, right
end

function M.words(file, done)
  local job = begin(file, "words", done)
  if not job then
    return
  end
  batched(job, function(checkpoint)
    local marks = { old = {}, new = {} }
    -- Match the split projection's ordinal pairing within each changed run,
    -- without materializing expanded context or another complete review layout.
    for _, hunk in ipairs(file.hunks or {}) do
      local old, new = {}, {}
      local function flush()
        for i = 1, math.min(#old, #new) do
          marks.old[old[i].line], marks.new[new[i].line] = word_ranges(old[i].text, new[i].text)
          checkpoint()
        end
        old, new = {}, {}
      end
      for _, row in ipairs(hunk.rows) do
        if row.change == "context" then
          flush()
        else
          if row.old then
            old[#old + 1] = row.old
          end
          if row.new then
            new[#new + 1] = row.new
          end
        end
        checkpoint()
      end
      flush()
    end
    return marks
  end, function(marks)
    job.finish(nil, marks or { old = {}, new = {} })
  end)
end

-- Default syntax coverage matches readable Git sources. Capture indexing stays
-- cooperative; Neovim's native parse can still take longer on large files. Users
-- who prefer stricter latency can lower these limits without changing Git reads.
local MAX_SOURCE_LINES, MAX_SOURCE_BYTES, MAX_SPANS = 100000, 1024 * 1024, 100000

local function release(file, parser)
  if not parser then
    return
  end
  for i, owned in ipairs(file.parsers or {}) do
    if owned == parser then
      table.remove(file.parsers, i)
      break
    end
  end
  pcall(function()
    parser:destroy()
  end)
end

local function captures(parser, source, lines, checkpoint)
  local marks, count, exhausted = {}, 0, false
  parser:for_each_tree(function(tree, language_tree)
    if exhausted then
      return
    end
    local lang = language_tree:lang()
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      return
    end
    for id, node, metadata in query:iter_captures(tree:root(), source) do
      local name = query.captures[id]
      if name ~= "spell" and name ~= "nospell" and name ~= "conceal" and name:sub(1, 1) ~= "_" then
        local capture = metadata[id] or {}
        -- Offset directives belong to this capture. get_node_range understands
        -- both four- and six-field ranges; unpacking six fields misreads bytes
        -- as source rows. Follow Neovim's precedence for pattern-level priority.
        local sr, sc, er, ec = vim.treesitter.get_node_range(capture.range or node)
        local priority = tonumber(metadata.priority or capture.priority) or 100
        priority = math.max(0, math.min(65535, priority))
        for row = math.max(0, sr), math.min(er, #lines - 1) do
          local length = #lines[row + 1]
          local first = math.max(0, math.min(row == sr and sc or 0, length))
          local last = math.max(0, math.min(row == er and ec or length, length))
          if last > first then
            count = count + 1
            if count > MAX_SPANS then
              exhausted = true
              return
            end
            local spans = marks[row + 1] or {}
            spans[#spans + 1] = { first, last, "@" .. name .. "." .. lang, priority }
            marks[row + 1] = spans
          end
          checkpoint()
        end
      end
      checkpoint()
    end
  end)
  return exhausted and {} or marks
end

function M.syntax(file, done)
  local job = begin(file, "syntax", done)
  if not job then
    return
  end
  local result, pending = { old = {}, new = {} }, 2
  local limits = file.syntax_limits or {}
  local max_lines, max_bytes = limits.max_lines or MAX_SOURCE_LINES, limits.max_bytes or MAX_SOURCE_BYTES
  file.parsers = {}
  local function finished(side, marks, parser)
    if not job.active then
      return
    end
    release(file, parser)
    result[side] = marks or {}
    pending = pending - 1
    if pending == 0 then
      job.finish(nil, result)
    end
  end
  for _, side in ipairs({ "old", "new" }) do
    -- A rename can also change language. Each side is parsed as its own filename
    -- and full source, never as the concatenated synthetic diff document.
    local path = side == "old" and file.meta.old_path or file.meta.path
    local ft = vim.filetype.match({ filename = path or file.meta.path })
    local lang = ft and vim.treesitter.language.get_lang(ft)
    local original = file[side .. "_source"] or {}
    if not lang or #original == 0 or #original > max_lines then
      finished(side)
    else
      batched(job, function(checkpoint)
        local normalized, bytes = {}, 0
        for i, line in ipairs(original) do
          normalized[i] = line:gsub("\r$", "")
          bytes = bytes + #normalized[i] + 1
          if bytes > max_bytes then
            return
          end
          checkpoint()
        end
        return { source = table.concat(normalized, "\n"), lines = normalized }
      end, function(prepared)
        if not prepared then
          finished(side)
          return
        end
        local ok, parser = pcall(vim.treesitter.get_string_parser, prepared.source, lang)
        if not ok then
          finished(side)
          return
        end
        file.parsers[#file.parsers + 1] = parser
        local settled = false
        local function on_parse(err)
          if settled or not job.active then
            return
          end
          settled = true
          if err then
            finished(side, nil, parser)
            return
          end
          batched(job, function(checkpoint)
            return captures(parser, prepared.source, prepared.lines, checkpoint)
          end, function(marks)
            finished(side, marks, parser)
          end)
        end
        local parsed, err = pcall(function()
          parser:parse(true, on_parse)
        end)
        if not parsed then
          on_parse(err)
        end
      end)
    end
  end
end

function M.dispose(file)
  file.disposed = true
  -- Collect before settling: finish removes its own entry from the jobs table.
  local jobs = {}
  for _, job in pairs(file._highlight_jobs or {}) do
    jobs[#jobs + 1] = job
  end
  for _, job in ipairs(jobs) do
    job.finish("cancelled")
  end
  for _, parser in ipairs(file.parsers or {}) do
    pcall(function()
      parser:destroy()
    end)
  end
  file.parsers, file.syntax, file.words = nil, nil, nil
  file.syntax_loading, file.words_loading = false, false
end

return M
