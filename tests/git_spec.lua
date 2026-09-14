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

return {
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
