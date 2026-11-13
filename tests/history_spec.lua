-- History reviews against real repositories: git.log paging/follow at the Git
-- seam, then the session walking commits, paging and rendering messages.
local H = require("tests.helpers")
local api = vim.api
local git = require("rill.git")

local function commit(root, subject, body)
  H.command({ "git", "add", "--all" }, root)
  local args = { "git", "commit", "-q", "--allow-empty", "-m", subject }
  if body then
    vim.list_extend(args, { "-m", body })
  end
  H.command(args, root)
  return H.command({ "git", "rev-parse", "HEAD" }, root)
end

-- Five commits, newest last: c5 renames docs/guide.md to docs/manual.md, so a
-- followed history of the new name reaches back to c2 through the rename.
local function fixture()
  local root = vim.uv.fs_realpath(H.repo())
  local oids = {}
  H.write(root, "src/a.lua", { "one" })
  oids[1] = commit(root, "c1 add a")
  H.write(root, "docs/guide.md", { "# Guide", "intro" })
  oids[2] = commit(root, "c2 add guide", "Why the guide exists.\n\nSecond paragraph.")
  H.write(root, "src/a.lua", { "one", "two" })
  oids[3] = commit(root, "c3 grow a")
  H.write(root, "docs/guide.md", { "# Guide", "intro", "more" })
  oids[4] = commit(root, "c4 extend guide")
  H.command({ "git", "mv", "docs/guide.md", "docs/manual.md" }, root)
  oids[5] = commit(root, "c5 rename guide")
  return root, oids
end

local function page(opts)
  return H.await(function(done)
    git.log(opts, done)
  end)
end

local function subjects(commits)
  return vim.tbl_map(function(item)
    return item.subject
  end, commits)
end

-- Open a history review through the public entrypoint and wait for its first
-- commit. Notifications are captured; the session and repository are removed.
local function with_history(opts, fn)
  local root, oids = fixture()
  local previous_notify, previous_columns = vim.notify, vim.o.columns
  local previous_tree = package.loaded["rill.tree"]
  -- Manual Files widths persist per module; keep each case's geometry its own.
  package.loaded["rill.tree"] = nil
  vim.o.columns = 160
  local notes = {}
  vim.notify = function(message)
    notes[#notes + 1] = message
  end
  local session
  local ok, err = xpcall(function()
    session = require("rill").open_history(vim.tbl_extend("force", {
      cwd = root,
      count = 2,
      syntax = false,
      sidekick = false,
      layout = "unified",
    }, opts or {}))
    H.ok(
      vim.wait(5000, function()
        return session.history.shown ~= nil and not session.history.loading
      end, 10),
      "history did not show its first commit"
    )
    fn(session, { root = root, oids = oids, notes = notes })
  end, debug.traceback)
  if session then
    pcall(session.close, session)
  end
  vim.notify, vim.o.columns = previous_notify, previous_columns
  package.loaded["rill.tree"] = previous_tree
  vim.fn.delete(root, "rf")
  if not ok then
    error(err, 0)
  end
end

local function shows(session, index)
  return vim.wait(5000, function()
    local history = session.history
    return history.shown == history.commits[index] and not history.loading and not history.busy
  end, 10)
end

local function lines(win)
  return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
end

local function tree_lines(session)
  return api.nvim_buf_get_lines(session.tree.buf, 0, -1, false)
end

local function press(key)
  local binding = vim.fn.maparg(key, "n", false, true)
  H.eq("function", type(binding.callback), "expected local action for " .. key)
  binding.callback()
end

return {
  ["git.log pages from a pinned head and reports the end"] = function()
    local root = fixture()
    local first = page({ cwd = root, count = 2 })
    H.eq({ "c5 rename guide", "c4 extend guide" }, subjects(first.commits))
    H.eq(false, first.done)
    H.eq(H.command({ "git", "rev-parse", "HEAD" }, root), first.head)
    -- A commit made after the first page must not shift the pages after it.
    H.write(root, "late.txt", { "late" })
    commit(root, "c6 late")
    local second = page({ cwd = root, head = first.head, skip = 2, count = 2 })
    H.eq({ "c3 grow a", "c2 add guide" }, subjects(second.commits))
    local last = page({ cwd = root, head = first.head, skip = 4, count = 2 })
    H.eq({ "c1 add a" }, subjects(last.commits))
    H.eq(true, last.done)
    H.eq(true, last.commits[1].root_commit)
    H.eq({}, last.commits[1].parents)
    vim.fn.delete(root, "rf")
  end,

  ["git.log keeps multi-line bodies and limits by paths"] = function()
    local root = fixture()
    local result = page({ cwd = root, count = 10, paths = { "docs" } })
    H.eq({ "c5 rename guide", "c4 extend guide", "c2 add guide" }, subjects(result.commits))
    H.eq(true, result.done)
    H.eq("Why the guide exists.\n\nSecond paragraph.", result.commits[3].body)
    H.eq("", result.commits[1].body)
    -- Without --follow, commits carry no per-commit paths: the scope applies.
    H.eq(nil, result.commits[1].paths)
    vim.fn.delete(root, "rf")
  end,

  ["git.log follows one file across a rename, paging past it"] = function()
    local root = fixture()
    local first = page({ cwd = root, count = 1, paths = { "docs/manual.md" }, follow = true })
    H.eq({ "c5 rename guide" }, subjects(first.commits))
    -- The rename commit needs both names to stay a rename in its review.
    H.eq({ "docs/manual.md", "docs/guide.md" }, first.commits[1].paths)
    local rest = page({
      cwd = root,
      head = first.head,
      skip = 1,
      count = 5,
      paths = { "docs/manual.md" },
      follow = true,
    })
    H.eq({ "c4 extend guide", "c2 add guide" }, subjects(rest.commits))
    H.eq({ "docs/guide.md" }, rest.commits[1].paths)
    H.eq(true, rest.done)
    vim.fn.delete(root, "rf")
  end,

  ["git.log reports unknown starting revisions"] = function()
    local root = fixture()
    local err
    local done = false
    git.log({ cwd = root, rev = "no-such-ref" }, function(e)
      err, done = e, true
    end)
    H.ok(vim.wait(5000, function()
      return done
    end, 10))
    H.eq("No commits at no-such-ref", err)
    vim.fn.delete(root, "rf")
  end,

  ["history opens on the newest commit with its message and lists the page"] = function()
    with_history(nil, function(session, env)
      local document = lines(session.main_win)
      H.eq("● " .. env.oids[5]:sub(1, 8) .. "  c5 rename guide", document[1])
      H.eq("  Author: Rill Tests <rill@example.invalid>", document[2])
      H.ok(document[3]:match("^  Date:   %a%a%a %d%d %a%a%a %d%d%d%d %d%d:%d%d [-+]%d%d%d%d$"), document[3])
      H.eq("  Commit: " .. env.oids[5], document[4])
      H.eq("  1 file · +0 −0", document[6])
      H.eq("commit", session.rows[1].kind)
      H.eq({ 1, 0 }, api.nvim_win_get_cursor(session.main_win))
      local tree = tree_lines(session)
      H.ok(tree[1]:find("▾ " .. env.oids[5]:sub(1, 8) .. " c5 rename guide", 1, true), tree[1])
      H.ok(
        tree[#tree - 1]:find("▸ " .. env.oids[4]:sub(1, 8) .. " c4 extend guide", 1, true),
        tree[#tree - 1]
      )
      H.ok(tree[#tree]:find("C-e / Enter: 2 more", 1, true), tree[#tree])
      H.ok(vim.wo[session.main_win].winbar:find("[1/2+]", 1, true))
      H.ok(vim.wo[session.tree.win].winbar:find("History · ", 1, true))
    end)
  end,

  ["Tab walks older commits, loading the next page past the last"] = function()
    with_history(nil, function(session, env)
      api.nvim_set_current_win(session.main_win)
      api.nvim_win_set_cursor(session.main_win, { #session.rows, 0 })
      press("<Tab>")
      H.ok(shows(session, 2))
      -- Each commit starts at its message, not at the previous cursor row.
      H.eq({ 1, 0 }, api.nvim_win_get_cursor(session.main_win))
      H.eq("● " .. env.oids[4]:sub(1, 8) .. "  c4 extend guide", lines(session.main_win)[1])
      H.eq(session.history.commits[2], session.tree:selected().commit)
      -- Past the second (last listed) commit, Tab loads page two and moves on.
      press("<Tab>")
      H.ok(shows(session, 3))
      H.eq(4, #session.history.commits)
      H.eq("c3 grow a", session.history.shown.subject)
      press("<S-Tab>")
      H.ok(shows(session, 2))
      press("]C")
      H.ok(shows(session, 3))
      press("[C")
      H.ok(shows(session, 2))
    end)
  end,

  ["the walk stops at both ends of the history"] = function()
    with_history({ count = 5 }, function(session, env)
      api.nvim_set_current_win(session.main_win)
      press("<S-Tab>")
      H.eq("Already at the newest commit", env.notes[#env.notes])
      for _ = 1, 4 do
        press("<Tab>")
        H.ok(shows(session, session.history.index))
      end
      H.eq("c1 add a", session.history.shown.subject)
      H.ok(lines(session.main_win)[4]:find("root commit", 1, true))
      press("<Tab>")
      H.eq("Already at the oldest commit", env.notes[#env.notes])
      H.ok(tree_lines(session)[#tree_lines(session)]:find("All 5 commits listed", 1, true))
    end)
  end,

  ["C-e and the last Files row load more commits"] = function()
    with_history(nil, function(session, env)
      api.nvim_set_current_win(session.main_win)
      press("<C-e>")
      H.ok(vim.wait(5000, function()
        return #session.history.commits == 4 and not session.history.busy
      end, 10))
      -- Paging never moves the commit on screen.
      H.eq(session.history.commits[1], session.history.shown)
      H.ok(vim.wo[session.main_win].winbar:find("[1/4+]", 1, true))
      api.nvim_set_current_win(session.tree.win)
      api.nvim_win_set_cursor(session.tree.win, { #session.tree.entries, 0 })
      H.eq(true, session.tree:selected().more)
      press("<CR>")
      H.ok(vim.wait(5000, function()
        return session.history.done and not session.history.busy
      end, 10))
      H.eq(5, #session.history.commits)
      H.eq(true, session.tree:selected().more)
      press("<C-e>")
      H.eq("All 5 commits are listed", env.notes[#env.notes])
    end)
  end,

  ["Enter on a Files commit shows it; on the shown commit it reads the message"] = function()
    with_history(nil, function(session, env)
      api.nvim_set_current_win(session.tree.win)
      local index
      for i, entry in ipairs(session.tree.entries) do
        if entry.commit == session.history.commits[2] then
          index = i
        end
      end
      api.nvim_win_set_cursor(session.tree.win, { index, 0 })
      press("<CR>")
      H.ok(shows(session, 2))
      H.eq(session.history.commits[2], session.tree:selected().commit)
      H.eq("c4 extend guide", session.history.shown.subject)
      api.nvim_set_current_win(session.tree.win)
      press("<CR>")
      H.eq(session.main_win, api.nvim_get_current_win())
      H.eq({ 1, 0 }, api.nvim_win_get_cursor(session.main_win))
      -- File rows under the shown commit still open that file in the document.
      api.nvim_set_current_win(session.tree.win)
      for i, entry in ipairs(session.tree.entries) do
        if entry.file then
          api.nvim_win_set_cursor(session.tree.win, { i, 0 })
          break
        end
      end
      press("<CR>")
      H.eq("file", session.rows[api.nvim_win_get_cursor(session.main_win)[1]].kind)
      H.eq(env.root, session.snapshot.root)
    end)
  end,

  ["za on the message hides bodies for every commit until shown again"] = function()
    with_history({ count = 5 }, function(session)
      api.nvim_set_current_win(session.main_win)
      for _ = 1, 3 do
        press("<Tab>")
        H.ok(shows(session, session.history.index))
      end
      H.eq("c2 add guide", session.history.shown.subject)
      local document = lines(session.main_win)
      H.ok(document[1]:find("▾", 1, true))
      H.eq({ "", "  Why the guide exists.", "", "  Second paragraph.", "" }, vim.list_slice(document, 5, 9))
      api.nvim_win_set_cursor(session.main_win, { 7, 0 })
      press("za")
      document = lines(session.main_win)
      H.ok(document[1]:find("▸", 1, true))
      H.eq("  … 3 message lines hidden · za shows", document[6])
      H.eq({ 1, 0 }, api.nvim_win_get_cursor(session.main_win))
      press("<S-Tab>")
      H.ok(shows(session, 3))
      press("<Tab>")
      H.ok(shows(session, 4))
      H.eq("  … 3 message lines hidden · za shows", lines(session.main_win)[6])
      press("za")
      H.eq("  Why the guide exists.", lines(session.main_win)[6])
    end)
  end,

  ["long message lines wrap to the document with hanging bullets"] = function()
    local root = vim.uv.fs_realpath(H.repo())
    H.write(root, "a.txt", { "a" })
    local words = string.rep("word ", 40)
    commit(root, "wide", "Paragraph " .. words .. "\n\n- bullet " .. words .. "\n    code " .. words)
    local previous_notify, previous_columns = vim.notify, vim.o.columns
    vim.notify = function() end
    vim.o.columns = 160
    local session = require("rill").open_history({ cwd = root, syntax = false, sidekick = false })
    local ok, err = pcall(function()
      H.ok(vim.wait(5000, function()
        return session.history.shown ~= nil and not session.history.loading
      end, 10))
      local body = vim.tbl_filter(function(line)
        return line:find("word", 1, true) ~= nil
      end, lines(session.main_win))
      local code = table.remove(body)
      H.eq("      code word", code:sub(1, 15))
      for _, line in ipairs(body) do
        H.ok(vim.fn.strdisplaywidth(line) <= 102, line)
      end
      local bullet
      for index, line in ipairs(body) do
        if line:find("- bullet", 1, true) then
          bullet = index
        end
      end
      H.eq("  - bullet word", body[bullet]:sub(1, 15))
      H.eq("    word", body[bullet + 1]:sub(1, 8))
    end)
    session:close()
    vim.notify, vim.o.columns = previous_notify, previous_columns
    vim.fn.delete(root, "rf")
    if not ok then
      error(err, 0)
    end
  end,

  ["za on a commit without a body leaves the next commit's message shown"] = function()
    with_history({ count = 5 }, function(session)
      api.nvim_set_current_win(session.main_win)
      api.nvim_win_set_cursor(session.main_win, { 1, 0 })
      press("za")
      H.eq(false, session.history.collapsed)
      for _ = 1, 3 do
        press("<Tab>")
        H.ok(shows(session, session.history.index))
      end
      H.eq("  Why the guide exists.", lines(session.main_win)[6])
    end)
  end,

  ["focus mode walks commits from each one's first file"] = function()
    with_history({ count = 5 }, function(session)
      api.nvim_set_current_win(session.main_win)
      api.nvim_win_set_cursor(session.main_win, { session.file_rows[session.files[1].meta.id], 0 })
      press("gf")
      H.eq(session.files[1].meta.id, session.focus_id)
      press("<Tab>")
      H.ok(shows(session, 2))
      H.eq("docs/guide.md", session.focus_id)
      -- The message heads the focused document, and the cursor opens on it.
      H.eq("commit", session.rows[1].kind)
      H.eq({ 1, 0 }, api.nvim_win_get_cursor(session.main_win))
      H.eq(1, vim.fn.line("w0", session.main_win))
    end)
  end,

  ["a step queued behind a page yields to a newer choice"] = function()
    with_history(nil, function(session)
      api.nvim_set_current_win(session.main_win)
      press("<Tab>")
      H.ok(shows(session, 2))
      -- Tab past the last listed commit waits for page two; S-Tab meanwhile.
      press("<Tab>")
      H.eq(true, session.history.busy)
      press("<S-Tab>")
      H.ok(vim.wait(5000, function()
        return #session.history.commits == 4 and not session.history.busy and not session.history.loading
      end, 10))
      vim.wait(50)
      H.eq(1, session.history.index)
      H.eq(session.history.commits[1], session.history.shown)
    end)
  end,

  ["walking from the split After pane opens its cursor on the message"] = function()
    with_history(nil, function(session)
      api.nvim_set_current_win(session.main_win)
      press("gs")
      api.nvim_set_current_win(session.right_win)
      api.nvim_win_set_cursor(session.right_win, { #session.rows, 0 })
      session:cursor_changed(api.nvim_win_get_buf(session.right_win))
      press("<Tab>")
      H.ok(shows(session, 2))
      H.eq({ 1, 0 }, api.nvim_win_get_cursor(session.right_win))
    end)
  end,

  ["tabs in a message expand to git's 8-column stops"] = function()
    local root = vim.uv.fs_realpath(H.repo())
    H.write(root, "a.txt", { "a" })
    commit(root, "tabs", "key\t= 1\nlonger_key\t= 2\n\tindented")
    local previous_notify = vim.notify
    vim.notify = function() end
    local session = require("rill").open_history({ cwd = root, syntax = false, sidekick = false })
    local ok, err = pcall(function()
      H.ok(vim.wait(5000, function()
        return session.history.shown ~= nil and not session.history.loading
      end, 10))
      H.eq(
        { "  key     = 1", "  longer_key      = 2", "          indented" },
        vim.list_slice(lines(session.main_win), 6, 8)
      )
    end)
    session:close()
    vim.notify = previous_notify
    vim.fn.delete(root, "rf")
    if not ok then
      error(err, 0)
    end
  end,

  ["message wrapping follows the layout being drawn"] = function()
    local root = vim.uv.fs_realpath(H.repo())
    H.write(root, "a.txt", { "a" })
    local line = "Ninety columns of prose " .. string.rep("x", 60) .. " end"
    commit(root, "wide", line)
    local previous_notify, previous_columns = vim.notify, vim.o.columns
    vim.notify = function() end
    vim.o.columns = 200
    local session = require("rill").open_history({ cwd = root, syntax = false, sidekick = false })
    local ok, err = pcall(function()
      H.ok(vim.wait(5000, function()
        return session.history.shown ~= nil and not session.history.loading
      end, 10))
      H.eq("  " .. line, lines(session.main_win)[6])
      api.nvim_set_current_win(session.main_win)
      press("gs")
      H.eq("  Ninety columns of prose", lines(session.main_win)[6])
      press("gs")
      H.eq("  " .. line, lines(session.main_win)[6])
    end)
    session:close()
    vim.notify, vim.o.columns = previous_notify, previous_columns
    vim.fn.delete(root, "rf")
    if not ok then
      error(err, 0)
    end
  end,

  ["folder history lists and diffs only its paths"] = function()
    with_history({ paths = { "src" }, count = 5 }, function(session)
      H.eq({ "c3 grow a", "c1 add a" }, subjects(session.history.commits))
      H.eq(true, session.history.done)
      H.eq(
        { "src/a.lua" },
        vim.tbl_map(function(file)
          return file.meta.path
        end, session.files)
      )
      H.eq("  1 file in src · +1 −0", lines(session.main_win)[6])
      H.ok(vim.wo[session.tree.win].winbar:find("History · src", 1, true))
    end)
  end,

  ["a followed file keeps its rename as a rename"] = function()
    with_history({ paths = { "docs/manual.md" }, follow = true }, function(session)
      H.eq("c5 rename guide", session.history.shown.subject)
      H.eq(1, #session.files)
      H.eq("R", session.files[1].meta.status:sub(1, 1))
      H.eq("docs/guide.md", session.files[1].meta.old_path)
      api.nvim_set_current_win(session.main_win)
      press("<Tab>")
      H.ok(shows(session, 2))
      press("<Tab>")
      H.ok(shows(session, 3))
      H.eq("c2 add guide", session.history.shown.subject)
      H.eq("docs/guide.md", session.files[1].meta.path)
    end)
  end,

  ["folding the shown commit's files holds while walking"] = function()
    with_history(nil, function(session)
      api.nvim_set_current_win(session.tree.win)
      api.nvim_win_set_cursor(session.tree.win, { 1, 0 })
      press("za")
      H.eq(3, #session.tree.entries)
      press("<Tab>")
      H.ok(shows(session, 2))
      -- Two folded commit rows and the paging row: no files drawn.
      H.eq(3, #session.tree.entries)
      H.ok(tree_lines(session)[2]:find("▸", 1, true))
      press("za")
      H.ok(#session.tree.entries > 3)
    end)
  end,

  ["Files context names history commits and their files' revision"] = function()
    with_history(nil, function(session, env)
      local function context(row)
        return require("rill.view").context({
          buf = session.tree.buf,
          win = session.tree.win,
          row = row,
          col = 1,
        })
      end
      local commit_row, file_row
      for i, entry in ipairs(session.tree.entries) do
        if entry.commit == session.history.commits[2] then
          commit_row = i
        elseif entry.file then
          file_row = i
        end
      end
      local commit_context = context(commit_row)
      H.eq(
        { { kind = "commit", revision = env.oids[4], subject = "c4 extend guide" } },
        commit_context.entries
      )
      H.eq(nil, commit_context.file)
      local file_context = context(file_row)
      H.eq(env.oids[5], file_context.entries[1].revision)
      H.eq("docs/manual.md", file_context.file.path)
    end)
  end,

  [":Rill log parses the start, --follow and paths"] = function()
    local rill = require("rill")
    local original = rill.open_history
    local seen
    rill.open_history = function(opts)
      seen = opts
    end
    local ok, err = pcall(function()
      rill.command({ "log", "v1.0", "--follow", "--", "docs/manual.md" })
      H.eq("v1.0", seen.rev)
      H.eq(true, seen.follow)
      H.eq({ "docs/manual.md" }, seen.paths)
      rill.command({ "history" })
      H.eq(nil, seen.rev)
    end)
    rill.open_history = original
    if not ok then
      error(err, 0)
    end
  end,

  ["an empty folder history explains itself"] = function()
    local root = fixture()
    local previous_notify = vim.notify
    vim.notify = function() end
    local session =
      require("rill").open_history({ cwd = root, paths = { "nowhere" }, syntax = false, sidekick = false })
    local ok, err = pcall(function()
      H.ok(vim.wait(5000, function()
        return session.error ~= nil
      end, 10))
      H.eq("No commits touch nowhere", lines(session.main_win)[1])
    end)
    session:close()
    vim.notify = previous_notify
    vim.fn.delete(root, "rf")
    if not ok then
      error(err, 0)
    end
  end,
}
