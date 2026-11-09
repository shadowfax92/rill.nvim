local H = require("tests.helpers")
local api = vim.api

local function file(path, status, group)
  return { meta = { id = (group or "") .. path, path = path, status = status or "M", group = group } }
end

-- Exercise real Neovim windows: resize events, local defaults and buffer maps
-- are the sidebar's contract, independent of Git or the review document rows.
local function with_tree(fn)
  local previous, columns, mini = api.nvim_get_current_tabpage(), vim.o.columns, rawget(_G, "MiniIcons")
  local buffers = api.nvim_list_bufs()
  vim.o.columns = 160
  vim.cmd("tabnew")
  local tab, anchor = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
  local Tree = dofile("lua/rill/tree.lua")
  local trees = {}
  local function create(opts)
    local tree = Tree.new(vim.tbl_extend("force", { id = "test" .. #trees, initial_width = 30 }, opts or {}))
    trees[#trees + 1] = tree
    tree:open(anchor)
    return tree
  end
  local ok, err = xpcall(function()
    fn(create, anchor)
  end, debug.traceback)
  for _, tree in ipairs(trees) do
    tree:dispose()
  end
  if api.nvim_tabpage_is_valid(tab) then
    api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose!")
  end
  api.nvim_set_current_tabpage(previous)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not vim.tbl_contains(buffers, buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.o.columns = columns
  _G.MiniIcons = mini
  assert(ok, err)
end

local function lines(tree)
  return api.nvim_buf_get_lines(tree.buf, 0, -1, false)
end

local function key(tree, lhs)
  api.nvim_set_current_win(tree.win)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  H.eq("function", type(mapping.callback), lhs)
  mapping.callback()
end

return {
  toggle_all_reopens_individually_closed_commits_in_one_press = function()
    with_tree(function(create)
      local tree = create()
      tree:update({
        files = { file("src/a.lua", "M", 1), file("tests/b.lua", "M", 2) },
        groups = {
          { oid = "aaa", short = "aaa", subject = "First" },
          { oid = "bbb", short = "bbb", subject = "Second" },
        },
      })
      local expanded = lines(tree)
      for group = 1, 2 do
        for row, entry in ipairs(tree.entries) do
          if entry.group == group then
            api.nvim_win_set_cursor(tree.win, { row, 0 })
            key(tree, "za")
            break
          end
        end
      end
      H.eq(2, #tree.entries)
      key(tree, "zA")
      H.eq(expanded, lines(tree), "a visibly closed tree opens in one press, including its hidden folders")
    end)
  end,

  all_folds_can_be_closed_and_reopened_from_the_sidebar = function()
    with_tree(function(create)
      local tree = create()
      tree:update({
        files = {
          file("src/deep/a.lua", "M", 1),
          file("src/deep/b.lua", "A", 1),
          file("other/c.lua", "M", 2),
        },
        groups = { { short = "aaaa1111", subject = "First" }, { short = "bbbb2222", subject = "Second" } },
      })
      local expanded = lines(tree)
      H.ok(#expanded > 2)
      api.nvim_win_set_cursor(tree.win, { 3, 0 })
      key(tree, "zA")
      H.eq(2, #tree.entries)
      H.eq("@aaaa1111", tree:selected().key, "collapse keeps the cursor on its visible ancestor")
      key(tree, "zA")
      H.eq(expanded, lines(tree), "toggle all restores the merged directory chains")
      key(tree, "zM")
      H.eq(2, #tree.entries, "collapse all must fold both commits and their hidden directories")
      key(tree, "zR")
      H.eq(expanded, lines(tree), "expand all must reopen the full hierarchy")
    end)
  end,

  recursive_node_folds_do_not_touch_sibling_commits = function()
    with_tree(function(create)
      local tree = create()
      tree:update({
        files = {
          file("src/deep/a.lua", "M", 1),
          file("src/other/b.lua", "M", 1),
          file("tests/c.lua", "M", 2),
        },
        groups = { { short = "aaaa1111", subject = "First" }, { short = "bbbb2222", subject = "Second" } },
      })
      local expanded = lines(tree)
      api.nvim_win_set_cursor(tree.win, { 1, 0 })
      key(tree, "zC")
      H.eq(true, tree.folded["@aaaa1111/src"])
      H.eq(nil, tree.folded["@bbbb2222"])
      key(tree, "zo")
      H.eq(nil, tree.folded["@aaaa1111"])
      H.eq(true, tree.folded["@aaaa1111/src"], "opening one node preserves descendant folds")
      key(tree, "zO")
      H.eq(expanded, lines(tree))
      key(tree, "zc")
      H.eq(true, tree.folded["@aaaa1111"])
    end)
  end,

  folded_commits_keep_their_identity_when_new_commits_are_inserted = function()
    with_tree(function(create)
      local tree = create()
      local a, b = file("a.lua", "M", 1), file("b.lua", "M", 2)
      local groups = {
        { oid = "aaa", short = "aaa", subject = "First" },
        { oid = "bbb", short = "bbb", subject = "Second" },
      }
      tree:update({ files = { a, b }, groups = groups })
      api.nvim_win_set_cursor(tree.win, { 3, 0 })
      key(tree, "za")
      table.insert(groups, 1, { oid = "new", short = "new", subject = "Inserted" })
      a.meta.group, b.meta.group = 2, 3
      tree:update({ files = { file("new.lua", "A", 1), a, b }, groups = groups })
      H.eq(true, tree.folded["@bbb"])
      H.eq(nil, tree.folded["@aaa"])
      H.eq("@bbb", tree:selected().key)
      H.eq("▸ 3/3 bbb Second", lines(tree)[#tree.entries])
    end)
  end,

  file_navigation_highlights_the_closed_parent_without_expanding_it = function()
    with_tree(function(create)
      require("rill.highlight").colors()
      local tree = create()
      local a, b = file("src/a.lua", "M", 1), file("src/b.lua", "M", 1)
      tree:update({
        files = { a, b },
        groups = { { short = "aaaa1111", subject = "First" } },
        current_file = b.meta.id,
      })
      key(tree, "zM")
      tree:highlight(b.meta.id)
      H.eq(1, #tree.entries)
      local highlighted = false
      for _, mark in
        ipairs(
          api.nvim_buf_get_extmarks(
            tree.buf,
            api.nvim_create_namespace("rill.tree"),
            0,
            -1,
            { details = true }
          )
        )
      do
        highlighted = highlighted or (mark[2] == 0 and mark[4].line_hl_group == "RillTreeCurrent")
      end
      H.ok(highlighted, "the current file's closed parent remains identifiable")
    end)
  end,

  a_smaller_screen_clamps_manual_width_without_forgetting_it = function()
    with_tree(function(create)
      local tree = create()
      tree:update({ files = { file("a.lua") } })
      api.nvim_win_set_width(tree.win, 80)
      tree:render()
      H.eq(80, api.nvim_win_get_width(tree.win), "native resizing ignores the automatic cap")
      vim.o.columns = 100
      tree:render()
      H.eq(59, api.nvim_win_get_width(tree.win))
      key(tree, "}") -- a no-op at this screen's maximum must preserve the wider preference
      vim.o.columns = 160
      tree:render()
      H.eq(80, api.nvim_win_get_width(tree.win))
    end)
  end,

  nvimtree_width_keys_can_grow_beyond_the_automatic_content_limit = function()
    with_tree(function(create, anchor)
      local tree = create({ options = { max_width = 48, max_ratio = 0.3 } })
      tree:update({ files = { file("directory-with-a-long-name/another-long-name/file.lua") } })
      H.eq(48, api.nvim_win_get_width(tree.win))
      key(tree, "}")
      H.eq(53, api.nvim_win_get_width(tree.win), "manual widening must not use the automatic content cap")
      key(tree, "{")
      H.eq(48, api.nvim_win_get_width(tree.win))
      key(tree, "}")
      tree:close()
      tree:open(anchor)
      H.eq(53, api.nvim_win_get_width(tree.win), "manual width survives closing and reopening")
    end)
  end,

  adaptive_width_is_bounded_and_keeps_filenames_and_commit_sha = function()
    with_tree(function(create)
      local tree = create({ options = { max_width = 48, max_ratio = 0.3 } })
      tree:update({
        files = { file("long-directory-name/another-long-directory-name/provision.rs", "A", 1) },
        groups = { { short = "a449ac8a", subject = "Useful change with a very long commit subject" } },
      })
      H.eq(48, api.nvim_win_get_width(tree.win))
      local text = lines(tree)
      H.ok(text[1]:find("a449ac8a", 1, true))
      H.ok(text[1]:find("…", 1, true))
      H.ok(text[#text]:find("provision.rs", 1, true))
      for _, line in ipairs(text) do
        H.ok(vim.fn.strdisplaywidth(line) <= 48, line)
      end
      vim.o.columns = 80
      api.nvim_exec_autocmds("VimResized", {})
      H.ok(vim.wait(1000, function()
        return api.nvim_win_get_width(tree.win) <= 24
      end, 1))
      H.ok(lines(tree)[#text]:find("provision.rs", 1, true))
    end)
  end,

  manual_width_survives_keys_native_resize_close_and_new_reviews = function()
    with_tree(function(create, anchor)
      local first = create()
      first:update({ files = { file("a.lua") } })
      key(first, ">")
      H.eq(35, api.nvim_win_get_width(first.win))
      api.nvim_win_set_width(first.win, 43) -- same resize event as dragging the separator
      api.nvim_exec_autocmds("WinResized", {})
      H.ok(vim.wait(1000, function()
        return first.width == 43
      end, 1))
      first:close()
      first:open(anchor)
      H.eq(43, api.nvim_win_get_width(first.win))
      first:dispose()
      local second = create()
      second:update({ files = { file("long-directory/another-directory/file.lua") } })
      H.eq(43, api.nvim_win_get_width(second.win))
      api.nvim_win_call(second.win, function()
        vim.cmd("vertical resize -3")
      end)
      second:close() -- capture native resize even before WinResized is delivered
      second:open(anchor)
      H.eq(40, api.nvim_win_get_width(second.win))
      api.nvim_win_call(anchor, function()
        vim.cmd("vsplit")
      end)
      vim.cmd("wincmd =")
      H.eq(40, api.nvim_win_get_width(second.win))
    end)
  end,

  tree_options_remain_local_and_defeat_late_number_autocmds = function()
    with_tree(function(create, anchor)
      api.nvim_set_option_value("relativenumber", true, { win = anchor, scope = "global" })
      local tree = create()
      api.nvim_set_current_win(tree.win)
      api.nvim_set_option_value("relativenumber", true, { win = tree.win, scope = "local" })
      api.nvim_exec_autocmds("BufEnter", { buffer = tree.buf })
      H.ok(vim.wait(1000, function()
        return not vim.wo[tree.win].relativenumber
      end, 1))
      H.eq(false, vim.wo[tree.win].number)
      H.eq("no", vim.wo[tree.win].signcolumn)
      H.eq("", vim.wo[tree.win].statuscolumn)
      H.eq(true, vim.wo[tree.win].winfixwidth)
      H.eq(true, api.nvim_get_option_value("relativenumber", { win = tree.win, scope = "global" }))
      H.eq(false, vim.bo[tree.buf].buflisted)
    end)
  end,

  file_icons_status_colors_and_current_highlight_keep_real_path_identities = function()
    with_tree(function(create)
      _G.MiniIcons = {
        get = function(kind, path)
          H.eq("file", kind)
          H.ok(path:find(".lua", 1, true))
          return "F", "Identifier"
        end,
      }
      require("rill.highlight").colors()
      local tree = create()
      local added, renamed = file("src/naïve.lua", "A"), file("src/renamed.lua", "R")
      tree:update({ files = { added, renamed }, current_file = renamed.meta.id })
      H.ok(lines(tree)[2]:find("F + naïve.lua", 1, true))
      H.ok(lines(tree)[3]:find("F ➜ renamed.lua", 1, true))
      H.eq(added, tree.entries[2].file)
      local found = {}
      for _, mark in
        ipairs(
          api.nvim_buf_get_extmarks(
            tree.buf,
            api.nvim_create_namespace("rill.tree"),
            0,
            -1,
            { details = true }
          )
        )
      do
        local details = mark[4]
        found[details.hl_group or details.line_hl_group] = true
      end
      H.ok(found.Identifier and found.RillTreeAdded and found.RillTreeRenamed and found.RillTreeCurrent)
    end)
  end,

  replacing_the_panel_with_a_file_releases_window_ownership = function()
    with_tree(function(create, anchor)
      api.nvim_set_option_value("number", true, { win = anchor, scope = "global" })
      local tree = create()
      local win = tree.win
      local buf = api.nvim_create_buf(true, false)
      api.nvim_buf_set_lines(buf, 0, -1, false, { "ordinary editing" })
      api.nvim_win_set_buf(win, buf)
      api.nvim_exec_autocmds("WinResized", {})
      vim.wait(10, function()
        return false
      end, 1)
      H.eq(true, vim.wo[win].number, "scheduled panel hooks must not decorate a replacement file")
      tree:close()
      H.ok(api.nvim_win_is_valid(win), "panel close must not close a replacement file")
      H.eq(buf, api.nvim_win_get_buf(win))
    end)
  end,

  resize_preserves_commit_node_selection_instead_of_its_first_file = function()
    with_tree(function(create)
      local tree = create()
      tree:update({
        files = { file("src/a.lua", "A", 1) },
        groups = { { short = "abcdef12", subject = "Change" } },
      })
      api.nvim_win_set_cursor(tree.win, { 1, 0 })
      key(tree, ">")
      H.eq("@abcdef12", tree:selected().key, "resizing must leave the selected commit node selected")
      key(tree, "za")
      H.eq(1, #tree.entries)
    end)
  end,

  familiar_keys_select_fold_navigate_and_close_only_the_panel = function()
    with_tree(function(create, anchor)
      local selected
      local tree = create({
        on_select = function(entry)
          selected = entry.file.meta.path
        end,
      })
      tree:update({ files = { file("src/a.lua"), file("src/b.lua") } })
      api.nvim_win_set_cursor(tree.win, { 2, 0 })
      key(tree, "o")
      H.eq("src/a.lua", selected)
      key(tree, "h")
      H.eq(1, api.nvim_win_get_cursor(tree.win)[1])
      key(tree, "h")
      H.eq(1, #tree.entries)
      key(tree, "l")
      H.eq(3, #tree.entries)
      key(tree, "g?")
      H.ok(api.nvim_get_current_win() ~= tree.win)
      H.ok(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Widen", 1, true))
      vim.cmd("close")
      key(tree, "q")
      H.eq(nil, tree.win)
      H.ok(api.nvim_win_is_valid(anchor))
    end)
  end,
}
