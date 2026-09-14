local H = require("tests.helpers")
local Adapter = require("rill.sidekick")

local function context()
  return {
    root = "/repo",
    file = { path = "src/new.lua", old_path = "src/old.lua" },
    spans = {
      {
        path = "src/old.lua",
        absolute_path = "/repo/src/old.lua",
        side = "old",
        revision = "abc123",
        start_line = 143,
        end_line = 144,
        start_col = 0,
        end_col = 14,
        lines = { "local old = 1", "return old" },
      },
      {
        path = "src/new.lua",
        absolute_path = "/repo/src/new.lua",
        side = "new",
        revision = "def456",
        start_line = 143,
        end_line = 143,
        start_col = 6,
        end_col = 9,
        lines = { "new" },
      },
      {
        path = "tests/new.lua",
        absolute_path = "/repo/tests/new.lua",
        side = "new",
        revision = "worktree",
        start_line = 8,
        end_line = 8,
        start_col = 0,
        end_col = 11,
        lines = { "assert(new)" },
      },
    },
  }
end

-- Optional integration coverage uses an installed Sidekick fork without setup,
-- agent discovery, network calls, real delivery, or writes to draft storage.
local function sidekick_available()
  if vim.env.RILL_SIDEKICK_PATH then
    vim.opt.runtimepath:append(vim.env.RILL_SIDEKICK_PATH)
  else
    local checkout = vim.fn.expand("~/code/hacks/shadowfax-sidekick.nvim")
    if vim.fn.isdirectory(checkout) == 1 then
      vim.opt.runtimepath:append(checkout)
    end
  end
  if #vim.api.nvim_get_runtime_file("lua/sidekick/cli/init.lua", false) == 0 then
    print("SKIP optional Sidekick integration: set RILL_SIDEKICK_PATH to a Sidekick checkout")
    return false
  end
  return true
end

return {
  mixed_source_spans_keep_their_paths_revisions_and_selected_text = function()
    H.eq(
      table.concat({
        "@src/old.lua :L143-L144 (old, abc123)",
        "```",
        "local old = 1",
        "return old",
        "```",
        "",
        "@src/new.lua :L143 (new, def456)",
        "```",
        "new",
        "```",
        "",
        "@tests/new.lua :L8 (new, worktree)",
        "```",
        "assert(new)",
        "```",
      }, "\n"),
      Adapter.format(context())
    )
    H.ok(Adapter.format(context(), { absolute = true }):find("@/repo/src/old.lua :L143", 1, true))
  end,

  file_context_is_path_only_and_deduplicates_selection = function()
    local selected = context()
    selected.spans[#selected.spans + 1] = vim.deepcopy(selected.spans[1])
    H.eq("@src/old.lua\n@src/new.lua\n@tests/new.lua", Adapter.format(selected, { kind = "file" }))
    selected.spans = {}
    H.eq("@/repo/src/new.lua", Adapter.format(selected, { kind = "file", absolute = true }))
    H.eq("", Adapter.format(selected))
    H.eq("", Adapter.format(nil))
  end,

  snippets_cannot_close_their_fence_or_expand_context_tokens = function()
    local selected = context()
    selected.spans = { selected.spans[1] }
    selected.spans[1].path = 'odd "name\n.lua'
    selected.spans[1].lines = { "````lua", "{line} and `text`", "```" }
    local rendered = Adapter.format(selected)
    H.ok(rendered:find('@"odd \\"name\\n.lua" :L143-L144', 1, true), rendered)
    H.ok(rendered:find("\n`````\n````lua\n{line} and `text`\n```\n`````", 1, true), rendered)
  end,

  mappings_are_local_and_attachment_does_not_load_sidekick = function()
    local loaded = package.loaded["sidekick.cli"]
    local global = vim.api.nvim_get_keymap("n")
    local buf = vim.api.nvim_create_buf(false, true)
    Adapter.attach(buf)
    H.eq(loaded, package.loaded["sidekick.cli"])
    H.eq(global, vim.api.nvim_get_keymap("n"))
    H.eq(9, #vim.api.nvim_buf_get_keymap(buf, "n"))
    H.eq(9, #vim.api.nvim_buf_get_keymap(buf, "x"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end,

  real_sidekick_captures_preview_and_later_delivers_the_same_snapshot = function()
    if not sidekick_available() then
      return
    end
    local Config = require("sidekick.config")
    local State = require("sidekick.cli.state")
    local Comment = require("sidekick.cli.ui.comment")
    local Drafts = require("sidekick.cli.comment_drafts")
    local Text = require("sidekick.text")
    local Util = require("sidekick.util")
    local saved = {
      rill = package.loaded.rill,
      with = State.with,
      open = Comment.open,
      mark_sent = Drafts.mark_sent,
      info = Util.info,
      warn = Util.warn,
      token = Config.cli.context.rill_review,
      buf = vim.api.nvim_get_current_buf(),
    }
    local buf = vim.api.nvim_create_buf(false, true)
    local fixture = context()
    local captured, opened, delivered, draft_message, dispatch
    local ok, err = xpcall(function()
      vim.api.nvim_buf_set_name(buf, "rill://sidekick-integration-test")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "file header", "local old = 1", "return old", "new" })
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.cmd("normal! Vj")
      package.loaded.rill = {
        context = function(ctx)
          captured = ctx
          return fixture
        end,
      }
      Config.cli.context.rill_review = function()
        return "previous token"
      end
      local previous = Config.cli.context.rill_review
      local notified
      Util.warn = function(message)
        notified = message
      end
      Util.info = function() end
      Comment.open = function(opts)
        opened = opts
      end
      Drafts.mark_sent = function(_, _, message)
        draft_message = message
      end
      State.with = function(use, opts)
        dispatch = opts
        use({
          tool = {
            format = function(_, text)
              return Text.to_string(text)
            end,
          },
          session = {
            send = function(_, message)
              delivered = message
            end,
          },
        })
      end

      local expected = Adapter.format(fixture, { absolute = true })
      H.ok(Adapter.send({ comment = true, absolute = true, filter = { name = "codex" }, focus = false }))
      H.eq(nil, notified)
      H.eq(buf, captured.buf)
      H.eq({ from = { 2, 0 }, to = { 3, vim.v.maxcol }, kind = "line" }, captured.range)
      H.eq(expected, table.concat(H.ok(opened).context_lines, "\n"))
      H.eq(previous, Config.cli.context.rill_review)

      -- Simulate an agent refresh and a popup moving focus after context capture.
      fixture.spans[1].lines[1] = "changed after popup"
      fixture.spans[1].revision = "new revision"
      vim.api.nvim_set_current_buf(saved.buf)
      opened.cb("Please explain this change", {})
      H.ok(vim.wait(1000, function()
        return delivered ~= nil
      end, 10))
      H.eq("> Please explain this change\n\n" .. expected, draft_message)
      H.eq(draft_message .. "\n", delivered)
      H.eq({ name = "codex" }, dispatch.filter)
      H.eq(false, dispatch.focus)
      H.eq(true, dispatch.multicast)
    end, debug.traceback)

    package.loaded.rill = saved.rill
    State.with = saved.with
    Comment.open = saved.open
    Drafts.mark_sent = saved.mark_sent
    Util.info = saved.info
    Util.warn = saved.warn
    Config.cli.context.rill_review = saved.token
    vim.api.nvim_set_current_buf(saved.buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    if not ok then
      error(err)
    end
  end,
}
