local H = require("tests.helpers")
local Git = require("rill.git")

local function fixture(run)
  local root = H.repo()
  local snapshots = {}
  local function load(opts)
    local snapshot = H.await(function(done)
      Git.load(
        vim.tbl_extend("force", { cwd = root, mode = "branch", commits_view = "commits" }, opts or {}),
        done
      )
    end)
    snapshots[#snapshots + 1] = snapshot
    return snapshot
  end
  local ok, err = xpcall(function()
    run(root, load)
  end, debug.traceback)
  for _, snapshot in ipairs(snapshots) do
    if snapshot.dispose then
      snapshot.dispose()
    end
  end
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

local function paths(snapshot)
  return vim.tbl_map(function(file)
    return file.path
  end, snapshot.files)
end

return {
  branch_octopus_and_old_git_explicitly_fall_back = function()
    fixture(function(root, load)
      H.write(root, "a", { "base" })
      local base = H.commit(root)
      for _, name in ipairs({ "side1", "side2", "feature" }) do
        H.command({ "git", "checkout", "-qb", name, base }, root)
        H.write(root, name, { name })
        H.commit(root)
      end
      H.command({ "git", "merge", "--no-ff", "-qm", "octopus", "side1", "side2" }, root)
      local snapshot = load({ base = base })
      local merge = snapshot.groups[#snapshot.groups]
      H.eq("octopus merge · vs 1st parent", merge.note)
      H.eq({ "side1", "side2" }, paths(merge.snapshot))
      H.command({ "git", "checkout", "-q", "main" }, root)
      H.write(root, "trunk", { "trunk" })
      H.commit(root)
      H.command({ "git", "checkout", "-q", "feature" }, root)
      H.command({ "git", "merge", "--no-ff", "-qm", "merge main", "main" }, root)
      local original = vim.system
      vim.system = function(args, ...)
        if vim.tbl_contains(args, "merge-tree") then
          args = vim.list_extend({}, args)
          args[#args + 1] = "--rill-unsupported-option"
        end
        return original(args, ...)
      end
      local ok, fallback = pcall(load, { base = base })
      vim.system = original
      assert(ok, fallback)
      local last = fallback.groups[#fallback.groups]
      H.eq("merge-tree unavailable · vs 1st parent", last.note)
      H.eq({ "trunk" }, paths(last.snapshot))
    end)
  end,

  branch_batch_handles_single_byte_chunks_and_shared_patch_budget = function()
    fixture(function(root, load)
      H.write(root, "a", { "base" })
      H.commit(root)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      local name = "odd\nname\t.lua"
      H.write(root, name, { "one" })
      H.commit(root)
      H.command({ "git", "commit", "--allow-empty", "-qm", "empty" }, root)
      H.write(root, "z", { string.rep("x", 4000) })
      H.commit(root)
      H.write(root, "a", { "dirty" })
      local original = vim.system
      vim.system = function(args, opts, done)
        if vim.tbl_contains(args, "diff-tree") then
          local stdout = opts.stdout
          opts.stdout = function(err, data)
            if data then
              for i = 1, #data do
                stdout(err, data:sub(i, i))
              end
            else
              stdout(err, data)
            end
          end
        end
        return original(args, opts, done)
      end
      local ok, snapshot = pcall(load, { max_patch_bytes = 1500, max_file_bytes = 10000 })
      vim.system = original
      assert(ok, snapshot)
      H.eq(4, #snapshot.groups)
      H.eq({ name }, paths(snapshot.groups[1].snapshot))
      H.eq({}, snapshot.groups[2].snapshot.files)
      H.ok(snapshot.groups[3].snapshot.files[1].omitted_reason:find("max_patch_bytes", 1, true))
      H.eq("uncommitted", snapshot.groups[4].kind)
      H.eq(nil, snapshot.groups[4].snapshot.files[1].omitted_reason)
    end)
  end,
  branch_marker_without_commits_and_clean_history = function()
    fixture(function(root, load)
      H.write(root, "a", { "base" })
      H.commit(root)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      H.write(root, "a", { "dirty" })
      local dirty = load()
      H.eq(1, #dirty.groups)
      H.eq("uncommitted", dirty.groups[1].kind)
      H.command({ "git", "checkout", "--", "a" }, root)
      H.eq(0, #load().groups)
      H.write(root, "a", { "committed" })
      local oid = H.commit(root)
      local clean = load()
      H.eq(1, #clean.groups)
      H.eq(oid, clean.groups[1].oid)
    end)
  end,

  branch_trunk_compares_unpushed_commits_with_upstream = function()
    fixture(function(root, load)
      H.write(root, "a", { "base" })
      local base = H.commit(root)
      H.command({ "git", "update-ref", "refs/remotes/origin/main", base }, root)
      H.command({ "git", "config", "remote.origin.url", "." }, root)
      H.command({ "git", "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" }, root)
      H.command({ "git", "config", "branch.main.remote", "origin" }, root)
      H.command({ "git", "config", "branch.main.merge", "refs/heads/main" }, root)
      H.write(root, "a", { "unpushed" })
      local oid = H.commit(root)
      H.write(root, "a", { "dirty" })
      local snapshot = load()
      H.eq(base, snapshot.branch.left.rev)
      H.eq(oid, snapshot.groups[1].oid)
      H.eq("uncommitted", snapshot.groups[2].kind)
    end)
  end,

  branch_clean_merge_is_empty_and_commit_selection_is_unchanged = function()
    fixture(function(root, load)
      H.write(root, "a", { "base" })
      H.commit(root)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      H.write(root, "feature", { "own" })
      local first = H.commit(root)
      H.command({ "git", "checkout", "-q", "main" }, root)
      H.write(root, "trunk", { "trunk" })
      H.commit(root)
      H.command({ "git", "checkout", "-q", "feature" }, root)
      H.command({ "git", "merge", "--no-ff", "-qm", "merge main", "main" }, root)
      local oid = H.command({ "git", "rev-parse", "HEAD" }, root)
      local snapshot = load()
      H.eq(2, #snapshot.groups)
      H.eq(first, snapshot.groups[1].oid)
      local merge = snapshot.groups[2]
      H.eq(oid, merge.oid)
      H.eq(true, merge.auto_merge)
      H.eq("no changes of its own", merge.note)
      H.eq({}, merge.snapshot.files)
      H.eq({ "trunk" }, paths(load({ mode = "commits", commits = { oid } })))
      local directory = merge.snapshot.git_env.GIT_OBJECT_DIRECTORY
      H.eq(1, vim.fn.isdirectory(directory))
      snapshot.dispose()
      H.eq(0, vim.fn.isdirectory(directory))
    end)
  end,

  branch_merge_resolution_uses_private_auto_merge_blobs = function()
    fixture(function(root, load)
      H.write(root, "a", { "base" })
      H.commit(root)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      H.write(root, "a", { "branch" })
      H.commit(root)
      H.command({ "git", "checkout", "-q", "main" }, root)
      H.write(root, "a", { "trunk" })
      H.commit(root)
      H.command({ "git", "checkout", "-q", "feature" }, root)
      local merge = vim.system({ "git", "merge", "main" }, { cwd = root }):wait()
      H.eq(1, merge.code)
      H.write(root, "a", { "resolved" })
      H.commit(root, "resolve main")
      local objects_before = H.command({ "git", "count-objects", "-v" }, root)
      local snapshot = load()
      local group = snapshot.groups[2]
      H.ok(group.auto_merge)
      H.eq({ "a" }, paths(group.snapshot))
      local file = group.snapshot.files[1]
      H.ok(file.patch:find("+resolved", 1, true))
      H.ok(file.patch:find("-<<<<<<<", 1, true))
      local old = H.await(function(done)
        Git.source(group.snapshot, file, "old", done)
      end)
      H.ok(old.text:find("<<<<<<<", 1, true))
      H.eq(objects_before, H.command({ "git", "count-objects", "-v" }, root))
    end)
  end,

  branch_hundred_commits_merge_and_marker_use_bounded_git_processes = function()
    fixture(function(root, load)
      H.write(root, "a", { "base" })
      H.commit(root)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      for i = 1, 100 do
        H.write(root, "a", { tostring(i) })
        H.commit(root, "commit " .. i)
      end
      H.command({ "git", "checkout", "-q", "main" }, root)
      H.write(root, "trunk", { "upstream" })
      H.commit(root)
      H.command({ "git", "checkout", "-q", "feature" }, root)
      H.command({ "git", "merge", "--no-ff", "-qm", "merge main", "main" }, root)
      H.write(root, "a", { "dirty" })
      H.write(root, "untracked", { "new" })
      local combined = load({ commits_view = "combined" })
      local original, count, commands = vim.system, 0, {}
      vim.system = function(args, ...)
        if args[1] == "git" then
          count = count + 1
          commands[#commands + 1] = table.concat(args, " ")
        end
        return original(args, ...)
      end
      local ok, snapshot = pcall(load, { _branch = combined.branch })
      vim.system = original
      assert(ok, snapshot)
      H.ok(count <= 9, "Expected at most 9 Git processes, got " .. count)
      H.ok(not table.concat(commands, "\n"):find("for-each-ref", 1, true), "gm reran base detection")
      H.eq(102, #snapshot.groups)
      H.eq("commit 1", snapshot.groups[1].subject)
      H.eq("commit 100", snapshot.groups[100].subject)
      H.eq("no changes of its own", snapshot.groups[101].note)
      H.eq("uncommitted", snapshot.groups[102].kind)
      H.eq({ "a", "untracked" }, paths(snapshot.groups[102].snapshot))
    end)
  end,
  branch_groups_include_dirty_and_untracked_last = function()
    fixture(function(root, load)
      H.write(root, "a", { "base" })
      local base = H.commit(root)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      H.write(root, "a", { "one" })
      local first = H.commit(root, "first")
      H.write(root, "a", { "two" })
      local second = H.commit(root, "second")
      H.write(root, "a", { "dirty" })
      H.write(root, "untracked", { "new" })
      local snapshot = load()
      H.eq("commits", snapshot.commits_view)
      H.eq(base, snapshot.branch.left.rev)
      H.eq(3, #snapshot.groups)
      H.eq(first, snapshot.groups[1].oid)
      H.eq(second, snapshot.groups[2].oid)
      H.eq("uncommitted", snapshot.groups[3].kind)
      H.eq({ "a", "untracked" }, paths(snapshot.groups[3].snapshot))
      H.eq(second, snapshot.groups[3].snapshot.left.rev)
    end)
  end,
}
