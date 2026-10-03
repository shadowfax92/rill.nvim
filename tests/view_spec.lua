local H = require("tests.helpers")
local api = vim.api
local view = require("rill.view")

local function fixture(root)
  local sources = {
    first = {
      old = {
        "first",
        "second",
        "third",
        "removed α",
        "removed extra",
        "same tail",
        "hidden a",
        "hidden b",
        "last",
      },
      new = { "first", "second", "third", "replacement β", "same tail", "hidden a", "hidden b", "last" },
    },
    second = { old = {}, new = { "first new", "last new" } },
  }
  local snapshot = {
    root = root,
    label = "main → worktree",
    left = { kind = "commit", rev = "deadbeef", label = "main" },
    right = { kind = "worktree", label = "worktree" },
    files = {
      {
        id = "first",
        path = "src/new name.lua",
        old_path = "src/old name.lua",
        status = "R",
        additions = 1,
        deletions = 2,
        patch = "@@ -4,3 +4,2 @@\n-removed α\n-removed extra\n+replacement β\n same tail\n",
      },
      {
        id = "second",
        path = "tests/new.lua",
        status = "A",
        additions = 2,
        deletions = 0,
        patch = "@@ -0,0 +1,2 @@\n+first new\n+last new\n",
      },
    },
  }
  for _, file in ipairs(snapshot.files) do
    H.write(root, file.path, sources[file.id].new)
  end
  return snapshot, sources
end

-- The composite snapshot rill.git returns for open_commits (decision §1c): one
-- group per commit in the given order, each with its own commit-mode snapshot,
-- and every meta tagged with its group and namespaced as oid:path. Commit 1 is
-- a root commit, commit 2 changes nothing, commit 3 is a merge that changes a
-- path commit 1 also touched, so that path appears twice with distinct ids.
local A, B, C = string.rep("a", 40), string.rep("b", 40), string.rep("c", 40)
local function commits_fixture(root)
  local sources = {
    [A .. ":src/a.lua"] = { old = {}, new = { "alpha", "beta" } },
    [A .. ":src/shared.lua"] = { old = {}, new = { "one" } },
    [C .. ":src/shared.lua"] = { old = { "one" }, new = { "two" } },
  }
  local function meta(oid, group, path, status, patch, additions, deletions)
    return {
      id = oid .. ":" .. path,
      group = group,
      path = path,
      status = status,
      additions = additions,
      deletions = deletions,
      patch = patch,
    }
  end
  local metas = {
    {
      meta(A, 1, "src/a.lua", "A", "@@ -0,0 +1,2 @@\n+alpha\n+beta\n", 2, 0),
      meta(A, 1, "src/shared.lua", "A", "@@ -0,0 +1 @@\n+one\n", 1, 0),
    },
    {},
    { meta(C, 3, "src/shared.lua", "M", "@@ -1 +1 @@\n-one\n+two\n", 1, 1) },
  }
  local function group(index, oid, fields, left)
    return vim.tbl_extend("force", {
      index = index,
      oid = oid,
      short = oid:sub(1, 8),
      author = "Ada",
      date = "03 Oct 2026",
      merge = #fields.parents > 1,
      root_commit = #fields.parents == 0,
      snapshot = {
        root = root,
        options = {},
        label = oid:sub(1, 8) .. "^ → " .. oid:sub(1, 8),
        left = left,
        right = { kind = "commit", rev = oid, label = oid },
        files = metas[index],
      },
    }, fields)
  end
  local groups = {
    group(
      1,
      A,
      { subject = "Add a", parents = {} },
      { kind = "empty", rev = "4b825dc6", label = "empty tree" }
    ),
    group(2, B, { subject = "Nothing", parents = { A } }, { kind = "commit", rev = A, label = B .. "^" }),
    group(
      3,
      C,
      { subject = "Merge side", parents = { B, "f00d" } },
      { kind = "commit", rev = B, label = C .. "^" }
    ),
  }
  local files = {}
  for _, list in ipairs(metas) do
    vim.list_extend(files, list)
  end
  return {
    root = root,
    options = {},
    label = "3 commits",
    left = groups[1].snapshot.left,
    right = groups[3].snapshot.right,
    groups = groups,
    files = files,
  },
    sources
end

-- The backend stub owns delivery timing, not view state. It deliberately allows
-- canceled completions through so tests exercise the session's generation guard.
local function backend(snapshot, sources, opts)
  local control = { loads = {}, reads = {} }
  function control.load(_, callback)
    local job = { callback = callback, canceled = false }
    control.loads[#control.loads + 1] = job
    if opts.auto_load ~= false then
      vim.schedule(function()
        callback(nil, snapshot)
      end)
    end
    return function()
      job.canceled = true
    end
  end
  function control.source(_, meta, side, callback)
    local job = { callback = callback, canceled = false, side = side, id = meta.id }
    control.reads[#control.reads + 1] = job
    local content = sources[meta.id][side]
    job.result =
      { lines = vim.deepcopy(content), text = table.concat(content, "\n"), identity = meta.id .. ":" .. side }
    if opts.auto_source ~= false then
      vim.schedule(function()
        callback(nil, job.result)
      end)
    end
    return function()
      job.canceled = true
    end
  end
  return control
end

local function with_review(fn, options)
  options = options or {}
  local previous_git, previous_notify = package.loaded["rill.git"], vim.notify
  local initial_buffers = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    initial_buffers[buf] = true
  end
  local origin_win, previous_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  -- Headless windows are narrow enough that the winbar sheds its title; cases
  -- asserting on titles widen the screen before the review lays out its panes.
  local previous_columns = vim.o.columns
  vim.o.columns = options.columns or previous_columns
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local snapshot, sources = (options.fixture or fixture)(root)
  local control = backend(snapshot, sources, options)
  package.loaded["rill.git"] = control
  local notifications = {}
  vim.notify = function(message)
    notifications[#notifications + 1] = message
  end
  local origin_buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "unsaved work", "keep me" })
  api.nvim_win_set_buf(origin_win, origin_buf)
  local session
  local ok, err = xpcall(function()
    session = view.open(vim.tbl_extend("force", {
      cwd = root,
      layout = "unified",
      tree_width = 30,
      context_step = 2,
      wrap = false,
      syntax = false,
      sidekick = false,
    }, options.view or {}))
    if options.auto_load ~= false then
      H.ok(
        vim.wait(1000, function()
          return session.snapshot ~= nil
        end, 1),
        "review did not load"
      )
    end
    fn(session, {
      root = root,
      snapshot = snapshot,
      sources = sources,
      control = control,
      origin_win = origin_win,
      origin_buf = origin_buf,
      notifications = notifications,
    })
  end, debug.traceback)
  if session then
    pcall(function()
      session:close()
    end)
  end
  if api.nvim_win_is_valid(origin_win) then
    api.nvim_set_current_win(origin_win)
    api.nvim_win_set_buf(origin_win, previous_buf)
  end
  -- Cleanup our test-owned source buffers after assertions; session-owned buffers
  -- must already have been released by close(), which its own cases verify.
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not initial_buffers[buf] and api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.wait(5, function()
    return false
  end, 1)
  package.loaded["rill.git"], vim.notify = previous_git, previous_notify
  vim.o.columns = previous_columns
  vim.fn.delete(root, "rf")
  if not ok then
    error(err, 0)
  end
end

local function find_row(session, predicate)
  for index, row in ipairs(session.rows) do
    if predicate(row) then
      return index, row
    end
  end
  error("expected review row not found")
end

local function at_source(session, side, line, file_id)
  return find_row(session, function(row)
    return row.file and row.file.meta.id == (file_id or "first") and row[side] and row[side].line == line
  end)
end

local function select(session, first, last, win, kind, from_col, to_col)
  win = win or session.main_win
  return view.context({
    win = win,
    buf = api.nvim_win_get_buf(win),
    row = first,
    col = 1,
    range = last and { from = { first, from_col or 0 }, to = { last, to_col or 999 }, kind = kind or "line" }
      or nil,
  })
end

local function span_locations(context)
  local result = {}
  for _, span in ipairs(context.spans) do
    result[#result + 1] = { span.path, span.side, span.revision, span.start_line, span.end_line, span.lines }
  end
  return result
end

local function place(session, side, line, file_id)
  local win = session.layout == "split" and side == "new" and session.right_win or session.main_win
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { at_source(session, side, line, file_id), 0 })
  session:cursor_changed(api.nvim_win_get_buf(win))
end

-- Invoke the review buffer's own mapping, as a keypress would.
local function press(key)
  local binding = vim.fn.maparg(key, "n", false, true)
  H.eq("function", type(binding.callback), "expected local action for " .. key)
  binding.callback()
end

local function buffer_lines(win)
  return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
end

local function eval_bar(win, field)
  return api.nvim_eval_statusline(vim.wo[win][field], {
    winid = win,
    use_winbar = field == "winbar",
    maxwidth = 400,
  }).str
end

-- Reload through the stub with a replacement snapshot delivered synchronously.
local function refresh(session, env, snapshot)
  session:load()
  env.control.loads[#env.control.loads].callback(nil, snapshot)
end

local function without_files(snapshot, keep)
  local copy = vim.deepcopy(snapshot)
  copy.files = vim.tbl_filter(function(meta)
    return vim.tbl_contains(keep, meta.id)
  end, copy.files)
  return copy
end

return {
  ["Tab cycles actual files in stream and focus while gs changes layout"] = function()
    with_review(function(session)
      place(session, "new", 4)
      local function press(key)
        local binding = vim.fn.maparg(key, "n", false, true)
        H.eq("function", type(binding.callback), "expected local action for " .. key)
        binding.callback()
      end
      press("<Tab>")
      H.eq("second", session:current().meta.id)
      H.eq("unified", session.layout)
      session:toggle_focus()
      press("<Tab>")
      H.eq("first", session.focus_id)
      press("<S-Tab>")
      H.eq("second", session.focus_id)
      press("gs")
      H.eq("split", session.layout)
      H.eq("second", session.focus_id)
      press("<Tab>")
      H.eq("first", session.focus_id)
    end)
  end,

  ["unified selections preserve old paths revisions and mixed source ranges"] = function()
    with_review(function(session, env)
      local first, last = at_source(session, "old", 4), at_source(session, "new", 5)
      local context = select(session, first, last)
      H.eq({
        { "src/old name.lua", "old", "deadbeef", 4, 5, { "removed α", "removed extra" } },
        { "src/new name.lua", "new", "worktree", 4, 5, { "replacement β", "same tail" } },
      }, span_locations(context))
      H.eq(env.root .. "/src/old name.lua", context.spans[1].absolute_path)
      H.eq(0, context.spans[1].start_col)
      H.eq(#"same tail", context.spans[2].end_col)
      H.ok(last ~= 5, "fixture must distinguish display and source line numbers")
      local all = select(session, 1, #session.rows)
      H.eq(3, #all.spans)
      H.eq("tests/new.lua", all.spans[3].path)
      H.eq({ "first new", "last new" }, all.spans[3].lines)
    end)
  end,

  ["headers gaps and split padding carry no invented source locations"] = function()
    with_review(function(session)
      local header = session.file_rows.first
      H.eq({}, select(session, header).spans)
      local gap = find_row(session, function(row)
        return row.kind == "gap"
      end)
      H.eq({}, select(session, gap).spans)
      session:toggle_layout()
      local deletion = at_source(session, "old", 5)
      H.eq({}, select(session, deletion, nil, session.right_win).spans)
      H.eq(
        "",
        api.nvim_buf_get_lines(api.nvim_win_get_buf(session.right_win), deletion - 1, deletion, false)[1]
      )
      local addition = at_source(session, "new", 1, "second")
      H.eq({}, select(session, addition, nil, session.main_win).spans)
      H.eq(
        "",
        api.nvim_buf_get_lines(api.nvim_win_get_buf(session.main_win), addition - 1, addition, false)[1]
      )
      H.eq("first new", select(session, addition, nil, session.right_win).spans[1].lines[1])
      H.eq(
        api.nvim_buf_line_count(api.nvim_win_get_buf(session.main_win)),
        api.nvim_buf_line_count(api.nvim_win_get_buf(session.right_win))
      )
    end)
  end,

  ["ordinary visual yank and search operate on code without gutter prefixes"] = function()
    with_review(function(session)
      place(session, "old", 4)
      vim.cmd('normal! Vj"zy')
      H.eq({ "removed α", "removed extra" }, vim.fn.getreg("z", 1, true))
      local buf = api.nvim_win_get_buf(session.main_win)
      local context = view.context({
        buf = buf,
        win = session.main_win,
        range = {
          from = api.nvim_buf_get_mark(buf, "<"),
          to = api.nvim_buf_get_mark(buf, ">"),
          kind = "line",
        },
      })
      H.eq(
        { { "src/old name.lua", "old", "deadbeef", 4, 5, { "removed α", "removed extra" } } },
        span_locations(context)
      )
      H.eq(at_source(session, "new", 4), vim.fn.search("replacement", "W"))
      H.eq(false, vim.bo[buf].modifiable)
    end)
  end,

  ["file tree selection supplies exact file context while directory rows supply none"] = function()
    with_review(function(session)
      local tree_buf = api.nvim_win_get_buf(session.tree_win)
      local directory, file_row
      for index, entry in ipairs(session.tree_entries) do
        if entry.directory then
          directory = index
        end
        if entry.file and entry.file.meta.id == "second" then
          file_row = index
        end
      end
      H.eq(nil, view.context({ buf = tree_buf, row = directory }))
      local context = view.context({ buf = tree_buf, row = file_row })
      H.eq("tests/new.lua", context.file.path)
      H.eq({}, context.spans)
      api.nvim_set_current_win(session.tree_win)
      api.nvim_win_set_cursor(session.tree_win, { file_row, 0 })
      session:open_source()
      H.eq(session.main_win, api.nvim_get_current_win())
      H.eq(session.file_rows.second, api.nvim_win_get_cursor(0)[1])
    end)
  end,

  ["character selections preserve complete UTF-8 endpoint characters and exact columns"] = function()
    with_review(function(session)
      local row = at_source(session, "new", 4)
      local prefix = #"replacement "
      local context = select(session, row, row, nil, "char", prefix, prefix)
      H.eq({ "β" }, context.spans[1].lines)
      H.eq(prefix, context.spans[1].start_col)
      H.eq(#"replacement β", context.spans[1].end_col)
      local block = select(session, row, row, nil, "block", prefix, prefix)
      H.eq({ "β" }, block.spans[1].lines, "block selections must also preserve complete UTF-8")
      local first = at_source(session, "old", 4)
      local reversed = select(session, row, first, nil, "char", prefix, 8)
      H.eq({ "α" }, reversed.spans[1].lines)
      H.eq({ "removed extra" }, reversed.spans[2].lines)
      H.eq({ "replacement β" }, reversed.spans[3].lines)
    end)
  end,

  ["layout and file focus restore source identity without reloading Git"] = function()
    with_review(function(session, env)
      place(session, "new", 4)
      local stream_anchor = session:anchor()
      session:toggle_layout()
      H.eq("split", session.layout)
      H.eq(session.right_win, api.nvim_get_current_win())
      H.eq({ "first", "new", 4 }, { session:anchor().file_id, session:anchor().side, session:anchor().line })
      session:toggle_focus()
      H.eq("first", session.focus_id)
      H.eq(nil, session.file_rows.second)
      place(session, "new", 5)
      session:toggle_focus()
      H.eq(nil, session.focus_id)
      H.ok(session.file_rows.second)
      H.eq(stream_anchor.line, session:anchor().line, "leaving focus restores prior stream source position")
      session:toggle_layout()
      H.eq({ "first", "new", 4 }, { session:anchor().file_id, session:anchor().side, session:anchor().line })
      H.eq(1, #env.control.loads, "layout/focus toggles must not invoke Git")
      place(session, "old", 5)
      session:toggle_layout()
      H.eq({ "old", 5 }, { session:anchor().side, session:anchor().line })
    end)
  end,

  ["focusing a different tree file selects that file and restores the prior stream source"] = function()
    with_review(function(session)
      place(session, "new", 5)
      local target
      for index, entry in ipairs(session.tree_entries) do
        if entry.file and entry.file.meta.id == "second" then
          target = index
        end
      end
      api.nvim_set_current_win(session.tree_win)
      api.nvim_win_set_cursor(session.tree_win, { target, 0 })
      session:toggle_focus()
      H.eq("second", session.focus_id)
      H.eq("second", session:anchor().file_id)
      H.eq(nil, session.file_rows.first)
      H.eq(session.main_win, api.nvim_get_current_win())
      session:toggle_focus()
      H.eq(nil, session.focus_id)
      H.eq({ "first", "new", 5 }, { session:anchor().file_id, session:anchor().side, session:anchor().line })
    end)
  end,

  ["full-file expansion exposes source addresses and preserves file-local state"] = function()
    with_review(function(session, env)
      place(session, "new", 4)
      session:expand("all", true)
      H.ok(vim.wait(1000, function()
        return session.files[1].hydrated
      end, 1))
      H.eq(2, #env.control.reads)
      for line, text in ipairs(env.sources.first.new) do
        local row = at_source(session, "new", line)
        local span = select(session, row).spans[1]
        H.eq(line, span.start_line)
        H.eq({ text }, span.lines)
      end
      H.eq(4, session:anchor().line)
      session:toggle_focus()
      session:toggle_layout()
      local row = at_source(session, "new", 8)
      H.eq(8, select(session, row, nil, session.right_win).spans[1].start_line)
      session:toggle_focus()
      H.ok(session.file_rows.second)
      H.ok(at_source(session, "new", 1))
      session:collapse_context()
      H.eq(nil, session.files[1].expansion["gap:1"])
      H.ok(find_row(session, function(value)
        return value.kind == "gap" and value.file.meta.id == "first"
      end))
    end)
  end,

  ["refresh ignores older load completions and cancels outstanding jobs"] = function()
    with_review(function(session, env)
      H.eq(nil, session.snapshot)
      session:load({ mode = "staged" })
      H.eq(2, #env.control.loads)
      H.eq(true, env.control.loads[1].canceled)
      local newer = vim.deepcopy(env.snapshot)
      newer.label = "newest staged result"
      newer.files = { newer.files[2] }
      env.control.loads[2].callback(nil, newer)
      H.eq("newest staged result", session.snapshot.label)
      env.control.loads[1].callback(nil, env.snapshot)
      H.eq("newest staged result", session.snapshot.label)
      H.eq(nil, session.file_rows.first)
      H.ok(session.file_rows.second)
    end, { auto_load = false })
  end,

  ["late context hydration cannot overwrite a refreshed review"] = function()
    with_review(function(session, env)
      local old_file = session.files[1]
      place(session, "new", 4)
      session:expand("all", true)
      H.eq(2, #env.control.reads)
      session:load()
      H.ok(vim.wait(1000, function()
        return session.files[1] ~= old_file
      end, 1))
      for _, read in ipairs(env.control.reads) do
        H.eq(true, read.canceled)
        read.callback(nil, read.result)
      end
      H.eq(false, session.files[1].hydrated)
      H.eq({}, session.files[1].expansion)
      H.eq(4, session:anchor().line)
    end, { auto_source = false })
  end,

  ["failed refresh permits source requests after canceling previous hydration"] = function()
    with_review(function(session, env)
      env.control.loads[1].callback(nil, env.snapshot)
      local retained = session.files[1]
      place(session, "new", 4)
      session:expand("all", true)
      H.eq(2, #env.control.reads)
      session:load()
      env.control.loads[2].callback("fixture refresh failed", nil)
      H.eq(retained, session.files[1])
      H.eq(1, #env.notifications)
      session:expand("all", true)
      H.eq(4, #env.control.reads, "canceled waiters must not absorb fresh source requests")
      for index = 1, 2 do
        H.eq(true, env.control.reads[index].canceled)
        env.control.reads[index].callback(nil, env.control.reads[index].result)
      end
      H.eq(false, retained.hydrated, "canceled source results must remain ignored")
      for index = 3, 4 do
        env.control.reads[index].callback(nil, env.control.reads[index].result)
      end
      H.eq(true, retained.hydrated)
      H.ok(at_source(session, "new", 1))
      H.ok(at_source(session, "new", 8))
    end, { auto_load = false, auto_source = false })
  end,

  ["refreshing an expanded file restores context only after fresh source validation"] = function()
    with_review(function(session, env)
      env.control.loads[1].callback(nil, env.snapshot)
      place(session, "new", 4)
      session:expand("all", true)
      H.ok(vim.wait(1000, function()
        return session.files[1].hydrated
      end, 1))
      H.ok(at_source(session, "new", 8))
      local old_file = session.files[1]
      session:load()
      env.control.loads[2].callback(nil, vim.deepcopy(env.snapshot))
      H.ok(vim.wait(1000, function()
        return session.files[1] ~= old_file and session.files[1].hydrated
      end, 1))
      H.ok(at_source(session, "new", 1))
      H.ok(at_source(session, "new", 8))
      H.eq(4, session:anchor().line)
    end, { auto_load = false })
  end,

  ["path presentation escapes control characters while source addresses remain exact"] = function()
    with_review(function(session, env)
      local path = "路径/naïve 🪶\nb\t.lua"
      env.snapshot.files[1].path = path
      env.snapshot.files[1].old_path = "old\nname.lua"
      env.control.loads[1].callback(nil, env.snapshot)
      local row = at_source(session, "new", 4)
      H.eq(path, select(session, row).spans[1].path)
      local header = api.nvim_buf_get_lines(
        api.nvim_win_get_buf(session.main_win),
        session.file_rows.first - 1,
        session.file_rows.first,
        false
      )[1]
      H.ok(header:find("路径/naïve 🪶", 1, true), "Unicode path characters must remain readable")
      for _, win in ipairs({ session.main_win, session.tree_win }) do
        for _, text in ipairs(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)) do
          H.eq(nil, text:find("\n", 1, true))
          H.eq(nil, text:find("\t", 1, true))
        end
      end
    end, { auto_load = false })
  end,

  ["historical source opening preserves unsaved user buffers and requested source line"] = function()
    with_review(function(session, env)
      place(session, "old", 5)
      session:open_source()
      H.ok(vim.wait(1000, function()
        return api.nvim_get_current_win() == env.origin_win
      end, 1))
      local historical = api.nvim_get_current_buf()
      H.eq(env.sources.first.old, api.nvim_buf_get_lines(historical, 0, -1, false))
      H.eq(false, vim.bo[historical].modifiable)
      H.eq(5, api.nvim_win_get_cursor(0)[1])
      H.eq({ "unsaved work", "keep me" }, api.nvim_buf_get_lines(env.origin_buf, 0, -1, false))
      H.eq(true, vim.bo[env.origin_buf].modified)
      H.ok(api.nvim_tabpage_is_valid(session.tab))
      session:close()
      H.eq(true, api.nvim_buf_is_valid(historical))
      H.eq(historical, api.nvim_win_get_buf(env.origin_win))
      H.eq(
        { { "src/old name.lua", "old", "deadbeef", 5, 5, { "removed extra" } } },
        span_locations(view.context({ buf = historical, win = env.origin_win, row = 5, col = 1 }))
      )
    end)
  end,

  ["worktree source opening uses the existing editable buffer"] = function()
    with_review(function(session, env)
      local path = env.root .. "/src/new name.lua"
      local expected = vim.fn.bufadd(path)
      vim.fn.bufload(expected)
      place(session, "new", 5)
      session:open_source()
      H.eq(env.origin_win, api.nvim_get_current_win())
      H.eq(expected, api.nvim_get_current_buf())
      H.eq(true, vim.bo[expected].modifiable)
      H.eq(5, api.nvim_win_get_cursor(0)[1])
      H.eq({ "unsaved work", "keep me" }, api.nvim_buf_get_lines(env.origin_buf, 0, -1, false))
    end)
  end,

  ["repeated historical source opening reuses a valid snapshot without name collisions"] = function()
    with_review(function(session, env)
      place(session, "old", 4)
      session:open_source()
      H.ok(vim.wait(1000, function()
        return api.nvim_get_current_win() == env.origin_win
      end, 1))
      local initial = api.nvim_get_current_buf()
      place(session, "old", 5)
      session:open_source()
      H.ok(vim.wait(1000, function()
        return api.nvim_get_current_win() == env.origin_win
      end, 1))
      H.eq(env.sources.first.old, api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false))
      H.eq(5, api.nvim_win_get_cursor(0)[1])
      H.ok(api.nvim_get_current_buf() == initial or not api.nvim_buf_is_valid(initial))
    end)
  end,

  ["Enter on missing split source padding does not open an unrelated line"] = function()
    with_review(function(session, env)
      session:toggle_layout()
      local deletion = at_source(session, "old", 5)
      api.nvim_set_current_win(session.right_win)
      api.nvim_win_set_cursor(session.right_win, { deletion, 0 })
      session:open_source()
      H.eq(session.right_win, api.nvim_get_current_win())
      H.eq(0, #env.control.reads)
      H.eq(env.origin_buf, api.nvim_win_get_buf(env.origin_win))
    end)
  end,

  ["closing the review releases only owned windows buffers and jobs"] = function()
    with_review(function(session, env)
      session:toggle_layout()
      local source_delivered = false
      session:ensure_source(session.files[1], function()
        source_delivered = true
      end)
      H.eq(2, #env.control.reads)
      local buffers = vim.tbl_values(session.bufs)
      local tab = session.tab
      session:close()
      H.eq(true, session.closed)
      H.eq(nil, view.sessions[tab])
      H.eq(false, api.nvim_tabpage_is_valid(tab))
      for _, buf in ipairs(buffers) do
        H.eq(false, api.nvim_buf_is_valid(buf))
        H.eq(nil, view.buffers[buf])
      end
      for _, read in ipairs(env.control.reads) do
        H.eq(true, read.canceled)
        read.callback(nil, read.result)
      end
      H.eq(false, source_delivered, "closed session must ignore pending source completions")
      H.eq(true, api.nvim_buf_is_valid(env.origin_buf))
      H.eq({ "unsaved work", "keep me" }, api.nvim_buf_get_lines(env.origin_buf, 0, -1, false))
      H.eq(env.origin_win, api.nvim_get_current_win())
      H.eq(nil, view.context({ buf = buffers[1], row = 1 }))
      env.control.loads[1].callback(nil, env.snapshot)
      H.eq(nil, view.sessions[tab], "late completion must not resurrect closed UI")
    end, { auto_source = false })
  end,

  ["manually closing the review tab invokes lifecycle cleanup"] = function()
    with_review(function(session)
      local buffers = vim.tbl_values(session.bufs)
      vim.cmd("tabclose")
      H.ok(vim.wait(1000, function()
        return session.closed
      end, 1))
      for _, buf in ipairs(buffers) do
        H.eq(false, api.nvim_buf_is_valid(buf))
      end
    end)
  end,

  ["manually closing the main review window cleans the remaining session windows"] = function()
    with_review(function(session, env)
      session:toggle_layout()
      local buffers, tab = vim.tbl_values(session.bufs), session.tab
      api.nvim_win_close(session.main_win, true)
      H.ok(
        vim.wait(1000, function()
          return session.closed
        end, 1),
        "manual main-window close must dispose session"
      )
      H.eq(false, api.nvim_tabpage_is_valid(tab))
      H.eq(nil, view.sessions[tab])
      for _, buf in ipairs(buffers) do
        H.eq(false, api.nvim_buf_is_valid(buf))
        H.eq(nil, view.buffers[buf])
      end
      H.eq(true, api.nvim_buf_is_valid(env.origin_buf))
      H.eq({ "unsaved work", "keep me" }, api.nvim_buf_get_lines(env.origin_buf, 0, -1, false))
    end)
  end,

  ["manually closing the new split pane restores a usable unified review"] = function()
    with_review(function(session)
      place(session, "new", 4)
      session:toggle_layout()
      api.nvim_win_close(session.right_win, true)
      H.ok(
        vim.wait(1000, function()
          return session.layout == "unified"
        end, 1),
        "closing split pane did not restore unified layout"
      )
      H.ok(not session.closed)
      H.eq(nil, session.right_win)
      H.eq(session.bufs.unified, api.nvim_win_get_buf(session.main_win))
      local row = at_source(session, "new", 4)
      H.eq("replacement β", select(session, row).spans[1].lines[1])
    end)
  end,

  ["visible sources stay cached under pressure and evicted sources reload once when revisited"] = function()
    with_review(function(session, env)
      H.ok(
        vim.wait(3000, function()
          return session.files[1].syntax and session.files[2].syntax and session.cache_stats
        end, 1),
        "visible files did not finish highlighting"
      )
      H.eq(4, #env.control.reads)
      H.ok(
        session.cache_stats.pinned_overflow > 0,
        "visible sources may intentionally exceed the cache budget"
      )
      for _ = 1, 3 do
        session:queue_visible()
        vim.wait(5, function()
          return false
        end, 1)
      end
      H.eq(4, #env.control.reads, "redraw/prune must not repeatedly reload visible files")
      place(session, "new", 1, "second")
      session:toggle_focus()
      H.ok(
        vim.wait(3000, function()
          return session.files[1].sources == nil
        end, 1),
        "hidden source was not evicted"
      )
      H.eq(false, session.files[1].hydrated)
      H.eq(nil, session.files[1].syntax)
      H.ok(session.files[2].sources)
      vim.wait(15, function()
        return false
      end, 1)
      H.eq(nil, session.files[1].sources, "queued decoration callbacks must not resurrect evicted sources")
      H.eq(4, #env.control.reads)
      session:toggle_focus()
      H.ok(
        vim.wait(3000, function()
          return session.files[1].syntax ~= nil
        end, 1),
        "revisited source did not reload"
      )
      H.eq(6, #env.control.reads)
      for _ = 1, 3 do
        session:queue_visible()
        vim.wait(5, function()
          return false
        end, 1)
      end
      H.eq(6, #env.control.reads)
    end, { view = { syntax = true, source_cache_bytes = 0 } })
  end,

  ["view focus focuses the first file once and gf to stream survives refresh"] = function()
    with_review(function(session, env)
      env.control.loads[1].callback(nil, env.snapshot)
      H.eq("first", session.focus_id)
      H.eq(nil, session.file_rows.second)
      H.ok(eval_bar(session.main_win, "winbar"):find("· focused", 1, true))
      refresh(session, env, vim.deepcopy(env.snapshot))
      H.eq("first", session.focus_id, "refresh keeps the focused file")
      press("<Tab>")
      refresh(session, env, vim.deepcopy(env.snapshot))
      H.eq("second", session.focus_id, "focus is not re-forced onto the first file")
      press("gf")
      H.eq(nil, session.focus_id)
      refresh(session, env, vim.deepcopy(env.snapshot))
      H.eq(nil, session.focus_id, "gf to stream must survive refresh")
      H.ok(session.file_rows.first and session.file_rows.second)
    end, { auto_load = false, columns = 200, view = { view = "focus" } })
  end,

  ["view focus waits through an empty comparison and focuses when changes appear"] = function()
    with_review(function(session, env)
      env.control.loads[1].callback(nil, without_files(env.snapshot, {}))
      H.eq(nil, session.focus_id)
      H.eq({ "No changes in this comparison." }, buffer_lines(session.main_win))
      refresh(session, env, vim.deepcopy(env.snapshot))
      H.eq("first", session.focus_id)
      H.eq(session.file_rows.first, api.nvim_win_get_cursor(session.main_win)[1])
    end, { auto_load = false, view = { view = "focus" } })
  end,

  ["view focus on a single-file comparison wraps Tab to that file"] = function()
    with_review(function(session, env)
      env.control.loads[1].callback(nil, without_files(env.snapshot, { "second" }))
      H.eq("second", session.focus_id)
      press("<Tab>")
      H.eq("second", session.focus_id)
      press("<S-Tab>")
      H.eq("second", session.focus_id)
    end, { auto_load = false, view = { view = "focus" } })
  end,

  ["refresh focuses the file at the vanished file's index and streams only when empty"] = function()
    with_review(function(session, env)
      env.control.loads[1].callback(nil, env.snapshot)
      H.eq(nil, session.focus_id, "the default view is the stream")
      place(session, "new", 1, "second")
      session:toggle_focus()
      H.eq("second", session.focus_id)
      refresh(session, env, without_files(env.snapshot, { "first" }))
      H.eq("first", session.focus_id, "index 2 is clamped to the remaining file")
      H.eq(session.file_rows.first, api.nvim_win_get_cursor(session.main_win)[1])
      refresh(session, env, without_files(env.snapshot, { "second" }))
      H.eq("second", session.focus_id, "the file now at index 1 takes focus")
      refresh(session, env, without_files(env.snapshot, {}))
      H.eq(nil, session.focus_id)
      H.eq({ "No changes in this comparison." }, buffer_lines(session.main_win))
      refresh(session, env, vim.deepcopy(env.snapshot))
      H.eq(nil, session.focus_id, "without view = focus, a later refresh stays in the stream")
    end, { auto_load = false })
  end,

  ["public API validates view and parses commits and view flags"] = function()
    local rill = require("rill")
    local original, captured = view.open, nil
    view.open = function(opts)
      captured = opts
    end
    local ok, err = pcall(function()
      local bad_ok, bad = pcall(rill.open, { view = "grid" })
      H.eq(false, bad_ok)
      H.ok(tostring(bad):find("Rill view must be stream or focus", 1, true), tostring(bad))
      rill.command({ "commits", "HEAD~2", "HEAD", "--focus", "--split", "--", "lua", "doc" })
      H.eq("commits", captured.mode)
      H.eq({ { rev = "HEAD~2" }, { rev = "HEAD" } }, captured.commits)
      H.eq({ "lua", "doc" }, captured.paths)
      H.eq({ "focus", "split" }, { captured.view, captured.layout })
      rill.command({ "--stream" })
      H.eq({ "working", "stream" }, { captured.mode, captured.view })
      rill.open_commits({ "a1", { rev = "b2", paths = { "x" } }, "a1" }, { paths = { "default" } })
      H.eq({ { rev = "a1" }, { rev = "b2", paths = { "x" } } }, captured.commits, "repeated revs are dropped")
      H.eq({ "default" }, captured.paths, "opts.paths stays the default for items without paths")
      for _, call in ipairs({
        function()
          rill.open_commits({})
        end,
        function()
          rill.command({ "commits", "--", "lua" })
        end,
        function()
          rill.open_commits({ { paths = { "x" } } })
        end,
      }) do
        H.eq(false, pcall(call), "empty or malformed commit lists must error")
      end
      rill.setup({ view = "focus" })
      rill.open_working()
      H.eq("focus", captured.view)
      rill.open_working({ view = "stream" })
      H.eq("stream", captured.view, "a single call overrides the configured view")
    end)
    view.open = original
    rill.setup()
    if not ok then
      error(err, 0)
    end
  end,

  ["commits mode renders a row per commit and reads each file from its own commit"] = function()
    with_review(function(session, env)
      local lines = buffer_lines(session.main_win)
      local function row_of(text)
        for index, line in ipairs(lines) do
          if line == text then
            return index
          end
        end
        error("missing row: " .. text .. "\n" .. table.concat(lines, "\n"))
      end
      local first = row_of("● 1/3  aaaaaaaa  Add a — Ada · 03 Oct 2026 · root")
      local empty = row_of("● 2/3  bbbbbbbb  Nothing — Ada · 03 Oct 2026")
      local merge = row_of("● 3/3  cccccccc  Merge side — Ada · 03 Oct 2026 · merge vs 1st parent")
      H.eq(1, first)
      H.eq("  (no changes)", lines[empty + 1])
      H.eq({ "group", 3 }, { session.rows[merge].kind, session.rows[merge].group })
      H.eq(merge + 1, session.file_rows[C .. ":src/shared.lua"], "a commit's first file follows its row")
      H.ok(session.file_rows[A .. ":src/shared.lua"], "the same path in two commits keeps two entries")
      for _, file in ipairs(session.files) do
        H.eq(env.snapshot.groups[file.meta.group].snapshot, file.snapshot)
      end
      local header = session.rows[merge]
      H.eq(C .. ":src/shared.lua", header.file.meta.id, "a commit row resolves like its first file's header")
      local winbar, status = eval_bar(session.main_win, "winbar"), eval_bar(session.main_win, "statusline")
      H.ok(winbar:find("[1/3] aaaaaaaa Add a · unified · stream", 1, true), winbar)
      H.ok(winbar:find("]C/[C commits", 1, true), winbar)
      H.ok(status:find("3 files · 3 commits", 1, true), status)
      place(session, "new", 1, C .. ":src/shared.lua")
      winbar, status = eval_bar(session.main_win, "winbar"), eval_bar(session.main_win, "statusline")
      H.ok(winbar:find("[3/3] cccccccc Merge side", 1, true), winbar)
      H.ok(status:find("Rill · src/shared.lua", 1, true), "statusline shows the path, not the oid:path id")
      api.nvim_win_set_cursor(session.main_win, { empty + 1, 0 })
      session:cursor_changed(api.nvim_win_get_buf(session.main_win))
      H.ok(eval_bar(session.main_win, "winbar"):find("[2/3] bbbbbbbb Nothing", 1, true))
    end, { fixture = commits_fixture, columns = 200 })
  end,

  ["Tab crosses commits in focus while ]C and [C skip empty commits"] = function()
    with_review(function(session)
      local first, second, third = A .. ":src/a.lua", A .. ":src/shared.lua", C .. ":src/shared.lua"
      H.eq(first, session.focus_id)
      H.eq({ "group", 1 }, { session.rows[1].kind, session.rows[1].group })
      H.eq(2, session.file_rows[first])
      local visited = {}
      for _ = 1, 3 do
        press("<Tab>")
        visited[#visited + 1] = session.focus_id
        H.eq(session.focus_id, session.rows[1].file.meta.id, "focus renders the focused file's commit row")
        H.eq(
          1,
          api.nvim_win_call(session.main_win, function()
            return vim.fn.line("w0")
          end),
          "the commit row stays on screen"
        )
      end
      H.eq({ second, third, first }, visited)
      press("<S-Tab>")
      H.eq(third, session.focus_id)
      press("]C")
      H.eq(first, session.focus_id, "]C wraps past the last commit")
      press("]C")
      H.eq(third, session.focus_id, "]C skips the empty commit")
      press("[C")
      H.eq(first, session.focus_id)
      press("[C")
      H.eq(third, session.focus_id, "[C wraps past the first commit")
      H.ok(
        eval_bar(session.main_win, "winbar"):find("[3/3] cccccccc Merge side · unified · focused", 1, true)
      )
      press("gf")
      H.eq(nil, session.focus_id)
      press("[C")
      H.eq(first, session.current_file, "in the stream, [C moves the cursor to the commit's first file")
      H.eq(session.file_rows[first], api.nvim_win_get_cursor(session.main_win)[1])
    end, { fixture = commits_fixture, columns = 200, view = { view = "focus" } })
  end,

  ["context reports each commit's own revision and path"] = function()
    with_review(function(session)
      local function span(side, line, id)
        return select(session, (at_source(session, side, line, id))).spans[1]
      end
      local added = span("new", 1, A .. ":src/a.lua")
      H.eq({ "src/a.lua", "new", A, { "alpha" } }, { added.path, added.side, added.revision, added.lines })
      local merged = span("new", 1, C .. ":src/shared.lua")
      H.eq({ "src/shared.lua", C, { "two" } }, { merged.path, merged.revision, merged.lines })
      H.eq(B, span("old", 1, C .. ":src/shared.lua").revision, "the old side is the commit's first parent")
      local header = session.file_rows[C .. ":src/shared.lua"] - 1
      H.eq(C .. ":src/shared.lua", select(session, header).file.id)
      H.eq({}, select(session, header).spans)
    end, { fixture = commits_fixture })
  end,

  ["commit tree nodes fold independently and Enter jumps to their first file"] = function()
    with_review(function(session)
      local function tree_lines()
        return buffer_lines(session.tree_win)
      end
      H.eq({
        "▾ 1/3 aaaaaaaa Add a",
        "  ▾ src/",
        "    A a.lua",
        "    A shared.lua",
        "▾ 2/3 bbbbbbbb Nothing",
        "  (no changes)",
        "▾ 3/3 cccccccc Merge side",
        "  ▾ src/",
        "    M shared.lua",
      }, tree_lines())
      api.nvim_set_current_win(session.tree_win)
      api.nvim_win_set_cursor(session.tree_win, { 7, 0 })
      press("<CR>")
      H.eq(session.main_win, api.nvim_get_current_win())
      H.eq(session.file_rows[C .. ":src/shared.lua"], api.nvim_win_get_cursor(0)[1])
      api.nvim_set_current_win(session.tree_win)
      api.nvim_win_set_cursor(session.tree_win, { 2, 0 })
      press("za")
      H.eq("  ▸ src/", tree_lines()[2])
      H.eq("  ▾ src/", tree_lines()[6], "the same directory in another commit stays open")
      api.nvim_win_set_cursor(session.tree_win, { 1, 0 })
      press("za")
      H.eq({ "▸ 1/3 aaaaaaaa Add a", "▾ 2/3 bbbbbbbb Nothing" }, vim.list_slice(tree_lines(), 1, 2))
      H.eq(A .. ":src/a.lua", view.context({ buf = api.nvim_win_get_buf(session.tree_win), row = 1 }).file.id)
      press("<CR>")
      H.eq(session.file_rows[A .. ":src/a.lua"], api.nvim_win_get_cursor(session.main_win)[1])
    end, { fixture = commits_fixture })
  end,

  ["jumping to a file keeps the commit row above it on screen"] = function()
    with_review(function(session)
      vim.wo[session.main_win].scrolloff = 0
      local id = C .. ":src/shared.lua"
      session:jump_file(session.by_id[id])
      local top = api.nvim_win_call(session.main_win, function()
        return vim.fn.line("w0")
      end)
      H.eq(session.file_rows[id] - 1, top)
      H.eq("group", session.rows[top].kind)
      H.eq(session.file_rows[id], api.nvim_win_get_cursor(session.main_win)[1])
    end, { fixture = commits_fixture })
  end,
}
