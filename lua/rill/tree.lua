-- The Files panel owns its windows, row projection, folds and sizing. Sessions
-- supply file/group identities and receive selections; display truncation never
-- changes the identities used by source navigation or Sidekick context.
local api = vim.api
local M, Tree = {}, {}
Tree.__index = Tree
local ns = api.nvim_create_namespace("rill.tree")
-- A manual choice lasts across reviews, while automatic content fitting remains
-- per-panel. Screen-size clamps never overwrite the user's remembered width.
local preferred_width
local defaults = { adaptive = true, max_width = 60, max_ratio = 0.4, resize_step = 5, icons = true }
local statuses = {
  A = { "+", "RillTreeAdded" },
  M = { "●", "RillTreeModified" },
  D = { "−", "RillTreeDeleted" },
  R = { "➜", "RillTreeRenamed" },
  C = { "+", "RillTreeAdded" },
  ["?"] = { "?", "RillTreeAdded" },
}

local function valid(win)
  return win and api.nvim_win_is_valid(win)
end
local function escape(text)
  return (text:gsub("[\n\r\t]", { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }))
end
local function fit(text, width, tail)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 0 then
    return ""
  end
  local chars = vim.fn.strchars(text)
  for count = chars - 1, 0, -1 do
    local part = vim.fn.strcharpart(text, tail and chars - count or 0, count)
    local result = tail and "…" .. part or part .. "…"
    if vim.fn.strdisplaywidth(result) <= width then
      return result
    end
  end
  return ""
end

local function icon(path, enabled)
  if enabled then
    local mini = rawget(_G, "MiniIcons")
    if mini and type(mini.get) == "function" then
      local ok, glyph, hl = pcall(mini.get, "file", path)
      if ok and glyph then
        return glyph, hl
      end
    end
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
      local glyph, hl = devicons.get_icon(vim.fn.fnamemodify(path, ":t"), nil, { default = true })
      if glyph then
        return glyph, hl
      end
    end
  end
  return "·", "RillMuted"
end

-- Fold keys include the commit group, so repeated paths in a multi-commit
-- review remain independent. Compact directory chains leave room for filenames.
local function entries(files, groups, folded)
  local roots = {}
  for i = 1, groups and #groups or 1 do
    roots[i] = { children = {}, order = {} }
  end
  for _, file in ipairs(files) do
    local group = groups and file.meta.group or 1
    local node, path = roots[group], groups and "@" .. group or ""
    if node then
      node.first = node.first or file
      local parts = vim.split(file.meta.path, "/", { plain = true })
      for i, name in ipairs(parts) do
        path = path == "" and name or path .. "/" .. name
        if not node.children[name] then
          node.children[name] = { name = name, path = path, children = {}, order = {} }
          node.order[#node.order + 1] = name
        end
        node = node.children[name]
        if i == #parts then
          node.file = file
        end
      end
    end
  end
  local result = {}
  local function visit(node, indent, parent)
    for index, name in ipairs(node.order) do
      local child, label = node.children[name], name
      while not child.file and not folded[child.path] and #child.order == 1 do
        local descendant = child.children[child.order[1]]
        if descendant.file then
          break
        end
        child, label = descendant, label .. "/" .. descendant.name
      end
      local last = index == #node.order
      local prefix = indent .. (last and "└─ " or "├─ ")
      local entry = { label = escape(label), prefix = prefix, parent = parent }
      if child.file then
        entry.file = child.file
      else
        entry.directory, entry.key = child.path, child.path
      end
      result[#result + 1] = entry
      if not child.file and not folded[child.path] then
        visit(child, indent .. (last and "   " or "│  "), child.path)
      end
    end
  end
  if groups then
    for index, group in ipairs(groups) do
      local key, root = "@" .. index, roots[index]
      result[#result + 1] = {
        group = index,
        key = key,
        file = root.first,
        prefix = "",
        label = escape(("%d/%d %s %s"):format(index, #groups, group.short, group.subject)),
      }
      if not folded[key] then
        if #root.order == 0 then
          result[#result + 1] = { placeholder = true, prefix = "  ", label = "(no changes)", parent = key }
        end
        visit(root, "  ", key)
      end
    end
  else
    visit(roots[1], "", nil)
  end
  return result
end

-- A user can replace the panel with :edit. Late resize/enter callbacks must
-- relinquish that window instead of styling or closing the new editing buffer.
function Tree:is_open()
  return valid(self.win) and api.nvim_win_get_buf(self.win) == self.buf
end

function Tree:limits()
  local maximum = math.max(
    1,
    math.min(math.floor(self.options.max_width), math.floor(vim.o.columns * self.options.max_ratio))
  )
  return math.min(20, maximum), maximum
end

function Tree:capture_width()
  if not self:is_open() then
    return
  end
  local actual = api.nvim_win_get_width(self.win)
  if self.columns == vim.o.columns and self.width and actual ~= self.width then
    preferred_width = actual
  end
  self.columns, self.width = vim.o.columns, actual
end

function Tree:options_local()
  if not self:is_open() then
    return
  end
  for key, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    statuscolumn = "",
    foldcolumn = "0",
    foldenable = false,
    wrap = false,
    spell = false,
    list = false,
    cursorline = true,
    cursorlineopt = "line",
    winfixwidth = true,
    scrollbind = false,
    cursorbind = false,
    winbar = "%#RillHeader# Files",
    fillchars = "eob: ",
  }) do
    api.nvim_set_option_value(key, value, { win = self.win, scope = "local" })
  end
end

function Tree:buffer()
  if self.buf and api.nvim_buf_is_valid(self.buf) then
    return self.buf
  end
  local buf = api.nvim_create_buf(false, true)
  self.buf = buf
  api.nvim_buf_set_name(buf, "rill://" .. self.id .. "/files")
  vim.bo[buf].bufhidden, vim.bo[buf].filetype = "hide", "rill_tree"
  vim.bo[buf].swapfile, vim.bo[buf].modifiable = false, false
  vim.b[buf].rill = true
  -- Register session context and inherited Rill keys before overriding only the
  -- panel-specific actions. Sidekick still sees the selected file's full path.
  if self.attach then
    self.attach(buf)
  end
  local actions = {
    ["<CR>"] = {
      "Open file / expand directory",
      function()
        self:activate()
      end,
    },
    o = {
      "Open file / expand directory",
      function()
        self:activate()
      end,
    },
    l = {
      "Open file / expand directory",
      function()
        self:activate()
      end,
    },
    h = {
      "Collapse / parent",
      function()
        self:parent()
      end,
    },
    za = {
      "Toggle directory / commit",
      function()
        self:toggle()
      end,
    },
    q = {
      "Close Files panel",
      function()
        self:close()
      end,
    },
    [">"] = {
      "Widen Files panel",
      function()
        self:resize(self.options.resize_step)
      end,
    },
    ["<"] = {
      "Narrow Files panel",
      function()
        self:resize(-self.options.resize_step)
      end,
    },
    ["g?"] = {
      "Files help",
      function()
        self:help()
      end,
    },
  }
  for key, action in pairs(actions) do
    vim.keymap.set(
      "n",
      key,
      action[2],
      { buffer = buf, silent = true, nowait = true, desc = "Rill: " .. action[1] }
    )
  end
  api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter" }, {
    group = self.augroup,
    buffer = buf,
    callback = function()
      -- Run after owner/plugin enter hooks that may re-enable number columns.
      -- This changes only the panel's local values, never editor defaults.
      vim.schedule(function()
        if not self.disposed then
          self:options_local()
        end
      end)
    end,
  })
  return buf
end

function Tree:open(anchor)
  if self.disposed or self:is_open() or not valid(anchor) then
    return
  end
  self.anchor = anchor
  local low, high = self:limits()
  local width = math.max(low, math.min(high, preferred_width or self.initial_width))
  api.nvim_win_call(anchor, function()
    vim.cmd("topleft vertical " .. width .. "split")
    self.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.win, self:buffer())
  end)
  self.width, self.columns = api.nvim_win_get_width(self.win), vim.o.columns
  self:options_local()
  self:render()
end

function Tree:close()
  self:capture_width()
  if self:is_open() then
    api.nvim_win_close(self.win, true)
  end
  self.win = nil
end

function Tree:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self:close()
  if valid(self.help_win) then
    api.nvim_win_close(self.help_win, true)
  end
  api.nvim_del_augroup_by_id(self.augroup)
  if self.buf then
    if self.detach then
      self.detach(self.buf)
    end
    if api.nvim_buf_is_valid(self.buf) then
      api.nvim_buf_delete(self.buf, { force = true })
    end
  end
end

function Tree:resize(delta)
  if not self:is_open() then
    return
  end
  local low, high = self:limits()
  preferred_width = math.max(low, math.min(high, api.nvim_win_get_width(self.win) + math.floor(delta)))
  self:render()
end

function Tree:update(data)
  self.data = data
  self.current_file = data.current_file
  self:render()
end

function Tree:render()
  if not self:is_open() or self.rendering then
    return
  end
  self.rendering = true
  self:capture_width()
  local prior = self.entries[api.nvim_win_get_cursor(self.win)[1]]
  self.entries = entries(self.data.files or {}, self.data.groups, self.folded)
  local natural = self.initial_width
  for _, entry in ipairs(self.entries) do
    if entry.group or entry.directory then
      entry.symbol, entry.hl = self.folded[entry.key] and "▸" or "▾", "Directory"
      entry.suffix = entry.directory and "/" or ""
    elseif entry.file then
      entry.symbol, entry.hl = icon(entry.file.meta.path, self.options.icons)
      entry.status = statuses[(entry.file.meta.status or "M"):sub(1, 1)] or statuses.M
    end
    local prefix = entry.prefix .. (entry.symbol and entry.symbol .. " " or "")
    if entry.status then
      prefix = prefix .. entry.status[1] .. " "
    end
    entry.display_prefix = prefix
    natural = math.max(natural, vim.fn.strdisplaywidth(prefix .. entry.label .. (entry.suffix or "")) + 1)
  end
  local low, high = self:limits()
  local width = math.max(
    low,
    math.min(high, preferred_width or (self.options.adaptive and natural or self.initial_width))
  )
  if api.nvim_win_get_width(self.win) ~= width then
    api.nvim_win_set_width(self.win, width)
  end
  self.width, self.columns = api.nvim_win_get_width(self.win), vim.o.columns
  local lines, cursor = {}, nil
  for index, entry in ipairs(self.entries) do
    local label = entry.label .. (entry.suffix or "")
    local prefix = entry.display_prefix
    entry.paint_indent = entry.prefix
    if entry.file and not entry.group then
      -- Spend narrow-panel space on the filename before indentation. The
      -- original parent/key remains on the entry even when its stem is elided.
      local decoration = prefix:sub(#entry.prefix + 1)
      local budget = self.width - 1 - vim.fn.strdisplaywidth(label .. decoration)
      if budget < vim.fn.strdisplaywidth(entry.prefix) then
        entry.paint_indent = fit(entry.prefix, math.max(0, budget), true)
        prefix = entry.paint_indent .. decoration
      end
    end
    prefix = fit(prefix, math.max(0, self.width - 1), false)
    local room = self.width - vim.fn.strdisplaywidth(prefix) - 1
    if entry.directory and vim.fn.strdisplaywidth(label) > room then
      label = vim.fn.pathshorten(label)
    end
    lines[index] = prefix .. fit(label, room, not entry.group)
    if
      prior
      and (
        (entry.key and prior.key == entry.key)
        or (not entry.group and entry.file and prior.file and prior.file.meta.id == entry.file.meta.id)
      )
    then
      cursor = index
    end
  end
  if #lines == 0 then
    lines = { fit(self.data.message or "Loading…", self.width - 1, false) }
  end
  vim.bo[self.buf].modifiable = true
  api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  if cursor then
    api.nvim_win_set_cursor(self.win, { cursor, 0 })
  end
  self:highlight()
  self.rendering = false
end

function Tree:highlight(current)
  if current ~= nil then
    self.current_file = current
  end
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then
    return
  end
  api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  for index, entry in ipairs(self.entries) do
    local line = api.nvim_buf_get_lines(self.buf, index - 1, index, false)[1] or ""
    local function span(start, length, hl)
      if start < #line then
        api.nvim_buf_set_extmark(
          self.buf,
          ns,
          index - 1,
          start,
          { end_col = math.min(#line, start + length), hl_group = hl }
        )
      end
    end
    span(0, #entry.paint_indent, "RillMuted")
    if entry.symbol then
      span(#entry.paint_indent, #entry.symbol, entry.hl)
    end
    if entry.status then
      span(#entry.paint_indent + #entry.symbol + 1, #entry.status[1], entry.status[2])
    end
    local hl = entry.group and "RillGroup"
      or entry.file and entry.file.meta.id == self.current_file and "RillTreeCurrent"
    if hl then
      api.nvim_buf_set_extmark(self.buf, ns, index - 1, 0, { line_hl_group = hl })
    end
  end
end

function Tree:selected()
  return self:is_open() and self.entries[api.nvim_win_get_cursor(self.win)[1]] or nil
end
function Tree:activate()
  local entry = self:selected()
  if entry and entry.directory then
    self:toggle(entry)
  elseif entry and entry.file and self.on_select then
    self.on_select(entry)
  end
end
function Tree:toggle(entry)
  entry = entry or self:selected()
  if entry and entry.key then
    self.folded[entry.key] = not self.folded[entry.key]
    self:render()
  end
end
function Tree:parent()
  local entry = self:selected()
  if not entry then
    return
  end
  if entry.key and not self.folded[entry.key] then
    self:toggle(entry)
    return
  end
  for index, candidate in ipairs(self.entries) do
    if candidate.key and candidate.key == entry.parent then
      api.nvim_win_set_cursor(self.win, { index, 0 })
      return
    end
  end
end

function Tree:help()
  if valid(self.help_win) then
    api.nvim_win_close(self.help_win, true)
  end
  local buf = api.nvim_create_buf(false, true)
  local lines = {
    "Files",
    "",
    "Enter / o / l  Open file / expand directory",
    "h              Collapse / parent",
    "za             Toggle directory / commit",
    "> / <          Widen / narrow (session-persistent)",
    "Ctrl-w < / >   Native resize; separator drag also works",
    "q              Close Files panel",
    "gT             Reopen Files panel",
    "",
    "Rill: gs layout, gf focus, Tab files, gr refresh, Sidekick keys",
    "",
    "q / Escape     Close help",
  }
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "wipe", false
  local width, height = math.min(65, vim.o.columns - 4), math.min(#lines, vim.o.lines - 4)
  self.help_win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Files ",
  })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if valid(self.help_win) then
        api.nvim_win_close(self.help_win, true)
      end
    end, { buffer = buf })
  end
end

function M.new(opts)
  assert(opts.options == nil or type(opts.options) == "table", "Rill tree must be a table")
  local options = vim.tbl_extend("force", defaults, opts.options or {})
  assert(
    type(opts.initial_width or 30) == "number" and (opts.initial_width or 30) >= 1,
    "Rill tree_width must be positive"
  )
  assert(
    type(options.max_width) == "number" and options.max_width >= 1,
    "Rill tree.max_width must be positive"
  )
  assert(
    type(options.max_ratio) == "number" and options.max_ratio > 0 and options.max_ratio < 1,
    "Rill tree.max_ratio must be between 0 and 1"
  )
  assert(
    type(options.resize_step) == "number" and options.resize_step >= 1,
    "Rill tree.resize_step must be positive"
  )
  local self = setmetatable({
    id = opts.id,
    options = options,
    initial_width = math.floor(opts.initial_width or 30),
    on_select = opts.on_select,
    attach = opts.attach,
    detach = opts.detach,
    data = {},
    entries = {},
    folded = {},
    augroup = api.nvim_create_augroup("RillTree" .. opts.id, { clear = true }),
  }, Tree)
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = self.augroup,
    callback = function()
      if not self.disposed then
        self:render()
      end
    end,
  })
  api.nvim_create_autocmd({ "FocusGained", "InsertLeave" }, {
    group = self.augroup,
    callback = function()
      vim.schedule(function()
        if not self.disposed then
          self:options_local()
        end
      end)
    end,
  })
  return self
end

return M
