if vim.g.loaded_rill then
  return
end
vim.g.loaded_rill = true

vim.api.nvim_create_user_command("Rill", function(opts)
  local ok, err = pcall(require("rill").command, opts.fargs)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR, { title = "Rill" })
  end
end, {
  nargs = "*",
  desc = "Open a Git review",
  complete = function(arglead)
    return vim.tbl_filter(function(value)
      return value:sub(1, #arglead) == arglead
    end, { "working", "staged", "unstaged", "branch", "commit", "range", "--split", "--unified" })
  end,
})
for name, action in pairs({
  RillClose = "close",
  RillToggle = "toggle",
  RillFocus = "focus",
  RillRefresh = "refresh",
}) do
  vim.api.nvim_create_user_command(name, function()
    require("rill")[action]()
  end, { desc = "Rill: " .. action })
end
