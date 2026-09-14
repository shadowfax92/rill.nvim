local M = {}
function M.check()
  vim.health.start("Rill")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim 0.11+")
  else
    vim.health.error("Neovim 0.11+ is required")
  end
  if vim.fn.executable("git") == 1 then
    vim.health.ok("Git available")
  else
    vim.health.error("Git is required")
  end
  vim.health.info("Tree-sitter parsers improve syntax; missing parsers use plain text.")
  vim.health.info("Sidekick is optional and loaded only by send/comment actions.")
end
return M
