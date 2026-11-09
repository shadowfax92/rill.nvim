-- Real review sessions and Git jobs exercise base selection across presentation,
-- refresh, ref updates and teardown. Only the user's picker decision is injected.
local H = require("tests.helpers")
local api = vim.api

local function wait_for(predicate, message)
  H.ok(vim.wait(3000, predicate, 5), message)
end

-- Keep Git and the session real; intercept only the user decision so callbacks
-- can arrive after cancellation, another picker, refresh or session teardown.
local function fixture(run, opts)
  local root = H.repo()
  local previous_select = vim.ui.select
  local picks, session = {}, nil
  vim.ui.select = function(items, options, choose)
    picks[#picks + 1] = { items = items, options = options, choose = choose }
  end
  local ok, err = xpcall(function()
    H.write(root, "src/file.lua", { "base" })
    local base = H.commit(root)
    H.command({ "git", "update-ref", "refs/remotes/origin/main", base }, root)
    H.command({ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, root)
    H.command({ "git", "checkout", "-qb", "feature" }, root)
    H.write(root, "src/file.lua", { "feature" })
    local head = H.commit(root)
    H.command({ "git", "update-ref", "refs/remotes/origin/feature", head }, root)
    session = require("rill").open_branch(vim.tbl_extend("force", {
      cwd = root,
      base = "origin/feature",
      syntax = false,
      sidekick = false,
      paths = { "src" },
      view = "focus",
    }, opts or {}))
    wait_for(function()
      return session.snapshot ~= nil
    end, "initial review did not load")
    run(session, picks, root)
  end, debug.traceback)
  if session then
    session:close()
  end
  vim.ui.select = previous_select
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

local function pick(session, picks, win)
  api.nvim_set_current_win(win or session.main_win)
  local binding = vim.fn.maparg("gb", "n", false, true)
  H.eq("function", type(binding.callback), "gb must work in this review pane")
  local count = #picks
  binding.callback()
  wait_for(function()
    return #picks > count
  end, "base picker did not open")
  return picks[#picks]
end

local function named(picker, label)
  for _, item in ipairs(picker.items) do
    if item.label == label then
      return item
    end
  end
  error("missing base choice: " .. label)
end

return {
  a_ref_deleted_after_listing_keeps_the_previous_comparison_refreshable = function()
    fixture(function(session, picks, root)
      local picker = pick(session, picks)
      local snapshot, base = session.snapshot, session.opts.base
      H.command({ "git", "update-ref", "-d", "refs/remotes/origin/main" }, root)
      local previous_notify = vim.notify
      vim.notify = function() end
      local ok, err = xpcall(function()
        picker.choose(named(picker, "origin/main"))
        wait_for(function()
          return session.error ~= nil
        end, "the removed ref did not report a load failure")
        H.eq(snapshot, session.snapshot, "a failed pick retains the review")
        H.eq(base, session.opts.base, "refresh must keep the last successful base")
        session:load()
        wait_for(function()
          return session.snapshot ~= snapshot
        end, "the previous comparison could not refresh")
        H.eq("origin/feature", session.snapshot.left.label)
      end, debug.traceback)
      vim.notify = previous_notify
      assert(ok, err)
    end)
  end,

  direct_base_revisions_follow_ref_updates_on_refresh_but_gm_stays_pinned = function()
    fixture(function(session, _, root)
      vim.cmd.runtime("plugin/rill.lua")
      vim.cmd("RillBase origin/main")
      wait_for(function()
        return session.snapshot.left.label == "origin/main"
      end, "direct base did not load")
      H.eq("picked", session.snapshot.left.base_source)
      local base = session.snapshot.left.rev
      local head = H.command({ "git", "rev-parse", "HEAD" }, root)
      H.command({ "git", "update-ref", "refs/remotes/origin/main", head }, root)
      local snapshot = session.snapshot
      session:toggle_commits()
      wait_for(function()
        return session.snapshot ~= snapshot
      end, "gm did not complete")
      H.eq(base, session.snapshot.left.rev, "gm retains the resolved comparison")
      snapshot = session.snapshot
      session:load()
      wait_for(function()
        return session.snapshot ~= snapshot
      end, "refresh did not complete")
      H.eq(head, session.snapshot.left.rev, "gr follows the selected ref's new tip")
      H.eq(0, #session.files)
      H.ok(session.rows[1].text:find("origin/main (picked)", 1, true), session.rows[1].text)
      H.ok(session.rows[1].text:find("gb picks another base", 1, true))
      H.command({ "git", "tag", "review-start", base }, root)
      require("rill").select_base("review-start")
      wait_for(function()
        return session.snapshot.left.label == "review-start"
      end, "tag base did not load")
      H.eq(base, session.snapshot.left.rev)
    end)
  end,

  a_picker_updates_its_original_session_after_the_user_changes_tabs = function()
    fixture(function(session, picks, root)
      local picker = pick(session, picks)
      local other =
        require("rill").open_branch({ cwd = root, base = "origin/feature", syntax = false, sidekick = false })
      local ok, err = xpcall(function()
        wait_for(function()
          return other.snapshot ~= nil
        end, "second review did not load")
        local untouched = other.snapshot
        picker.choose(named(picker, "origin/main"))
        wait_for(function()
          return session.snapshot.left.label == "origin/main"
        end, "original session did not change")
        H.eq(untouched, other.snapshot, "the foreground session must not receive another session's pick")
        H.eq("origin/feature", other.snapshot.left.label)
      end, debug.traceback)
      other:close()
      assert(ok, err)
    end)
  end,

  empty_review_can_change_base_from_tree_and_both_split_panes = function()
    fixture(function(session, picks, root)
      H.eq(0, #session.files)
      local tab, snapshot, generation = session.tab, session.snapshot, session.generation
      for _, win in ipairs({ session.main_win, session.right_win, session.tree.win }) do
        local picker = pick(session, picks, win)
        H.ok(picker.options.prompt:find("Compare base", 1, true))
        H.ok(picker.options.format_item(named(picker, "origin/main")):find("default", 1, true))
        H.ok(picker.options.format_item(named(picker, "origin/feature")):find("in use", 1, true))
        H.ok(picker.options.format_item(named(picker, "origin/feature")):find("= HEAD, no commits", 1, true))
        H.eq("origin/feature", picker.items[1].label, "the base in use is pinned first")
        for _, item in ipairs(picker.items) do
          H.eq(nil, item.label:find("/HEAD", 1, true), "symbolic aliases are not base choices")
          H.eq(false, item.ref == "refs/heads/feature", "the checked-out local branch is omitted")
        end
        picker.choose(nil)
        H.eq(generation, session.generation, "cancel does not reload")
        H.eq(snapshot, session.snapshot, "cancel leaves the review intact")
      end
      local picker = pick(session, picks)
      picker.choose(named(picker, "origin/main"))
      wait_for(function()
        return session.snapshot ~= snapshot
      end, "new base did not load")
      H.eq(tab, session.tab)
      H.eq(tab, api.nvim_get_current_tabpage())
      H.eq("split", session.layout)
      H.eq("commits", session.snapshot.commits_view)
      H.eq({ "src" }, session.opts.paths)
      H.eq(1, #session.files)
      H.ok(session.focus_id, "changing base from an empty focused review focuses the first file")
      H.ok(session.snapshot.label:find("Branch feature vs origin/main", 1, true), session.snapshot.label)
      H.eq("feature", H.command({ "git", "branch", "--show-current" }, root), "picking does not checkout")
      local selected = session.snapshot
      session:load()
      wait_for(function()
        return session.snapshot ~= selected
      end, "selected base did not refresh")
      H.eq("origin/main", session.snapshot.left.label)
      selected = session.snapshot
      session:toggle_commits()
      wait_for(function()
        return session.snapshot ~= selected
      end, "presentation did not switch")
      H.eq("origin/main", session.snapshot.left.label)
      H.eq("combined", session.snapshot.commits_view)
    end, { layout = "split", commits_view = "commits" })
  end,

  picker_survives_refresh_but_old_or_closed_picker_choices_are_ignored = function()
    fixture(function(session, picks)
      local first = pick(session, picks)
      local second = pick(session, picks)
      local generation = session.generation
      first.choose(named(first, "origin/main"))
      H.eq(generation, session.generation, "the newer picker owns the decision")
      local snapshot = session.snapshot
      session:load()
      wait_for(function()
        return session.snapshot ~= snapshot
      end, "refresh did not finish")
      generation = session.generation
      second.choose(named(second, "origin/main"))
      H.eq(generation + 1, session.generation, "an open picker survives a refresh of its session")
      wait_for(function()
        return session.snapshot.left.label == "origin/main"
      end, "base selection did not finish")
      local last = pick(session, picks)
      session:close()
      generation = session.generation
      last.choose(named(last, "origin/main"))
      H.eq(generation, session.generation, "closed reviews ignore delayed choices")
    end)
  end,
}
