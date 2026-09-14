--- Owns Git processes and immutable comparison endpoints for review documents.
--- Git's NUL records supply paths/OIDs; presentation headers never become source
--- coordinates. Each request owns its jobs/read handles and suppresses late replies.
local M = {}
local uv = vim.uv

local DEFAULTS = {
  mode = "working",
  max_file_bytes = 1024 * 1024,
  max_changed_lines = 20000,
  max_source_lines = 100000,
  max_patch_bytes = 16 * 1024 * 1024,
  max_metadata_bytes = 16 * 1024 * 1024,
  timeout = 30000,
}

local function defaults(opts)
  return vim.tbl_extend("force", DEFAULTS, opts or {})
end

--- Async ownership belongs to the public request, including nested Git/file reads.
--- Cancellation closes descriptors and kills children; scheduled callbacks check
--- ownership again because a refresh may cancel after the OS operation finishes.
local function scope(callback)
  local self = { cancelled = false, completed = false, jobs = {}, cleanups = {} }

  function self:cancel()
    if self.cancelled then
      return
    end
    self.cancelled = true
    for job in pairs(self.jobs) do
      pcall(job.kill, job, 15)
    end
    for cleanup in pairs(self.cleanups) do
      cleanup()
    end
    self.cleanups = {}
  end

  function self:deliver(fn, ...)
    local args = { ... }
    local count = select("#", ...)
    vim.schedule(function()
      if not self.cancelled then
        fn(unpack(args, 1, count))
      end
    end)
  end

  function self:finish(err, result)
    if self.completed or self.cancelled then
      return
    end
    self.completed = true
    self:deliver(callback, err, result)
  end

  function self:run(root, args, opts, done)
    if self.cancelled then
      return
    end
    opts = opts or {}
    local command = {
      "git",
      "--no-pager",
      "--literal-pathspecs",
      "-c",
      "core.quotePath=true",
      "-c",
      "diff.suppressBlankEmpty=false",
    }
    vim.list_extend(command, args)
    local chunks, size, stderr, stderr_size = {}, 0, {}, 0
    local failure, job
    local function abort(message)
      if failure then
        return
      end
      failure = message
      if job then
        pcall(job.kill, job, 15)
      end
    end
    local ok, result = pcall(vim.system, command, {
      cwd = root,
      text = false, -- Source and patch CRLF/EOF bytes are part of the snapshot.
      stdin = opts.stdin,
      timeout = opts.timeout or DEFAULTS.timeout,
      env = { GIT_OPTIONAL_LOCKS = "0", LC_ALL = "C" },
      stdout = function(err, data)
        if self.cancelled or failure then
          return
        end
        if err then
          abort(tostring(err))
          return
        end
        if not data then
          return
        end
        if opts.sink then
          local parsed, message = pcall(opts.sink, data)
          if not parsed then
            abort(tostring(message))
          end
        else
          size = size + #data
          if size > (opts.limit or DEFAULTS.max_metadata_bytes) then
            abort("Git output exceeds the configured byte limit")
          else
            chunks[#chunks + 1] = data
          end
        end
      end,
      stderr = function(_, data)
        if data and stderr_size < 16384 then
          stderr[#stderr + 1] = data:sub(1, 16384 - stderr_size)
          stderr_size = stderr_size + #data
        end
      end,
    }, function(out)
      if job then
        self.jobs[job] = nil
      end
      if self.cancelled then
        return
      end
      local message = table.concat(stderr):gsub("\n$", "")
      local err = failure
      if not err and out.code ~= 0 then
        err = message ~= "" and message or ("Git exited with status " .. out.code)
      end
      self:deliver(done, err, table.concat(chunks), out)
    end)
    if not ok then
      self:deliver(done, tostring(result))
    else
      job = result
      self.jobs[job] = true
    end
  end

  return self
end

local function token(data, position)
  local ending = assert(data:find("\0", position, true), "Incomplete NUL-delimited Git metadata")
  return data:sub(position, ending - 1), ending + 1
end

-- Match Git's quote_c_style with core.quotePath=true. Header lookup is derived
-- from authoritative NUL paths, so spaces/newlines/Unicode cannot redirect a file.
local function quote_path(path)
  if not path:find('[%z\1-\31\127-\255"\\]') then
    return path
  end
  local escapes = {
    [7] = "\\a",
    [8] = "\\b",
    [9] = "\\t",
    [10] = "\\n",
    [11] = "\\v",
    [12] = "\\f",
    [13] = "\\r",
    [34] = '\\"',
    [92] = "\\\\",
  }
  local parts = { '"' }
  for i = 1, #path do
    local byte = path:byte(i)
    parts[#parts + 1] = escapes[byte]
      or ((byte < 32 or byte >= 127) and ("\\%03o"):format(byte) or path:sub(i, i))
  end
  parts[#parts + 1] = '"'
  return table.concat(parts)
end

local function header(meta)
  return "diff --git "
    .. quote_path("a/" .. (meta.old_path or meta.path))
    .. " "
    .. quote_path("b/" .. meta.path)
end

local function parse_metadata(data, options)
  local files, by_path, position = {}, {}, 1
  while data:sub(position, position) == ":" do
    local raw
    raw, position = token(data, position)
    local old_mode, new_mode, old_oid, new_oid, status = raw:match("^:(%d+) (%d+) (%x+) (%x+) (%S+)$")
    local parents = raw:match("^(:+)")
    if parents and #parents > 1 then
      -- With --patch, an unresolved index is reported as combined raw data:
      -- one mode/OID per parent plus the worktree result, followed by one path.
      -- It is still one visible conflict, not a two-way source projection.
      local fields = {}
      for field in raw:sub(#parents + 1):gmatch("%S+") do
        fields[#fields + 1] = field
      end
      old_mode, new_mode = fields[1], fields[#parents + 1]
      old_oid, new_oid = fields[#parents + 2], fields[#parents * 2 + 2]
      status = "U"
    end
    assert(status, "Unsupported Git raw metadata: " .. raw)
    local path, old_path
    path, position = token(data, position)
    if status:sub(1, 1) == "R" or status:sub(1, 1) == "C" then
      old_path = path
      path, position = token(data, position)
    end
    local meta = {
      id = path,
      path = path,
      old_path = old_path,
      status = status:sub(1, 1),
      score = tonumber(status:sub(2)),
      old_mode = old_mode,
      new_mode = new_mode,
      old_oid = old_oid,
      new_oid = new_oid,
      additions = 0,
      deletions = 0,
      patch = "",
    }
    -- Unmerged paths can appear twice (U and M). Keep one explicitly unresolved
    -- entry; stage-0 source coordinates do not exist until the conflict is fixed.
    if not by_path[path] then
      files[#files + 1] = meta
      by_path[path] = meta
    elseif meta.status == "U" then
      by_path[path].status = "U"
    end
  end
  while position <= #data do
    local stat
    stat, position = token(data, position)
    if stat ~= "" then
      local added, removed, path = stat:match("^([^\t]+)\t([^\t]+)\t(.*)$")
      assert(path, "Unsupported Git numstat metadata")
      if path == "" then
        local ignored
        ignored, position = token(data, position)
        path, position = token(data, position)
      end
      local meta = by_path[path]
      if meta then
        meta.binary = added == "-" or removed == "-"
        meta.additions = tonumber(added) or 0
        meta.deletions = tonumber(removed) or 0
      end
    end
  end
  local by_header = {}
  for _, meta in ipairs(files) do
    if meta.status == "U" then
      meta.omitted_reason = "Unmerged index entry; resolve the conflict and refresh"
    elseif meta.old_mode == "160000" or meta.new_mode == "160000" then
      meta.submodule = true
      meta.omitted_reason = "Submodule change"
    elseif meta.status == "T" then
      -- Git emits separate deletion/addition patch sections for a type change.
      -- Showing just one would invent a partial two-way source mapping.
      meta.omitted_reason = "File type changed (" .. meta.old_mode .. " → " .. meta.new_mode .. ")"
    elseif meta.binary then
      meta.omitted_reason = "Binary file"
    elseif meta.additions + meta.deletions > options.max_changed_lines then
      meta.omitted_reason = "Change exceeds max_changed_lines (" .. options.max_changed_lines .. ")"
    end
    by_header[header(meta)] = meta
    by_header["diff --cc " .. quote_path(meta.path)] = meta
    by_header["diff --combined " .. quote_path(meta.path)] = meta
  end
  return files, by_header
end

--- A streaming capture keeps huge changed lines outside Neovim's retained heap.
--- Git emits all NUL metadata before patch sections. Each section is captured only
--- within per-file/total budgets; skipped sections are drained so later files stay
--- reviewable. A short boundary tail also handles headers split across OS chunks.
local function diff_stream(options)
  local state = { files = {}, bytes = 0 }
  local pending, phase, by_header = "", "metadata", {}
  local current, parts, current_bytes = nil, {}, 0

  local function append(data)
    if not current or current.omitted_reason then
      return
    end
    local reason
    if data:find("\0", 1, true) then
      -- Attributes can force Git to treat a NUL-containing blob as text. Scratch
      -- buffers still require text, so explicit binary handling wins here.
      current.binary = true
      reason = "Binary file"
    elseif current_bytes + #data > options.max_file_bytes then
      reason = "Patch exceeds max_file_bytes (" .. options.max_file_bytes .. ")"
    elseif state.bytes + #data > options.max_patch_bytes then
      reason = "Review exceeds max_patch_bytes (" .. options.max_patch_bytes .. ")"
    end
    if reason then
      current.omitted_reason = reason
      state.bytes = state.bytes - current_bytes
      parts, current_bytes = {}, 0
      return
    end
    parts[#parts + 1] = data
    current_bytes = current_bytes + #data
    state.bytes = state.bytes + #data
  end

  local function finish_file()
    if current then
      current.patch = table.concat(parts)
    end
    current, parts, current_bytes = nil, {}, 0
  end

  function state.feed(data)
    pending = pending .. data
    while true do
      if phase == "metadata" then
        local boundary = pending:find("\0\0", 1, true)
        if not boundary then
          assert(#pending <= options.max_metadata_bytes, "Git metadata exceeds max_metadata_bytes")
          return
        end
        assert(boundary <= options.max_metadata_bytes, "Git metadata exceeds max_metadata_bytes")
        state.files, by_header = parse_metadata(pending:sub(1, boundary), options)
        pending = pending:sub(boundary + 2)
        phase = "header"
      elseif phase == "header" then
        local ending = pending:find("\n", 1, true)
        if not ending then
          assert(#pending <= 32768, "Git patch header exceeds path limit")
          return
        end
        local first = pending:sub(1, ending - 1)
        current = by_header[first]
        if current then
          current._seen_patch = true
        end
        append(pending:sub(1, ending))
        pending = pending:sub(ending + 1)
        phase = "body"
      else
        local boundary = pending:find("\ndiff --", 1, true)
        if boundary then
          append(pending:sub(1, boundary))
          pending = pending:sub(boundary + 1)
          finish_file()
          phase = "header"
        else
          -- Keep enough bytes to recognize a section marker cut across chunks.
          local amount = math.max(0, #pending - 12)
          append(pending:sub(1, amount))
          pending = pending:sub(amount + 1)
          return
        end
      end
    end
  end

  function state.finish()
    if phase == "metadata" then
      assert(pending == "", "Git output ended before patch metadata was complete")
    elseif phase == "body" then
      append(pending)
      finish_file()
    elseif pending ~= "" then
      error("Git output ended in a patch header")
    end
    for _, meta in ipairs(state.files) do
      if not meta._seen_patch and not meta.omitted_reason then
        meta.omitted_reason = "Patch unavailable; refresh the comparison"
      end
      meta._seen_patch = nil
    end
    return state.files
  end

  return state
end

local function resolve(owner, root, ref, options, done)
  owner:run(
    root,
    { "rev-parse", "--verify", "--quiet", "--end-of-options", ref .. "^{commit}" },
    options,
    function(err, out)
      done(err, not err and out:gsub("\n$", "") or nil)
    end
  )
end

local function endpoint(kind, rev, label)
  return { kind = kind, rev = rev, label = label or rev or kind }
end

local function endpoints(owner, root, options, done)
  local mode = options.mode
  local function empty(callback)
    owner:run(
      root,
      { "hash-object", "-t", "tree", "--stdin" },
      { stdin = "", timeout = options.timeout },
      function(err, out)
        callback(err, not err and endpoint("empty", out:gsub("\n$", ""), "empty tree") or nil)
      end
    )
  end
  local function head_or_empty(callback)
    resolve(owner, root, "HEAD", options, function(err, oid)
      if oid then
        callback(nil, endpoint("commit", oid, "HEAD"))
      else
        -- Only the normal unborn-HEAD result becomes an empty tree. Process or
        -- repository errors must remain visible rather than looking like adds.
        owner:run(root, { "symbolic-ref", "--quiet", "HEAD" }, options, function(sym_err)
          if sym_err then
            callback(err)
          else
            empty(callback)
          end
        end)
      end
    end)
  end
  if mode == "working" or mode == "staged" then
    head_or_empty(function(err, left)
      done(err, left, endpoint(mode == "staged" and "index" or "worktree"))
    end)
  elseif mode == "unstaged" then
    done(nil, endpoint("index"), endpoint("worktree"))
  elseif mode == "commit" then
    local ref = options.rev or options.head or "HEAD"
    resolve(owner, root, ref, options, function(err, oid)
      if err then
        done(err)
        return
      end
      owner:run(root, { "rev-list", "--parents", "-n", "1", oid }, options, function(parent_err, output)
        if parent_err then
          done(parent_err)
          return
        end
        local parent = output:match("^%x+ (%x+)")
        local right = endpoint("commit", oid, ref)
        if parent then
          done(nil, endpoint("commit", parent, ref .. "^"), right)
        else
          empty(function(empty_err, left)
            done(empty_err, left, right)
          end)
        end
      end)
    end)
  elseif mode == "range" or mode == "branch" then
    local head = options.head or options.rev or "HEAD"
    resolve(owner, root, head, options, function(head_err, head_oid)
      if head_err then
        done(head_err)
        return
      end
      local function with_base(base)
        resolve(owner, root, base, options, function(base_err, base_oid)
          if base_err then
            if mode == "range" and options.merge_base ~= true then
              -- Inclusive ranges beginning at a root commit have an empty-tree
              -- base. Compute it for this repository's hash algorithm, without
              -- writing a Git object or treating arbitrary invalid refs as empty.
              empty(function(empty_err, left)
                if not empty_err and base == left.rev then
                  done(nil, left, endpoint("commit", head_oid, head))
                else
                  done(base_err)
                end
              end)
            else
              done(base_err)
            end
            return
          end
          local right = endpoint("commit", head_oid, head)
          if options.merge_base == true or (mode == "branch" and options.merge_base ~= false) then
            owner:run(root, { "merge-base", base_oid, head_oid }, options, function(merge_err, output)
              done(
                merge_err,
                not merge_err
                    and endpoint(
                      "commit",
                      output:gsub("\n$", ""),
                      "merge-base(" .. base .. ", " .. head .. ")"
                    )
                  or nil,
                right
              )
            end)
          else
            done(nil, endpoint("commit", base_oid, base), right)
          end
        end)
      end
      if options.base then
        with_base(options.base)
      elseif mode == "range" then
        done("Range comparisons require a base revision")
      else
        owner:run(
          root,
          { "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" },
          options,
          function(origin_err, output)
            if not origin_err then
              with_base(output:gsub("\n$", ""))
              return
            end
            resolve(owner, root, "refs/heads/main", options, function(main_err)
              if not main_err then
                with_base("main")
                return
              end
              resolve(owner, root, "refs/heads/master", options, function(master_err)
                if not master_err then
                  with_base("master")
                else
                  done("No default branch found; provide a base revision")
                end
              end)
            end)
          end
        )
      end
    end)
  else
    done("Unknown comparison mode: " .. tostring(mode))
  end
end

local function diff_args(snapshot)
  local args = {
    "diff",
    "--raw",
    "--numstat",
    "--patch",
    "-z",
    "--no-abbrev",
    "--full-index",
    "--no-ext-diff",
    "--no-textconv",
    "--no-color",
    "--no-relative",
    "--find-renames",
    "--ignore-submodules=none",
    "--submodule=short",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    "--output-indicator-new=+",
    "--output-indicator-old=-",
    "--output-indicator-context= ",
    "--unified=3",
    "--inter-hunk-context=0",
    "--diff-algorithm=histogram",
  }
  local left, right = snapshot.left, snapshot.right
  if right.kind == "index" then
    args[#args + 1] = "--cached"
  end
  if left.kind ~= "index" then
    args[#args + 1] = left.rev
  end
  if right.kind == "commit" then
    args[#args + 1] = right.rev
  end
  args[#args + 1] = "--"
  vim.list_extend(args, snapshot.options.paths or {})
  return args
end

-- Regular worktree reads use a bounded asynchronous descriptor, never readfile()
-- or a shell command. Closing a session also closes the descriptor, including
-- the race where cancellation arrives before fs_open delivers its result.
local function read_file(owner, path, limit, callback)
  local fd, closed, chunks, offset = nil, false, {}, 0
  local cleanup
  cleanup = function()
    if closed then
      return
    end
    closed = true
    owner.cleanups[cleanup] = nil
    if fd then
      uv.fs_close(fd, function() end)
    end
  end
  local function finish(err, text)
    cleanup()
    owner:deliver(callback, err, text)
  end
  uv.fs_open(path, "r", 438, function(err, opened)
    if owner.cancelled then
      if opened then
        uv.fs_close(opened, function() end)
      end
      return
    end
    if err then
      owner:deliver(callback, err)
      return
    end
    fd = opened
    owner.cleanups[cleanup] = true
    uv.fs_fstat(fd, function(stat_err, stat)
      if owner.cancelled then
        return
      end
      if stat_err then
        finish(stat_err)
        return
      end
      if stat.type ~= "file" then
        finish("Source is no longer a regular file; refresh the comparison")
        return
      end
      if stat.size > limit then
        finish("Source exceeds max_file_bytes (" .. limit .. ")")
        return
      end
      local function read_next()
        if owner.cancelled then
          return
        end
        uv.fs_read(fd, math.min(65536, limit + 1 - offset), offset, function(read_err, data)
          if owner.cancelled then
            return
          end
          if read_err then
            finish(read_err)
            return
          end
          if not data or #data == 0 then
            finish(nil, table.concat(chunks))
            return
          end
          offset = offset + #data
          if offset > limit then
            finish("Source exceeds max_file_bytes (" .. limit .. ")")
            return
          end
          chunks[#chunks + 1] = data
          read_next()
        end)
      end
      read_next()
    end)
  end)
end

local function worktree_text(owner, path, mode, limit, callback)
  if mode == "120000" then
    -- A Git symlink blob contains the link target, not the dereferenced file.
    uv.fs_readlink(path, function(err, target)
      if target and #target > limit then
        err = "Source exceeds max_file_bytes (" .. limit .. ")"
      end
      owner:deliver(callback, err, target)
    end)
  else
    read_file(owner, path, limit, callback)
  end
end

local function source_value(text, identity, label, options)
  if text:find("\0", 1, true) then
    return nil, "Binary source cannot be expanded"
  end
  local _, newlines = text:gsub("\n", "")
  local count = newlines + ((#text > 0 and text:sub(-1) ~= "\n") and 1 or 0)
  if count > options.max_source_lines then
    return nil, "Source exceeds max_source_lines (" .. options.max_source_lines .. ")"
  end
  local lines = {}
  local start = 1
  while start <= #text do
    local ending = text:find("\n", start, true)
    local line = ending and text:sub(start, ending - 1) or text:sub(start)
    lines[#lines + 1] = line:gsub("\r$", "")
    if not ending then
      break
    end
    start = ending + 1
  end
  return {
    lines = lines,
    text = text,
    identity = identity or ("worktree:" .. vim.fn.sha256(text)),
    label = label,
    eol = #text > 0 and text:sub(-1) == "\n",
    crlf = text:find("\r\n", 1, true) ~= nil,
  }
end

local function untracked_patch(meta, text)
  local chunks = { header(meta), "\nnew file mode ", meta.new_mode, "\n" }
  if text ~= "" then
    local _, count = text:gsub("\n", "")
    if text:sub(-1) ~= "\n" then
      count = count + 1
    end
    vim.list_extend(
      chunks,
      { "--- /dev/null\n+++ ", quote_path("b/" .. meta.path), "\n@@ -0,0 +1,", tostring(count), " @@\n" }
    )
    local position = 1
    while position <= #text do
      local ending = text:find("\n", position, true)
      if ending then
        chunks[#chunks + 1] = "+" .. text:sub(position, ending)
        position = ending + 1
      else
        chunks[#chunks + 1] = "+" .. text:sub(position) .. "\n\\ No newline at end of file\n"
        break
      end
    end
  end
  return table.concat(chunks)
end

local function load_untracked(owner, snapshot, retained_bytes, callback)
  local args = { "ls-files", "--others", "--exclude-standard", "-z", "--" }
  vim.list_extend(args, snapshot.options.paths or {})
  owner:run(
    snapshot.root,
    args,
    { timeout = snapshot.options.timeout, limit = snapshot.options.max_metadata_bytes },
    function(err, output)
      if err then
        callback(err)
        return
      end
      local paths, position = {}, 1
      local tracked = {}
      for _, meta in ipairs(snapshot.files) do
        tracked[meta.path] = true
      end
      while position <= #output do
        local path
        path, position = token(output, position)
        if not tracked[path] then
          paths[#paths + 1] = path
        end
      end
      local next_index, active, finished, entries = 1, 0, 0, {}
      local pump
      local function complete(index, meta)
        entries[index] = meta
        active, finished = active - 1, finished + 1
        if finished == #paths then
          vim.list_extend(snapshot.files, entries)
          callback()
        else
          pump()
        end
      end
      pump = function()
        if owner.cancelled then
          return
        end
        while active < 4 and next_index <= #paths do
          local index = next_index
          next_index, active = next_index + 1, active + 1
          local path = paths[index]
          local meta = {
            id = path,
            path = path,
            status = "?",
            untracked = true,
            additions = 0,
            deletions = 0,
            old_mode = "000000",
            new_mode = "100644",
            patch = "",
          }
          uv.fs_lstat(snapshot.root .. "/" .. path, function(stat_err, stat)
            owner:deliver(function()
              if stat_err then
                meta.omitted_reason = "Unable to read untracked file: " .. stat_err
                complete(index, meta)
                return
              end
              if stat.type == "link" then
                meta.new_mode = "120000"
              elseif stat.type ~= "file" then
                meta.omitted_reason = "Untracked directory or special file"
                complete(index, meta)
                return
              elseif bit.band(stat.mode, 73) ~= 0 then
                meta.new_mode = "100755"
              end
              worktree_text(
                owner,
                snapshot.root .. "/" .. path,
                meta.new_mode,
                snapshot.options.max_file_bytes,
                function(read_err, text)
                  if read_err then
                    meta.omitted_reason = read_err
                    complete(index, meta)
                    return
                  end
                  if text:find("\0", 1, true) then
                    meta.binary = true
                    meta.omitted_reason = "Binary file"
                    complete(index, meta)
                    return
                  end
                  local _, count = text:gsub("\n", "")
                  meta.additions = count + ((#text > 0 and text:sub(-1) ~= "\n") and 1 or 0)
                  if meta.additions > snapshot.options.max_changed_lines then
                    meta.omitted_reason = "Change exceeds max_changed_lines ("
                      .. snapshot.options.max_changed_lines
                      .. ")"
                  else
                    local patch = untracked_patch(meta, text)
                    if retained_bytes + #patch > snapshot.options.max_patch_bytes then
                      meta.omitted_reason = "Review exceeds max_patch_bytes ("
                        .. snapshot.options.max_patch_bytes
                        .. ")"
                    else
                      local value, source_err =
                        source_value(text, nil, path .. " (untracked)", snapshot.options)
                      if source_err then
                        meta.omitted_reason = source_err
                      else
                        meta.patch, meta._new_source = patch, value
                        retained_bytes = retained_bytes + #patch
                      end
                    end
                  end
                  complete(index, meta)
                end
              )
            end)
          end)
        end
      end
      if #paths == 0 then
        callback()
      else
        pump()
      end
    end
  )
end

--- Load one comparison without moving refs, touching the index, or opening buffers.
--- Returned commit endpoints and index blob IDs stay pinned even if Git changes
--- afterward. Worktree sources are mutable and must pass model hydration checks.
function M.load(opts, callback)
  local owner = scope(callback)
  local options = defaults(opts)
  local cwd = options.cwd or uv.cwd()
  owner:run(cwd, { "rev-parse", "--show-toplevel" }, options, function(root_err, output)
    if root_err then
      owner:finish(root_err)
      return
    end
    local root = output:gsub("\n$", "")
    endpoints(owner, root, options, function(endpoint_err, left, right)
      if endpoint_err then
        owner:finish(endpoint_err)
        return
      end
      local snapshot = {
        root = root,
        label = left.label .. " → " .. right.label,
        left = left,
        right = right,
        files = {},
        options = options,
      }
      local stream = diff_stream(options)
      owner:run(
        root,
        diff_args(snapshot),
        { sink = stream.feed, timeout = options.timeout },
        function(diff_err)
          if diff_err then
            owner:finish(diff_err)
            return
          end
          local ok, result = pcall(stream.finish)
          if not ok then
            owner:finish(tostring(result))
            return
          end
          snapshot.files = result
          local function ready(err)
            if not err then
              table.sort(snapshot.files, function(a, b)
                return a.path < b.path
              end)
            end
            owner:finish(err, not err and snapshot or nil)
          end
          if right.kind == "worktree" then
            load_untracked(owner, snapshot, stream.bytes, ready)
          else
            ready()
          end
        end
      )
    end)
  end)
  return function()
    owner:cancel()
  end
end

--- Read one side at its true source identity. An absent side is a real empty
--- source, while omitted/binary/conflicted entries intentionally have no source.
function M.source(snapshot, meta, side, callback)
  local owner = scope(callback)
  local options = defaults(snapshot.options)
  if side ~= "old" and side ~= "new" then
    owner:finish("Source side must be 'old' or 'new'")
    return function()
      owner:cancel()
    end
  end
  local old = side == "old"
  local source_endpoint = old and snapshot.left or snapshot.right
  local mode = old and meta.old_mode or meta.new_mode
  local path = old and (meta.old_path or meta.path) or meta.path
  local absent = mode == "000000"
    or source_endpoint.kind == "empty"
    or (old and (meta.status == "A" or meta.untracked))
    or (not old and meta.status == "D")
  if absent then
    owner:finish(
      nil,
      { lines = {}, text = "", identity = "empty", label = "absent", eol = false, crlf = false }
    )
  elseif meta.omitted_reason then
    owner:finish(meta.omitted_reason)
  elseif not old and meta._new_source then
    owner:finish(nil, meta._new_source)
  else
    local function received(err, text, identity)
      if err then
        owner:finish(err)
        return
      end
      if #text > options.max_file_bytes then
        owner:finish("Source exceeds max_file_bytes (" .. options.max_file_bytes .. ")")
        return
      end
      local value, source_err =
        source_value(text, identity, path .. " (" .. source_endpoint.label .. ")", options)
      owner:finish(source_err, value)
    end
    if source_endpoint.kind == "worktree" then
      worktree_text(owner, snapshot.root .. "/" .. path, mode, options.max_file_bytes, received)
    else
      local oid = old and meta.old_oid or meta.new_oid
      if not oid or oid:match("^0+$") then
        owner:finish("No pinned blob is available; refresh the comparison")
      else
        owner:run(
          snapshot.root,
          { "cat-file", "blob", oid },
          { limit = options.max_file_bytes, timeout = options.timeout },
          function(err, text)
            received(err, text, "blob:" .. oid)
          end
        )
      end
    end
  end
  return function()
    owner:cancel()
  end
end

return M
