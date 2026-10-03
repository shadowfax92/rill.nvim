local H = require("tests.helpers")
local Git = require("rill.git")

local function fixture(run)
  local root = H.repo()
  local ok, err = xpcall(function()
    run(root)
  end, debug.traceback)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

local function load(root, opts)
  return H.await(function(done)
    Git.load(vim.tbl_extend("force", { cwd = root }, opts or {}), done)
  end)
end

local function source(snapshot, file, side)
  return H.await(function(done)
    Git.source(snapshot, file, side, done)
  end)
end

local function get(snapshot, path)
  for _, file in ipairs(snapshot.files) do
    if file.path == path then
      return file
    end
  end
  error("Missing diff: " .. path)
end

local function bytes(root, path, text)
  local fd = assert(io.open(root .. "/" .. path, "wb"))
  fd:write(text)
  fd:close()
end

local function load_error(root, opts)
  local done, err, result = false, nil, nil
  Git.load(vim.tbl_extend("force", { cwd = root }, opts or {}), function(e, value)
    err, result, done = e, value, true
  end)
  assert(vim.wait(10000, function()
    return done
  end, 10), "async operation timed out")
  assert(result == nil, "expected the load to fail")
  return tostring(err)
end

local function commits(root, items, opts)
  return load(root, vim.tbl_extend("force", { mode = "commits", commits = items }, opts or {}))
end

local function paths(files)
  return vim.tbl_map(function(file)
    return file.path
  end, files)
end

-- R ← A ← { B on main, S on side } ← M, where M merges side into main (first
-- parent B). Marking S and B is the case a single cumulative range drops.
local function merge_history(root)
  local oids = {}
  H.write(root, "r", { "root" })
  oids.R = H.commit(root, "R root")
  H.write(root, "a", { "a" })
  oids.A = H.commit(root, "A adds a")
  H.command({ "git", "checkout", "-qb", "side" }, root)
  H.write(root, "s", { "side" })
  oids.S = H.commit(root, "S adds s")
  H.command({ "git", "checkout", "-q", "main" }, root)
  H.write(root, "b", { "main" })
  oids.B = H.commit(root, "B adds b")
  H.command({ "git", "merge", "--no-ff", "-qm", "M merges side", "side" }, root)
  oids.M = H.command({ "git", "rev-parse", "HEAD" }, root)
  return oids
end

return {
  commits_mode_reviews_each_commit_in_the_given_order = function()
    fixture(function(root)
      H.write(root, "a", { "one" })
      local first = H.commit(root, "first adds a")
      H.write(root, "b", { "two" })
      local second = H.commit(root, "second adds b")
      H.write(root, "c", { "three" })
      local third = H.commit(root, "third adds c")
      local snapshot = commits(root, { { rev = third }, { rev = first }, { rev = "HEAD~1" }, { rev = "HEAD" } })
      H.eq("3 commits", snapshot.label)
      H.eq({ third, first, second }, vim.tbl_map(function(group)
        return group.oid
      end, snapshot.groups))
      local group = snapshot.groups[1]
      H.eq(1, group.index)
      H.eq(third:sub(1, 8), group.short)
      H.eq("third adds c", group.subject)
      H.eq("Rill Tests", group.author)
      H.ok(group.date:match("^%d%d %a%a%a %d%d%d%d$"), group.date)
      H.eq({ second }, group.parents)
      H.eq(false, group.merge)
      H.eq(false, group.root_commit)
      H.eq(second, group.snapshot.left.rev)
      H.eq(third, group.snapshot.right.rev)
      H.eq(third:sub(1, 8) .. "^ → " .. third:sub(1, 8), group.snapshot.label)
      H.eq(snapshot.root, group.snapshot.root)
      H.eq(snapshot.groups[1].snapshot.left, snapshot.left)
      H.eq(snapshot.groups[3].snapshot.right, snapshot.right)
      H.eq({ "c", "a", "b" }, paths(snapshot.files))
      for index, file in ipairs(snapshot.files) do
        H.eq(index, file.group)
        H.eq(snapshot.groups[index].oid .. ":" .. file.path, file.id)
        H.eq({ file }, snapshot.groups[index].snapshot.files)
      end
      H.eq({ "two" }, source(snapshot.groups[3].snapshot, snapshot.files[3], "new").lines)
    end)
  end,

  commits_mode_keeps_both_sides_of_a_merge = function()
    fixture(function(root)
      local oids = merge_history(root)
      local snapshot = commits(root, { { rev = oids.S }, { rev = oids.B } })
      H.eq({ "s", "b" }, paths(snapshot.files))
      H.eq({ 1, 2 }, { snapshot.files[1].group, snapshot.files[2].group })
      H.eq(oids.A, snapshot.groups[1].snapshot.left.rev)
      H.eq(oids.A, snapshot.groups[2].snapshot.left.rev)
    end)
  end,

  commits_mode_diffs_a_merge_against_its_first_parent = function()
    fixture(function(root)
      local oids = merge_history(root)
      local snapshot = commits(root, { { rev = oids.M } })
      local group = snapshot.groups[1]
      H.eq("1 commit", snapshot.label)
      H.eq({ oids.B, oids.S }, group.parents)
      H.eq(true, group.merge)
      H.eq(false, group.root_commit)
      H.eq("M merges side", group.subject)
      H.eq(oids.B, group.snapshot.left.rev)
      H.eq({ "s" }, paths(snapshot.files))
    end)
  end,

  commits_mode_compares_a_root_commit_with_the_empty_tree = function()
    fixture(function(root)
      local oids = merge_history(root)
      local snapshot = commits(root, { { rev = oids.R }, { rev = oids.A } })
      local group = snapshot.groups[1]
      H.eq({}, group.parents)
      H.eq(true, group.root_commit)
      H.eq(false, group.merge)
      H.eq("empty", group.snapshot.left.kind)
      H.eq("empty tree → " .. oids.R:sub(1, 8), group.snapshot.label)
      H.eq(group.snapshot.left, snapshot.left)
      H.eq({ "r", "a" }, paths(snapshot.files))
      H.eq("A", snapshot.files[1].status)
      H.eq({}, source(group.snapshot, snapshot.files[1], "old").lines)
      H.eq({ "root" }, source(group.snapshot, snapshot.files[1], "new").lines)
      H.eq(oids.R, snapshot.groups[2].snapshot.left.rev)
    end)
  end,

  commits_mode_shows_an_add_and_its_revert_as_two_files = function()
    fixture(function(root)
      H.write(root, "x", { "keep" })
      H.commit(root)
      H.write(root, "x", { "keep", "tmp" })
      local added = H.commit(root, "Y adds tmp")
      H.write(root, "x", { "keep" })
      local reverted = H.commit(root, "Z reverts Y")
      local snapshot = commits(root, { { rev = added }, { rev = reverted } })
      H.eq({ "x", "x" }, paths(snapshot.files))
      H.eq(added .. ":x", snapshot.files[1].id)
      H.eq(reverted .. ":x", snapshot.files[2].id)
      H.ok(snapshot.files[1].patch:find("\n+tmp\n", 1, true))
      H.ok(snapshot.files[2].patch:find("\n-tmp\n", 1, true))
      H.eq({ "keep", "tmp" }, source(snapshot.groups[2].snapshot, snapshot.files[2], "old").lines)
    end)
  end,

  commits_mode_item_paths_override_default_paths_and_keep_renames = function()
    fixture(function(root)
      H.write(root, "old.txt", { "one", "two", "three", "four" })
      H.write(root, "other.txt", { "other" })
      H.commit(root)
      H.command({ "git", "mv", "old.txt", "new.txt" }, root)
      H.write(root, "new.txt", { "one", "changed", "three", "four" })
      H.write(root, "other.txt", { "other", "renamed alongside" })
      local renamed = H.commit(root, "rename old to new")
      H.write(root, "new.txt", { "one", "changed", "three", "four", "five" })
      H.write(root, "other.txt", { "other", "renamed alongside", "later" })
      local later = H.commit(root, "touch both")
      local snapshot = commits(root, {
        { rev = renamed, paths = { "new.txt", "old.txt" } },
        { rev = later },
      }, { paths = { "other.txt" } })
      local first, second = snapshot.groups[1], snapshot.groups[2]
      H.eq({ "new.txt", "old.txt" }, first.snapshot.options.paths)
      H.eq({ "other.txt" }, second.snapshot.options.paths)
      H.eq({ "other.txt" }, snapshot.options.paths)
      H.eq({ "new.txt" }, paths(first.snapshot.files))
      local file = first.snapshot.files[1]
      H.eq("R", file.status)
      H.eq("old.txt", file.old_path)
      H.eq({ "one", "two", "three", "four" }, source(first.snapshot, file, "old").lines)
      H.eq({ "other.txt" }, paths(second.snapshot.files))
    end)
  end,

  commits_mode_shares_one_patch_budget_across_commits = function()
    fixture(function(root)
      H.write(root, "seed", { "seed" })
      H.commit(root)
      local body = {}
      for line = 1, 12 do
        body[line] = ("line %02d %s"):format(line, string.rep("x", 40))
      end
      H.write(root, "first", body)
      local first = H.commit(root)
      H.write(root, "second", body)
      local second = H.commit(root)
      local alone = commits(root, { { rev = second } }, { max_patch_bytes = 1000 })
      H.eq(nil, alone.files[1].omitted_reason)
      local snapshot = commits(root, { { rev = first }, { rev = second } }, { max_patch_bytes = 1000 })
      H.eq(nil, snapshot.files[1].omitted_reason)
      H.ok(#snapshot.files[1].patch > 500)
      H.eq("Review exceeds max_patch_bytes (1000)", snapshot.files[2].omitted_reason)
      H.eq("", snapshot.files[2].patch)
    end)
  end,

  commits_mode_fails_whole_load_on_one_bad_rev = function()
    fixture(function(root)
      H.write(root, "a", { "one" })
      H.commit(root)
      H.write(root, "a", { "two" })
      H.commit(root)
      local err = load_error(root, { mode = "commits", commits = { "HEAD", "no-such-rev", "HEAD~1" } })
      H.ok(err:find("no-such-rev", 1, true), err)
      err = load_error(root, { mode = "commits", commits = {} })
      H.ok(err:find("at least one commit", 1, true), err)
      local tree = H.command({ "git", "rev-parse", "HEAD^{tree}" }, root)
      err = load_error(root, { mode = "commits", commits = { { rev = tree } } })
      H.ok(err:find(tree, 1, true), err)
    end)
  end,

  commits_mode_cancel_kills_the_in_flight_job_and_stops_the_chain = function()
    fixture(function(root)
      for index = 1, 3 do
        H.write(root, "file" .. index, { tostring(index) })
        H.commit(root)
      end
      local system = vim.system
      local spawned, diffs, called = 0, 0, false
      local cancel, stalled, signal, exited
      -- Process spawning is the boundary under test: the second commit's diff is
      -- swapped for a long sleep so it is reliably still running at cancel time.
      vim.system = function(command, opts, on_exit)
        spawned = spawned + 1
        local is_diff = vim.tbl_contains(command, "diff")
        diffs = diffs + (is_diff and 1 or 0)
        local stall = is_diff and diffs == 2
        local job = system(stall and { "sleep", "5" } or command, opts, function(out)
          if stall then
            exited = out
          end
          on_exit(out)
        end)
        if stall then
          stalled = job
          local kill = job.kill
          job.kill = function(self, value)
            signal = value
            return kill(self, value)
          end
          vim.schedule(cancel)
        end
        return job
      end
      local ok, err = pcall(function()
        cancel = Git.load({ cwd = root, mode = "commits", commits = { "HEAD~2", "HEAD~1", "HEAD" } }, function()
          called = true
        end)
        H.ok(vim.wait(5000, function()
          return exited ~= nil
        end, 10), "the stalled diff was never killed")
        local after_cancel = spawned
        vim.wait(200, function()
          return false
        end, 10)
        H.ok(stalled)
        H.eq(15, signal)
        H.eq(15, exited.signal)
        H.eq(2, diffs)
        H.eq(after_cancel, spawned)
        H.eq(false, called)
      end)
      vim.system = system
      assert(ok, err)
    end)
  end,
  working_includes_staged_unstaged_and_untracked = function()
    fixture(function(root)
      H.write(root, "file.txt", { "base" })
      H.commit(root)
      H.write(root, "file.txt", { "index" })
      H.command({ "git", "add", "file.txt" }, root)
      H.write(root, "file.txt", { "worktree" })
      H.write(root, "new.txt", { "new" })
      local snapshot = load(root)
      H.eq(2, #snapshot.files)
      H.eq("commit", snapshot.left.kind)
      H.eq("worktree", snapshot.right.kind)
      H.eq({ "base" }, source(snapshot, get(snapshot, "file.txt"), "old").lines)
      H.eq({ "worktree" }, source(snapshot, get(snapshot, "file.txt"), "new").lines)
      H.eq("?", get(snapshot, "new.txt").status)
      H.eq({}, source(snapshot, get(snapshot, "new.txt"), "old").lines)
      H.ok(get(snapshot, "file.txt").patch:find("+worktree", 1, true))
    end)
  end,

  index_sources_remain_pinned_after_index_changes = function()
    fixture(function(root)
      H.write(root, "a", { "base" })
      H.commit(root)
      H.write(root, "a", { "staged snapshot" })
      H.command({ "git", "add", "a" }, root)
      local staged = load(root, { mode = "staged" })
      H.write(root, "a", { "unstaged snapshot" })
      local unstaged = load(root, { mode = "unstaged" })
      H.write(root, "a", { "later change" })
      H.command({ "git", "add", "a" }, root)
      H.eq({ "staged snapshot" }, source(staged, staged.files[1], "new").lines)
      H.eq({ "staged snapshot" }, source(unstaged, unstaged.files[1], "old").lines)
      H.eq("index", staged.right.kind)
      H.eq("index", unstaged.left.kind)
      H.ok(unstaged.files[1].patch:find("+unstaged snapshot", 1, true))
    end)
  end,

  nul_paths_include_spaces_tabs_newlines_unicode_and_quotes = function()
    fixture(function(root)
      local paths = {
        "space name",
        "tab\tname",
        "newline\nname",
        'quote"and\\slash',
        "日本語.lua",
        "-option",
        ":(glob)*",
      }
      for _, path in ipairs(paths) do
        H.write(root, path, { "before" })
      end
      H.commit(root)
      for _, path in ipairs(paths) do
        H.write(root, path, { "after" })
      end
      local snapshot = load(root)
      H.eq(#paths, #snapshot.files)
      for _, path in ipairs(paths) do
        local file = get(snapshot, path)
        H.eq(nil, file.omitted_reason, "patch omitted for " .. path)
        H.eq(1, file.additions)
        H.eq(1, file.deletions)
        H.ok(file.patch:find("+after", 1, true))
        H.eq({ "before" }, source(snapshot, file, "old").lines)
      end
      local filtered = load(root, { paths = { ":(glob)*" } })
      H.eq(1, #filtered.files)
      H.eq(":(glob)*", filtered.files[1].path)
    end)
  end,

  rename_retains_old_path_and_exact_sources = function()
    fixture(function(root)
      H.write(root, "old\nname", { "one", "two", "three", "four" })
      H.commit(root)
      H.command({ "git", "mv", "old\nname", "new\tname" }, root)
      H.write(root, "new\tname", { "one", "changed", "three", "four" })
      H.command({ "git", "add", "--all" }, root)
      local snapshot = load(root, { mode = "staged" })
      H.eq(1, #snapshot.files)
      local file = snapshot.files[1]
      H.eq("R", file.status)
      H.eq("old\nname", file.old_path)
      H.eq("new\tname", file.path)
      H.eq(nil, file.omitted_reason)
      H.eq({ "one", "two", "three", "four" }, source(snapshot, file, "old").lines)
      H.eq({ "one", "changed", "three", "four" }, source(snapshot, file, "new").lines)
    end)
  end,

  empty_repo_and_root_commit_use_object_format_empty_tree = function()
    fixture(function(root)
      H.eq(0, #load(root).files)
      H.write(root, "first", { "hello" })
      local unborn = load(root)
      H.eq("empty", unborn.left.kind)
      H.eq(1, #unborn.files)
      H.command({ "git", "add", "." }, root)
      local staged = load(root, { mode = "staged" })
      H.eq("A", staged.files[1].status)
      H.eq({ "hello" }, source(staged, staged.files[1], "new").lines)
      local commit = H.commit(root)
      local snapshot = load(root, { mode = "commit", rev = commit })
      H.eq("empty", snapshot.left.kind)
      H.eq("A", snapshot.files[1].status)
      H.eq({}, source(snapshot, snapshot.files[1], "old").lines)
      H.eq({ "hello" }, source(snapshot, snapshot.files[1], "new").lines)
      local empty = H.command({ "git", "hash-object", "-t", "tree", "--stdin" }, root)
      local range = load(root, { mode = "range", base = empty, head = commit })
      H.eq("empty", range.left.kind)
      H.eq({ "hello" }, source(range, range.files[1], "new").lines)
    end)
  end,

  range_and_branch_compare_pinned_commits = function()
    fixture(function(root)
      H.write(root, "a", { "base" })
      local base = H.commit(root)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      H.write(root, "a", { "feature" })
      local head = H.commit(root)
      local branch = load(root, { mode = "branch", base = "main" })
      H.eq(base, branch.left.rev)
      H.eq(head, branch.right.rev)
      H.command({ "git", "checkout", "-q", "main" }, root)
      H.write(root, "a", { "main after branching" })
      local main = H.commit(root)
      local direct = load(root, { mode = "range", base = main, head = "feature" })
      local merged = load(root, { mode = "range", base = main, head = "feature", merge_base = true })
      H.eq({ "main after branching" }, source(direct, direct.files[1], "old").lines)
      H.eq({ "base" }, source(merged, merged.files[1], "old").lines)
      H.eq({ "feature" }, source(branch, branch.files[1], "new").lines)
    end)
  end,

  commit_mode_uses_first_parent_for_merges = function()
    fixture(function(root)
      H.write(root, "base", { "one" })
      H.commit(root)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      H.write(root, "feature", { "feature" })
      H.commit(root)
      H.command({ "git", "checkout", "-q", "main" }, root)
      H.write(root, "main", { "main" })
      local parent = H.commit(root)
      H.command({ "git", "merge", "--no-ff", "-qm", "merge", "feature" }, root)
      local snapshot = load(root, { mode = "commit", rev = "HEAD" })
      H.eq(parent, snapshot.left.rev)
      H.eq(1, #snapshot.files)
      H.eq("feature", snapshot.files[1].path)
    end)
  end,

  source_preserves_crlf_and_missing_final_newline = function()
    fixture(function(root)
      bytes(root, "a", "one\r\ntwo\r\n")
      H.commit(root)
      bytes(root, "a", "one\r\nchanged")
      bytes(root, "new", "first\r\nsecond")
      local snapshot = load(root)
      local old = source(snapshot, get(snapshot, "a"), "old")
      local new = source(snapshot, get(snapshot, "a"), "new")
      H.eq("one\r\ntwo\r\n", old.text)
      H.eq({ "one", "two" }, old.lines)
      H.eq(true, old.eol)
      H.eq(true, old.crlf)
      H.eq("one\r\nchanged", new.text)
      H.eq(false, new.eol)
      H.ok(get(snapshot, "a").patch:find("one\r\n", 1, true))
      H.ok(get(snapshot, "new").patch:find("+first\r\n+second\n\\ No newline at end of file", 1, true))
    end)
  end,

  untracked_empty_and_blank_lines_synthesize_valid_patches = function()
    fixture(function(root)
      bytes(root, "empty", "")
      bytes(root, "blank", "\n\nlast\n")
      local snapshot = load(root)
      H.eq(0, get(snapshot, "empty").additions)
      H.eq({}, source(snapshot, get(snapshot, "empty"), "new").lines)
      H.ok(not get(snapshot, "empty").patch:find("@@", 1, true))
      H.eq(3, get(snapshot, "blank").additions)
      H.ok(get(snapshot, "blank").patch:find("+\n+\n+last\n", 1, true))
    end)
  end,

  binary_mode_only_submodule_and_deleted_entries_remain_visible = function()
    fixture(function(root)
      bytes(root, "binary", "one\0two")
      H.write(root, "mode", { "same" })
      H.write(root, "removed", { "gone" })
      local parent = H.commit(root)
      bytes(root, "binary", "one\0changed")
      H.command({ "chmod", "+x", "mode" }, root)
      H.command({ "git", "rm", "-q", "removed" }, root)
      H.command({ "git", "update-index", "--add", "--cacheinfo", "160000," .. parent .. ",module" }, root)
      bytes(root, "new-binary", "hello\0world")
      local snapshot = load(root)
      H.eq(true, get(snapshot, "binary").binary)
      H.eq(true, get(snapshot, "new-binary").binary)
      local staged = load(root, { mode = "staged" })
      H.eq(true, get(staged, "module").submodule)
      H.eq(0, get(snapshot, "mode").additions)
      H.eq(nil, get(snapshot, "mode").omitted_reason)
      H.ok(get(snapshot, "mode").patch:find("old mode 100644", 1, true))
      H.eq("D", get(snapshot, "removed").status)
      H.eq({}, source(snapshot, get(snapshot, "removed"), "new").lines)
    end)
  end,

  symlinks_read_the_link_target_without_dereferencing = function()
    fixture(function(root)
      H.write(root, "target", { "contents must not leak into link source" })
      assert(vim.uv.fs_symlink("target", root .. "/link"))
      H.commit(root)
      assert(vim.uv.fs_unlink(root .. "/link"))
      assert(vim.uv.fs_symlink("missing-target", root .. "/link"))
      assert(vim.uv.fs_symlink("target", root .. "/new-link"))
      local snapshot = load(root)
      H.eq({ "target" }, source(snapshot, get(snapshot, "link"), "old").lines)
      H.eq({ "missing-target" }, source(snapshot, get(snapshot, "link"), "new").lines)
      H.eq({ "target" }, source(snapshot, get(snapshot, "new-link"), "new").lines)
    end)
  end,

  stream_omits_large_bodies_but_keeps_following_files = function()
    fixture(function(root)
      H.write(root, "a-huge", { "old" })
      H.write(root, "b-small", { "old" })
      H.commit(root)
      bytes(root, "a-huge", string.rep("x", 512 * 1024) .. "\n")
      H.write(root, "b-small", { "new" })
      local snapshot = load(root, { max_file_bytes = 1024 })
      H.ok(get(snapshot, "a-huge").omitted_reason:find("max_file_bytes", 1, true))
      H.eq("", get(snapshot, "a-huge").patch)
      H.eq(nil, get(snapshot, "b-small").omitted_reason)
      H.ok(get(snapshot, "b-small").patch:find("+new", 1, true))
      H.eq({ "new" }, source(snapshot, get(snapshot, "b-small"), "new").lines)
    end)
  end,

  cancelled_load_and_source_do_not_deliver_callbacks = function()
    fixture(function(root)
      H.write(root, "a", { "old" })
      H.commit(root)
      H.write(root, "a", { "new" })
      local called = false
      local cancel = Git.load({ cwd = root }, function()
        called = true
      end)
      cancel()
      vim.wait(120, function()
        return false
      end, 10)
      H.eq(false, called)
      local snapshot = load(root)
      cancel = Git.source(snapshot, snapshot.files[1], "old", function()
        called = true
      end)
      cancel()
      vim.wait(120, function()
        return false
      end, 10)
      H.eq(false, called)
    end)
  end,

  forced_binary_and_type_changes_never_publish_partial_code = function()
    fixture(function(root)
      H.write(root, ".gitattributes", { "binary diff" })
      bytes(root, "binary", "old\0value")
      assert(vim.uv.fs_symlink("binary", root .. "/link"))
      H.commit(root)
      bytes(root, "binary", "new\0value")
      assert(vim.uv.fs_unlink(root .. "/link"))
      H.write(root, "link", { "now a regular file" })
      local snapshot = load(root)
      H.eq(true, get(snapshot, "binary").binary)
      H.eq("", get(snapshot, "binary").patch)
      H.eq("T", get(snapshot, "link").status)
      H.ok(get(snapshot, "link").omitted_reason:find("File type changed", 1, true))
    end)
  end,

  source_and_changed_line_limits_are_explicit = function()
    fixture(function(root)
      H.write(root, "a", { "one", "two", "three", "four" })
      H.commit(root)
      H.write(root, "a", { "ONE", "TWO", "THREE", "FOUR" })
      local snapshot = load(root, { max_changed_lines = 2 })
      H.ok(snapshot.files[1].omitted_reason:find("max_changed_lines", 1, true))
      snapshot = load(root, { max_source_lines = 2 })
      local done, received = false, nil
      Git.source(snapshot, snapshot.files[1], "new", function(err)
        received, done = err, true
      end)
      H.ok(vim.wait(5000, function()
        return done
      end, 10))
      H.ok(received:find("max_source_lines", 1, true))
    end)
  end,

  unmerged_paths_do_not_misassign_later_patches = function()
    fixture(function(root)
      H.write(root, "a-conflict", { "base" })
      H.write(root, "z-safe", { "old" })
      H.commit(root)
      H.command({ "git", "checkout", "-qb", "other" }, root)
      H.write(root, "a-conflict", { "other" })
      H.commit(root)
      H.command({ "git", "checkout", "-q", "main" }, root)
      H.write(root, "a-conflict", { "main" })
      H.commit(root)
      local merged = vim.system({ "git", "merge", "other" }, { cwd = root }):wait()
      H.eq(1, merged.code)
      H.write(root, "z-safe", { "new" })
      local snapshot = load(root, { mode = "unstaged" })
      H.eq(2, #snapshot.files)
      H.eq("U", get(snapshot, "a-conflict").status)
      H.ok(get(snapshot, "a-conflict").omitted_reason)
      H.eq(nil, get(snapshot, "z-safe").omitted_reason)
      H.ok(get(snapshot, "z-safe").patch:find("+new", 1, true))
    end)
  end,
}
