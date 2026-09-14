-- The winbar is the review's persistent shortcut legend. Split panes share the
-- legend between them; narrow panes shed comparison text before hiding actions.
local M = {}

local function escape(text)
  return text:gsub("%%", "%%%%")
end
local function width(actions)
  local count = 0
  for _, action in ipairs(actions) do
    count = count + #action[1] + #action[2] + 3
  end
  return count - 2
end

function M.render(opts)
  local layout = opts.layout == "split" and "unified" or "split"
  local focus = opts.focused and "stream" or "focus"
  local actions
  if opts.layout == "split" and opts.side == "new" then
    actions = { { "zo", "context" }, { "zR", "full file" }, { "Enter", "source" }, { "g?", "help" } }
  else
    actions = { { "Tab/S-Tab", "files" }, { "gs", layout }, { "gf", focus } }
    if opts.layout ~= "split" then
      vim.list_extend(actions, { { "zo", "context" }, { "zR", "full file" }, { "Enter", "source" } })
    end
    actions[#actions + 1] = { "g?", "help" }
  end
  -- Keep the full help entry reachable even when the window is too narrow for
  -- all labels. The common review width displays every requested shortcut.
  while #actions > 1 and width(actions) + 2 > opts.width do
    table.remove(actions, #actions - 1)
  end
  local title = opts.title
  if vim.fn.strdisplaywidth(title) + width(actions) + 4 > opts.width then
    title = opts.layout == "split" and (opts.side == "old" and "Before" or "After") or "Rill"
  end
  if #title + width(actions) + 4 > opts.width then
    title = ""
  end
  local parts = { "%#RillBarHint# " .. escape(title) .. "%=" }
  for index, action in ipairs(actions) do
    if index > 1 then
      parts[#parts + 1] = "  "
    end
    parts[#parts + 1] = "%#RillBarKey#" .. action[1] .. "%#RillBarHint# " .. action[2]
  end
  parts[#parts + 1] = " "
  return table.concat(parts)
end

return M
