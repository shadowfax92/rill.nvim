local H = require("tests.helpers")
local Bar = require("rill.bar")

local function rendered(width, layout, side, commits)
  local value = Bar.render({
    width = width,
    layout = layout or "unified",
    side = side,
    title = "Before · feature%branch → HEAD · unified · stream",
    focused = false,
    commits = commits,
  })
  return vim.api.nvim_eval_statusline(value, { use_winbar = true, maxwidth = width }).str
end

return {
  ["commit jumps appear only in multi-commit reviews and outlive context shortcuts"] = function()
    H.eq(nil, rendered(150):find("]C/[C", 1, true))
    H.eq(nil, rendered(150, "split", "old"):find("]C/[C", 1, true))
    local commits = rendered(150, "unified", nil, true)
    H.ok(commits:find("Tab/S-Tab files  ]C/[C commits  gs split", 1, true), commits)
    H.ok(rendered(150, "split", "old", true):find("]C/[C commits", 1, true))
    H.eq(
      nil,
      rendered(150, "split", "new", true):find("]C/[C", 1, true),
      "the After pane keeps context actions"
    )
    local narrow = rendered(60, "unified", nil, true)
    H.ok(narrow:find("]C/[C commits", 1, true), narrow)
    H.eq(nil, narrow:find("zR full file", 1, true), "context shortcuts are shed first")
    H.ok(narrow:find("g? help", 1, true))
  end,

  ["a title that fits in display columns is kept despite multibyte separators"] = function()
    local title = "[2/5] b5fe24cc T1 add TEMP line to shared.txt · unified · focused"
    local actions =
      Bar.render({ width = 999, layout = "unified", title = "", focused = true, commits = true })
    local columns = vim.api.nvim_eval_statusline(actions, { use_winbar = true, maxwidth = 999 }).str
    -- Exactly wide enough for the title by display width, two columns short by bytes.
    local width = vim.fn.strdisplaywidth(vim.trim(columns)) + vim.fn.strdisplaywidth(title) + 4
    H.ok(#title > vim.fn.strdisplaywidth(title), "fixture must contain multibyte characters")
    local value =
      Bar.render({ width = width, layout = "unified", title = title, focused = true, commits = true })
    local shown = vim.api.nvim_eval_statusline(value, { use_winbar = true, maxwidth = width }).str
    H.ok(shown:find(title, 1, true), shown)
  end,

  ["top bar keeps actions visible across layouts and narrow widths"] = function()
    local unified = rendered(150)
    for _, label in ipairs({
      "Tab/S-Tab files",
      "gs split",
      "gf focus",
      "zo context",
      "zR full file",
      "Enter source",
      "g? help",
    }) do
      H.ok(unified:find(label, 1, true), "missing shortcut: " .. label)
    end
    H.ok(unified:find("feature%branch", 1, true), "revision percent must stay literal")
    local split = rendered(65, "split", "old") .. rendered(65, "split", "new")
    for _, label in ipairs({
      "Tab/S-Tab files",
      "gs unified",
      "gf focus",
      "zo context",
      "zR full file",
      "Enter source",
    }) do
      H.ok(split:find(label, 1, true), "missing split shortcut: " .. label)
    end
    H.ok(rendered(35):find("g? help", 1, true), "narrow windows must retain the full-help shortcut")
  end,
}
