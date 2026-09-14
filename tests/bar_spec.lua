local H = require("tests.helpers")
local Bar = require("rill.bar")

local function rendered(width, layout, side)
  local value = Bar.render({
    width = width,
    layout = layout or "unified",
    side = side,
    title = "Before · feature%branch → HEAD · unified · stream",
    focused = false,
  })
  return vim.api.nvim_eval_statusline(value, { use_winbar = true, maxwidth = width }).str
end

return {
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
