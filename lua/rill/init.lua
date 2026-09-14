-- Public entrypoints keep comparisons independent of pickers and presentation.
-- A session owns all asynchronous work; integrations resolve captured positions
-- through context() instead of interpreting a review buffer's synthetic rows.
local M = {}
local defaults = {
  layout = "unified",
  tree_width = 30,
  context_step = 20,
  wrap = false,
  syntax = true,
  syntax_max_lines = 100000,
  syntax_max_bytes = 1024 * 1024,
  sidekick = true,
  max_file_bytes = 1024 * 1024,
  max_changed_lines = 20000,
  max_patch_bytes = 16 * 1024 * 1024,
  source_cache_bytes = 32 * 1024 * 1024,
}
local config = vim.deepcopy(defaults)

function M.setup(opts)
  config = vim.tbl_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.open(opts)
  opts = vim.tbl_extend("force", config, opts or {})
  opts.cwd = opts.cwd or vim.fn.getcwd()
  opts.mode = opts.mode or "working"
  if opts.layout ~= "unified" and opts.layout ~= "split" then
    error("Rill layout must be unified or split")
  end
  return require("rill.view").open(opts)
end

function M.open_working(opts)
  return M.open(vim.tbl_extend("force", opts or {}, { mode = "working" }))
end
function M.open_staged(opts)
  return M.open(vim.tbl_extend("force", opts or {}, { mode = "staged" }))
end
function M.open_unstaged(opts)
  return M.open(vim.tbl_extend("force", opts or {}, { mode = "unstaged" }))
end
function M.open_branch(opts)
  return M.open(vim.tbl_extend("force", opts or {}, { mode = "branch" }))
end
function M.open_commit(rev, opts)
  return M.open(vim.tbl_extend("force", opts or {}, { mode = "commit", rev = rev or "HEAD" }))
end
function M.open_range(base, head, opts)
  return M.open(vim.tbl_extend("force", opts or {}, { mode = "range", base = base, head = head or "HEAD" }))
end

function M.current()
  return require("rill.view").current()
end
function M.context(ctx)
  return require("rill.view").context(ctx)
end
function M.close()
  local session = M.current()
  if session then
    session:close()
  end
end
function M.toggle()
  local session = M.current()
  if session then
    session:toggle_layout()
  end
end
function M.focus()
  local session = M.current()
  if session then
    session:toggle_focus()
  end
end
function M.refresh()
  local session = M.current()
  if session then
    session:load()
  end
end

function M.command(args)
  local options, positional, paths = {}, {}, nil
  for _, value in ipairs(args) do
    if paths then
      paths[#paths + 1] = value
    elseif value == "--" then
      paths = {}
    elseif value == "--split" then
      options.layout = "split"
    elseif value == "--unified" then
      options.layout = "unified"
    else
      positional[#positional + 1] = value
    end
  end
  options.paths = paths
  local mode = positional[1] or "working"
  if mode == "working" or mode == "staged" or mode == "unstaged" then
    options.mode = mode
    return M.open(options)
  elseif mode == "branch" then
    options.base = positional[2]
    return M.open_branch(options)
  elseif mode == "commit" then
    return M.open_commit(positional[2], options)
  elseif mode == "range" then
    if not positional[2] or not positional[3] then
      error("Usage: Rill range <base> <head> [-- paths]")
    end
    return M.open_range(positional[2], positional[3], options)
  end
  local base, head = mode:match("^(.-)%.%.%.(.-)$")
  if base then
    options.merge_base = true
    return M.open_range(base ~= "" and base or "HEAD", head ~= "" and head or "HEAD", options)
  end
  base, head = mode:match("^(.-)%.%.(.-)$")
  if base then
    return M.open_range(base ~= "" and base or "HEAD", head ~= "" and head or "HEAD", options)
  end
  return M.open_commit(mode, options)
end

return M
