-- Real Git histories distinguish declared/default bases from misleading equal-tip
-- aliases and merged child branches; inventory checks cover large repositories.
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

local function remote(root, name, oid)
  H.command({ "git", "config", "remote.origin.url", "." }, root)
  H.command({ "git", "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" }, root)
  H.command({ "git", "update-ref", "refs/remotes/origin/" .. name, oid }, root)
end

local function load(root, opts)
  return H.await(function(done)
    Git.load(vim.tbl_extend("force", { cwd = root, mode = "branch" }, opts or {}), done)
  end)
end

local function paths(snapshot)
  return vim.tbl_map(function(file)
    return file.path
  end, snapshot.files)
end

return {
  base_choices_pin_useful_refs_and_sort_the_remainder_without_per_ref_processes = function()
    fixture(function(root)
      local function commit_at(date)
        H.command({ "git", "add", "--all" }, root)
        local result = vim
          .system({ "git", "commit", "-qm", "dated fixture" }, {
            cwd = root,
            env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date },
          })
          :wait()
        H.eq(0, result.code, result.stderr)
        return H.command({ "git", "rev-parse", "HEAD" }, root)
      end
      H.write(root, "base", { "base" })
      local base = commit_at("2025-01-01T00:00:00Z")
      remote(root, "main", base)
      H.command({ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, root)
      H.command({ "git", "branch", "in-use" }, root)
      H.command({ "git", "branch", "aaa-old" }, root)
      H.command({ "git", "checkout", "-qb", "parent" }, root)
      H.write(root, "parent", { "parent" })
      local parent = commit_at("2025-02-01T00:00:00Z")
      remote(root, "parent", parent)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      H.write(root, "feature", { "feature" })
      local head = commit_at("2025-03-01T00:00:00Z")
      remote(root, "feature", head)
      H.command({ "git", "branch", "zzz-new" }, root)
      H.command({ "git", "branch", "--set-upstream-to=origin/feature" }, root)
      H.command({ "git", "config", "branch.feature.gh-merge-base", "parent" }, root)
      local updates = {}
      for i = 1, 400 do
        updates[#updates + 1] = ("update refs/remotes/origin/old-%d %s"):format(i, base)
      end
      H.eq(
        0,
        vim
          .system({ "git", "update-ref", "--stdin" }, { cwd = root, stdin = table.concat(updates, "\n") .. "\n" })
          :wait().code
      )
      local original, count = vim.system, 0
      vim.system = function(args, ...)
        count = count + (args[1] == "git" and 1 or 0)
        return original(args, ...)
      end
      local ok, choices = pcall(H.await, function(done)
        Git.bases(
          { cwd = root, head = head, left = { ref = "refs/heads/in-use", label = "in-use", rev = base } },
          done
        )
      end)
      vim.system = original
      assert(ok, choices)
      H.ok(count <= 3, "listing 400+ refs spawned " .. count .. " Git jobs")
      local labels = vim.tbl_map(function(item)
        return item.label
      end, choices)
      H.eq({ "in-use", "origin/parent", "origin/main", "origin/feature" }, vim.list_slice(labels, 1, 4))
      local indices = {}
      for i, item in ipairs(choices) do
        indices[item.label] = i
      end
      H.ok(indices["zzz-new"] < indices["aaa-old"], "recent refs precede alphabetically earlier old refs")
      H.eq(nil, indices.feature)
      H.eq(nil, indices["origin/HEAD"])
      H.ok(vim.tbl_contains(choices[4].hints, "upstream · unpushed only"))
      H.ok(vim.tbl_contains(choices[4].hints, "= HEAD, no commits"))
    end)
  end,

  merged_child_refs_cannot_be_mistaken_for_the_integration_branch_base = function()
    fixture(function(root)
      H.write(root, "base", { "base" })
      local base = H.commit(root)
      remote(root, "main", base)
      H.command({ "git", "checkout", "-qb", "integration" }, root)
      H.write(root, "integration", { "own" })
      H.commit(root)
      H.command({ "git", "checkout", "-qb", "child" }, root)
      H.write(root, "child", { "merged child" })
      local child = H.commit(root)
      remote(root, "child", child)
      H.command({ "git", "checkout", "-q", "integration" }, root)
      H.write(root, "later", { "integration continues" })
      H.commit(root)
      H.command({ "git", "merge", "--no-ff", "-qm", "merge child", "child" }, root)
      local snapshot = load(root)
      H.eq("origin/main", snapshot.left.label)
      H.eq("default", snapshot.left.base_source)
      H.eq(base, snapshot.left.rev)
      H.eq({ "child", "integration", "later" }, paths(snapshot))
    end)
  end,

  gh_merge_base_preserves_stacks_prefers_origin_and_never_writes_config = function()
    fixture(function(root)
      H.write(root, "base", { "base" })
      local base = H.commit(root)
      remote(root, "main", base)
      H.command({ "git", "checkout", "-qb", "parent" }, root)
      H.write(root, "parent", { "parent" })
      local parent = H.commit(root)
      remote(root, "parent", parent)
      H.write(root, "local-parent", { "unpushed parent" })
      local local_parent = H.commit(root)
      H.command({ "git", "checkout", "-qb", "child" }, root)
      H.write(root, "child", { "child" })
      H.commit(root)
      H.command({ "git", "config", "branch.child.gh-merge-base", "parent" }, root)
      local config = vim.fn.readfile(root .. "/.git/config")
      local snapshot = load(root)
      H.eq(parent, snapshot.left.rev)
      H.eq("origin/parent", snapshot.left.label)
      H.eq("gh-merge-base", snapshot.left.base_source)
      H.eq({ "child", "local-parent" }, paths(snapshot))
      H.eq(base, load(root, { base = "origin/main" }).left.rev, "an explicit base wins over gh config")
      H.command({ "git", "update-ref", "-d", "refs/remotes/origin/parent" }, root)
      H.eq(local_parent, load(root).left.rev, "a local stacked parent is a valid fallback")
      H.eq(config, vim.fn.readfile(root .. "/.git/config"), "base discovery is read-only")
    end)
  end,

  branch_defaults_to_origin_main_despite_an_equal_tip_feature_ref = function()
    fixture(function(root)
      H.write(root, "base", { "base" })
      local base = H.commit(root)
      remote(root, "main", base)
      H.command({ "git", "checkout", "-qb", "feat/claw-sdk-v2" }, root)
      H.write(root, "feature", { "committed" })
      local head = H.commit(root)
      remote(root, "feat/neo-hooks", head)
      remote(root, "feat/claw-sdk-v2", head)
      H.command({ "git", "branch", "--set-upstream-to=origin/feat/claw-sdk-v2" }, root)
      for _, symbolic in ipairs({ false, true }) do
        if symbolic then
          H.command({ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, root)
        end
        for _, presentation in ipairs({ "combined", "commits" }) do
          local snapshot = load(root, { commits_view = presentation })
          H.eq("origin/main", snapshot.left.label)
          H.eq(base, snapshot.left.rev)
          H.eq({ "feature" }, paths(snapshot))
        end
      end
    end)
  end,

  remote_default_is_authoritative_and_an_explicit_local_base_overrides_it = function()
    fixture(function(root)
      H.command({ "git", "branch", "-m", "trunk" }, root)
      H.write(root, "base", { "base" })
      local base = H.commit(root)
      remote(root, "trunk", base)
      H.command({ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk" }, root)
      H.write(root, "local-trunk", { "unpushed" })
      local trunk = H.commit(root)
      H.command({ "git", "checkout", "-qb", "feature" }, root)
      H.write(root, "feature", { "committed" })
      H.commit(root)
      local snapshot = load(root)
      H.eq("origin/trunk", snapshot.left.label)
      H.eq(base, snapshot.left.rev)
      H.eq({ "feature", "local-trunk" }, paths(snapshot))
      local explicit = load(root, { base = "trunk" })
      H.eq(trunk, explicit.left.rev)
      H.eq({ "feature" }, paths(explicit))
    end)
  end,

  stacked_reviews_choose_their_parent_explicitly = function()
    fixture(function(root)
      H.write(root, "base", { "base" })
      local base = H.commit(root)
      remote(root, "main", base)
      H.command({ "git", "checkout", "-qb", "parent" }, root)
      H.write(root, "parent", { "parent" })
      local parent = H.commit(root)
      H.command({ "git", "checkout", "-qb", "child" }, root)
      H.write(root, "child", { "child" })
      H.commit(root)
      H.eq({ "child", "parent" }, paths(load(root)))
      local explicit = load(root, { base = "parent" })
      H.eq(parent, explicit.left.rev)
      H.eq({ "child" }, paths(explicit))
    end)
  end,
}
