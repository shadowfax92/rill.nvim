-- A review session owns its tab, scratch buffers, Git jobs and projected rows.
-- Source identities live on model cells; every navigation/integration operation
-- crosses the same row map, even when focus, context or layout changes its size.
local api = vim.api
local M = { sessions = {}, buffers = {} }
local Session = {}
Session.__index = Session
local ns = api.nvim_create_namespace("rill.view")
local tree_ns = api.nvim_create_namespace("rill.tree")
local initialized = false
local serial = 0

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end
local function valid_buf(buf)
  return buf and api.nvim_buf_is_valid(buf)
end
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Rill" })
end
local function cell_for(row, side)
  if row.kind ~= "code" then
    return
  end
  if side == "old" then
    return row.old
  end
  if side == "new" then
    return row.new
  end
  return row.new or row.old
end

local function display_label(text)
  return (text:gsub("[\n\r\t]", { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }))
end

-- Commits mode (open_commits) loads a composite snapshot whose groups are the
-- reviewed commits, oldest first; every file meta names its group. The row
-- label heads a commit's files in the document; the tree node and the window
-- title use shorter forms because their width is scarce.
local function group_label(index, total, group, form)
  local short, subject = group.short or "", group.subject or ""
  if form == "title" then
    return ("[%d/%d] %s %s"):format(index, total, short, subject)
  elseif form == "tree" then
    return ("%d/%d %s %s"):format(index, total, short, subject)
  end
  local text = ("● %d/%d  %s  %s — %s · %s"):format(
    index,
    total,
    short,
    subject,
    group.author or "",
    group.date or ""
  )
  if group.merge then
    text = text .. " · merge vs 1st parent"
  end
  if group.root_commit then
    text = text .. " · root"
  end
  return text
end

-- The commit a document row belongs to: commit rows and "(no changes)" rows
-- carry it directly, file rows through their meta.
local function row_group(row)
  return row and (row.group or (row.file and row.file.meta.group))
end

local function changed(row, side)
  if row.kind ~= "code" then
    return
  end
  if side == "old" then
    return row.old and (not row.new or row.old.text ~= row.new.text) and "delete" or nil
  elseif side == "new" then
    return row.new and (not row.old or row.old.text ~= row.new.text) and "add" or nil
  end
  return not row.new and "delete" or not row.old and "add" or nil
end

local function source_side(row, side)
  if side == "old" or side == "new" then
    return side
  end
  return row.new and "new" or "old"
end

local function mark(buf, row, opts)
  -- line_hl_group is ignored on ephemeral marks in Neovim 0.11. A highlighted
  -- range crossing the newline paints the code and extends to the window edge,
  -- while keeping all diff decoration scoped to the current viewport/redraw.
  opts.hl_group = opts.line_hl_group
  opts.line_hl_group = nil
  opts.end_row, opts.end_col, opts.hl_eol = row + 1, 0, true
  opts.ephemeral = true
  api.nvim_buf_set_extmark(buf, ns, row, 0, opts)
end

function M.gutter(win)
  win = tonumber(win) or api.nvim_get_current_win()
  if not valid_win(win) then
    return ""
  end
  local binding = M.buffers[api.nvim_win_get_buf(win)]
  if not binding or binding.tree then
    return ""
  end
  local row = binding.session.rows[vim.v.lnum]
  local width = binding.session.digits or 4
  local blank = string.rep(" ", binding.side == "unified" and (width * 2 + 5) or (width + 3))
  -- Negative virtnum rows are virtual lines drawn above a row, not part of it.
  if not row or row.kind ~= "code" or vim.v.virtnum < 0 then
    return blank
  end
  local kind = changed(row, binding.side)
  local group = kind == "add" and "RillAddSign" or kind == "delete" and "RillDeleteSign" or "RillNumber"
  if vim.v.virtnum > 0 then
    -- The band covers the gutter, so wrapped rows of a changed line continue it
    -- there; numbers and signs appear only on the first screen row.
    return kind and ("%%#%s#%s%%*"):format(group, blank) or blank
  end
  local sign = kind == "add" and "+" or kind == "delete" and "−" or " "
  local function num(cell)
    return cell and tostring(cell.line) or ""
  end
  if binding.side == "unified" then
    return ("%%#%s#%" .. width .. "s %" .. width .. "s %s  %%*"):format(
      group,
      num(row.old),
      num(row.new),
      sign
    )
  end
  return ("%%#%s#%" .. width .. "s %s %%*"):format(group, num(cell_for(row, binding.side)), sign)
end

local function initialize()
  if initialized then
    return
  end
  initialized = true
  require("rill.highlight").colors()
  _G.RillStatuscolumn = function()
    return M.gutter(vim.g.statusline_winid)
  end
  local group = api.nvim_create_augroup("Rill", { clear = true })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      require("rill.highlight").colors()
    end,
  })
  api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for _, session in pairs(M.sessions) do
        if not session.closed then
          session:titles()
        end
      end
    end,
  })
  api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      vim.schedule(function()
        for tab, session in pairs(M.sessions) do
          if not api.nvim_tabpage_is_valid(tab) then
            session:close()
          end
        end
      end)
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function()
      vim.schedule(function()
        for _, session in pairs(M.sessions) do
          if not valid_win(session.main_win) then
            session:close()
          elseif session.layout == "split" and session.right_win and not valid_win(session.right_win) then
            local anchor = session:anchor()
            session.layout, session.right_win = "unified", nil
            session:render(anchor)
          end
        end
      end)
    end,
  })
  -- Redraw callbacks paint cached values only. Source I/O, parsing and document
  -- replacement are scheduled through ordinary session callbacks outside redraw.
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf)
      local binding = M.buffers[buf]
      return binding ~= nil and not binding.tree and not binding.session.closed
    end,
    on_line = function(_, _, buf, line)
      local binding = M.buffers[buf]
      if not binding then
        return
      end
      local row = binding.session.rows[line + 1]
      if not row then
        return
      end
      if row.kind == "file" then
        mark(buf, line, { line_hl_group = "RillHeader", priority = 50 })
      elseif row.kind == "group" then
        mark(buf, line, { line_hl_group = "RillGroup", priority = 50 })
      elseif row.kind == "gap" then
        mark(buf, line, { line_hl_group = "RillGap", priority = 50 })
      elseif row.kind == "hunk" or row.kind == "meta" then
        mark(buf, line, { line_hl_group = "RillMuted", priority = 50 })
      elseif row.kind == "code" then
        local cell = cell_for(row, binding.side)
        if not cell then
          mark(buf, line, { line_hl_group = "RillPadding", priority = 40 })
          return
        end
        local kind = changed(row, binding.side)
        if kind then
          mark(buf, line, { line_hl_group = kind == "add" and "RillAdd" or "RillDelete", priority = 40 })
        end
        local side = source_side(row, binding.side)
        local syntax = row.file.syntax and row.file.syntax[side][cell.line] or {}
        for _, span in ipairs(syntax) do
          if span[1] < #cell.text and span[2] > span[1] then
            api.nvim_buf_set_extmark(buf, ns, line, span[1], {
              end_col = math.min(span[2], #cell.text),
              hl_group = span[3],
              priority = span[4],
              ephemeral = true,
            })
          end
        end
      end
    end,
  })
end

-- The commits of an open_commits review, oldest first; nil for one comparison.
function Session:groups()
  local groups = self.snapshot and self.snapshot.groups
  return groups and #groups > 0 and groups or nil
end

function Session:buffer(key, side, tree)
  if valid_buf(self.bufs[key]) then
    M.buffers[self.bufs[key]].side = side
    return self.bufs[key]
  end
  local buf = api.nvim_create_buf(false, true)
  self.bufs[key] = buf
  M.buffers[buf] = { session = self, side = side, tree = tree }
  api.nvim_buf_set_name(buf, ("rill://%s/%s"):format(self.id, key))
  for option, value in pairs({
    buftype = "nofile",
    bufhidden = "hide",
    swapfile = false,
    undolevels = -1,
    filetype = tree and "rill_tree" or "rill",
  }) do
    vim.bo[buf][option] = value
  end
  vim.b[buf].rill = true
  vim.bo[buf].modifiable = false
  self:keys(buf, tree)
  api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if not self.closed and not self.rendering then
        self:cursor_changed(buf)
      end
    end,
  })
  return buf
end

function Session:options(win, tree)
  if not valid_win(win) then
    return
  end
  local options = {
    number = not tree,
    relativenumber = false,
    numberwidth = self.layout == "unified" and 13 or 7,
    signcolumn = "no",
    foldcolumn = "0",
    foldenable = false,
    spell = false,
    list = false,
    cursorline = true,
    cursorlineopt = "number",
    wrap = not tree and self.layout == "unified" and self.opts.wrap or false,
    linebreak = false,
    breakindent = false,
    conceallevel = 0,
    colorcolumn = "",
    scrolloff = 3,
    winfixwidth = tree,
    scrollbind = not tree and self.layout == "split",
    cursorbind = false,
    statuscolumn = tree and "" or "%!v:lua.RillStatuscolumn()",
    winhighlight = "Normal:Normal,NormalNC:Normal,EndOfBuffer:NonText,WinSeparator:WinSeparator",
    fillchars = "eob: ",
  }
  for key, value in pairs(options) do
    pcall(function()
      -- :set would also overwrite the defaults inherited by later buffers and
      -- splits. Review decoration belongs only to this buffer in this window.
      api.nvim_set_option_value(key, value, { win = win, scope = "local" })
    end)
  end
end

function Session:windows()
  if not valid_win(self.main_win) then
    return
  end
  local main =
    self:buffer(self.layout == "split" and "old" or "unified", self.layout == "split" and "old" or "unified")
  api.nvim_win_set_buf(self.main_win, main)
  self:options(self.main_win)
  if self.layout == "split" then
    if not valid_win(self.right_win) then
      api.nvim_win_call(self.main_win, function()
        vim.cmd("rightbelow vsplit")
        self.right_win = api.nvim_get_current_win()
      end)
    end
    api.nvim_win_set_buf(self.right_win, self:buffer("new", "new"))
    self:options(self.right_win)
  elseif valid_win(self.right_win) then
    api.nvim_win_close(self.right_win, true)
    self.right_win = nil
  end
  self:titles()
end

function Session:titles()
  local function escaped(text)
    return display_label(text):gsub("%%", "%%%%")
  end
  local groups = self:groups()
  local title, count = nil, #self.files .. " files "
  if groups then
    -- One composite comparison spans several commits; name the commit under
    -- the cursor instead of the first parent → last commit endpoints.
    local index = groups[self.current_group] and self.current_group or 1
    title = group_label(index, #groups, groups[index], "title")
    count = #self.files .. " files · " .. #groups .. " commits "
  else
    title = self.snapshot and self.snapshot.label or "Loading Git changes…"
    title = title:gsub("%x%x%x%x%x%x%x%x%x%x%x%x%x+", function(oid)
      return oid:sub(1, 8)
    end)
  end
  local mode = self.layout .. (self.focus_id and " · focused" or " · stream")
  -- current_file is a file id; commits mode namespaces ids as oid:path.
  local current = self.by_id[self.current_file]
  local path = current and current.meta.path or ""
  for index, win in ipairs({ self.main_win, self.right_win }) do
    if valid_win(win) then
      local side = self.layout == "split" and (index == 1 and "Before · " or "After · ") or ""
      local bar = require("rill.bar").render({
        title = side .. display_label(title) .. " · " .. mode,
        width = api.nvim_win_get_width(win),
        layout = self.layout,
        side = index == 1 and "old" or "new",
        focused = self.focus_id ~= nil,
        commits = groups ~= nil,
      })
      api.nvim_set_option_value("winbar", bar, { win = win, scope = "local" })
      api.nvim_set_option_value(
        "statusline",
        "%#RillMuted# Rill · %<" .. escaped(path) .. "%=" .. count,
        { win = win, scope = "local" }
      )
    end
  end
  if valid_win(self.tree_win) then
    api.nvim_set_option_value("winbar", "%#RillHeader# Files", { win = self.tree_win, scope = "local" })
  end
end

local function set_lines(buf, lines)
  if not valid_buf(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

-- Updating capture caches alone does not dirty Neovim's screen lines. Force a
-- repaint of our windows when a decoration job finishes, coalescing completions
-- so syntax appears in place without waiting for scrolling or cursor movement.
function Session:repaint()
  if self.repaint_scheduled or self.closed then
    return
  end
  self.repaint_scheduled = true
  vim.schedule(function()
    self.repaint_scheduled = false
    if self.closed or #api.nvim_list_uis() == 0 then
      return
    end
    for _, win in ipairs({ self.main_win, self.right_win }) do
      if valid_win(win) then
        api.nvim__redraw({ win = win, valid = false })
      end
    end
    api.nvim__redraw({ flush = true })
  end)
end

function Session:anchor()
  local win = api.nvim_get_current_win()
  local binding = M.buffers[api.nvim_win_get_buf(win)]
  if not binding or binding.session ~= self or binding.tree then
    win = valid_win(self.last_code_win) and self.last_code_win or self.main_win
    binding = valid_win(win) and M.buffers[api.nvim_win_get_buf(win)] or nil
  end
  if not binding or not valid_win(win) then
    return
  end
  local cursor = api.nvim_win_get_cursor(win)
  local row = self.rows[cursor[1]]
  if not row then
    return
  end
  local side = source_side(row, binding.side)
  local cell = cell_for(row, binding.side)
  local top = api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)
  return {
    file_id = row.file and row.file.meta.id,
    kind = row.kind,
    key = row.key,
    side = side,
    line = cell and cell.line,
    col = cursor[2],
    offset = cursor[1] - top,
  }
end

function Session:restore(anchor)
  if not anchor then
    return
  end
  local target = self.file_rows[anchor.file_id]
  for i, row in ipairs(self.rows) do
    if row.file and row.file.meta.id == anchor.file_id then
      local cell
      if anchor.side == "old" then
        cell = row.old
      else
        cell = row.new
      end
      if anchor.line and cell and cell.line == anchor.line then
        target = i
        break
      end
      if not anchor.line and row.kind == anchor.kind and row.key == anchor.key then
        target = i
        break
      end
    end
  end
  if target then
    local win = self.layout == "split" and anchor.side == "new" and self.right_win or self.main_win
    if valid_win(win) then
      local binding = M.buffers[api.nvim_win_get_buf(win)]
      local cell = cell_for(self.rows[target], binding.side)
      api.nvim_win_set_cursor(win, { target, math.min(anchor.col or 0, cell and #cell.text or 0) })
      api.nvim_win_call(win, function()
        vim.fn.winrestview({
          topline = math.min(math.max(1, target - (anchor.offset or 3)), self:topline(target)),
        })
      end)
      self.last_code_win = win
      self:sync_scroll(win)
    end
  end
end

-- The highest topline that still shows the row at index. A commit row directly
-- above a file header names the commit the file belongs to, so scrolling that
-- header to the top must not hide it (focus renders exactly this pair).
function Session:topline(index)
  local row, previous = self.rows[index], self.rows[index - 1]
  if row and row.kind == "file" and previous and previous.kind == "group" then
    return index - 1
  end
  return index
end

function Session:sync_scroll(win)
  if self.layout ~= "split" or not valid_win(self.right_win) then
    return
  end
  local other = win == self.right_win and self.main_win or self.right_win
  if not valid_win(other) then
    return
  end
  local top = api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)
  api.nvim_win_call(other, function()
    vim.fn.winrestview({ topline = top })
  end)
end

function Session:render(anchor)
  if self.closed or not valid_win(self.main_win) then
    return
  end
  self.rendering = true
  self.rows, self.file_rows, self.hunk_rows = {}, {}, {}
  self.digits = 4
  local model = require("rill.model")
  local function add_file(file)
    local meta = file.meta
    local rename = meta.old_path and meta.old_path ~= meta.path and (meta.old_path .. " → ") or ""
    local stats = ("  +%d −%d"):format(meta.additions or 0, meta.deletions or 0)
    self.file_rows[meta.id] = #self.rows + 1
    self.rows[#self.rows + 1] = {
      kind = "file",
      file = file,
      text = (self.collapsed[meta.id] and "▸ " or "▾ ") .. rename .. meta.path .. stats,
    }
    if not self.collapsed[meta.id] then
      local previous_hunk
      for _, row in ipairs(model.project(file, self.layout)) do
        row.file = file
        if row.hunk and row.hunk ~= previous_hunk and row.kind == "code" then
          self.hunk_rows[#self.hunk_rows + 1] = #self.rows + 1
          previous_hunk = row.hunk
        end
        self.rows[#self.rows + 1] = row
        self.digits = math.max(
          self.digits,
          #tostring(row.old and row.old.line or 0),
          #tostring(row.new and row.new.line or 0)
        )
      end
    end
    self.rows[#self.rows + 1] = { kind = "meta", file = file, text = "" }
  end
  local groups = self:groups()
  if groups then
    local shown = {}
    for index = 1, #groups do
      shown[index] = {}
    end
    for _, file in ipairs(self.files) do
      local members = shown[file.meta.group]
      if members and (not self.focus_id or file.meta.id == self.focus_id) then
        members[#members + 1] = file
      end
    end
    -- Each commit row carries the first file rendered under it, so cursor,
    -- anchor, gf and Sidekick context treat it like that file's header. Focus
    -- renders only the focused file's commit; the stream renders every commit,
    -- an empty one as "(no changes)", so a requested commit never vanishes.
    for index, group in ipairs(groups) do
      local members = shown[index]
      if #members > 0 or not self.focus_id then
        self.rows[#self.rows + 1] =
          { kind = "group", group = index, file = members[1], text = group_label(index, #groups, group) }
        if #members == 0 then
          self.rows[#self.rows + 1] = { kind = "meta", group = index, text = "  (no changes)" }
          self.rows[#self.rows + 1] = { kind = "meta", group = index, text = "" }
        end
        for _, file in ipairs(members) do
          add_file(file)
        end
      end
    end
  else
    for _, file in ipairs(self.files) do
      if not self.focus_id or file.meta.id == self.focus_id then
        add_file(file)
      end
    end
  end
  if #self.rows == 0 then
    self.rows = {
      {
        kind = "meta",
        text = self.error or (self.snapshot and "No changes in this comparison." or "Loading Git changes…"),
      },
    }
  end
  self:windows()
  local left, right = {}, {}
  for _, row in ipairs(self.rows) do
    if row.kind == "code" then
      local cell = cell_for(row, self.layout == "split" and "old" or "unified")
      left[#left + 1] = cell and cell.text or ""
      right[#right + 1] = row.new and row.new.text or ""
    else
      local text = row.text or ""
      text = display_label(text)
      left[#left + 1], right[#right + 1] = text, text
    end
  end
  set_lines(api.nvim_win_get_buf(self.main_win), left)
  if valid_win(self.right_win) then
    set_lines(api.nvim_win_get_buf(self.right_win), right)
  end
  self:render_tree()
  self:restore(anchor)
  -- Follow the pane restore() put the cursor in: in split, the After pane's
  -- position names the current file and commit, not the Before pane's.
  local cursor_win = valid_win(self.last_code_win) and self.last_code_win or self.main_win
  local cursor_row = self.rows[api.nvim_win_get_cursor(cursor_win)[1]]
  if cursor_row and cursor_row.file then
    self.current_file = cursor_row.file.meta.id
  end
  self.current_group = row_group(cursor_row) or self.current_group
  self:titles()
  self:highlight_tree()
  self.rendering = false
  self:queue_visible()
end

function Session:render_tree()
  if not valid_win(self.tree_win) then
    return
  end
  -- Node paths double as closed_dirs keys. Commits mode prefixes them with
  -- "@<group>" so the same directory in two commits folds independently.
  local function insert(root, file, prefix)
    local parts, node, path = vim.split(file.meta.path, "/", { plain = true }), root, prefix
    for index, name in ipairs(parts) do
      path = path == "" and name or path .. "/" .. name
      if not node.children[name] then
        node.children[name] = { name = name, path = path, children = {}, order = {} }
        node.order[#node.order + 1] = name
      end
      node = node.children[name]
      if index == #parts then
        node.file = file
      end
    end
  end
  local groups = self:groups()
  local roots = {}
  for index = 1, groups and #groups or 1 do
    roots[index] = { children = {}, order = {} }
  end
  for _, file in ipairs(self.files) do
    local group = groups and file.meta.group
    if not groups then
      insert(roots[1], file, "")
    elseif roots[group] then
      roots[group].first = roots[group].first or file
      insert(roots[group], file, "@" .. group)
    end
  end
  local lines, entries = {}, {}
  local function visit(node, depth)
    for _, key in ipairs(node.order) do
      local child, label = node.children[key], key
      -- Compact a chain of directories into one row. Deep monorepo paths should
      -- leave the narrow tree's width for filenames, not empty indentation.
      while not child.file and not self.closed_dirs[child.path] and #child.order == 1 do
        local descendant = child.children[child.order[1]]
        if descendant.file then
          break
        end
        child, label = descendant, label .. "/" .. descendant.name
      end
      local indent = string.rep("  ", depth)
      if child.file then
        lines[#lines + 1] = indent .. (child.file.meta.status or "M"):sub(1, 1) .. " " .. child.name
        entries[#entries + 1] = { file = child.file }
      else
        if vim.fn.strdisplaywidth(label) > api.nvim_win_get_width(self.tree_win) - #indent - 3 then
          label = vim.fn.pathshorten(label)
        end
        lines[#lines + 1] = indent .. (self.closed_dirs[child.path] and "▸ " or "▾ ") .. label .. "/"
        entries[#entries + 1] = { directory = child.path }
        if not self.closed_dirs[child.path] then
          visit(child, depth + 1)
        end
      end
    end
  end
  if groups then
    -- A commit node folds like a directory (za) and carries its first file,
    -- so Enter, gf and context() on it act on that file.
    for index, group in ipairs(groups) do
      local key, root = "@" .. index, roots[index]
      lines[#lines + 1] = (self.closed_dirs[key] and "▸ " or "▾ ")
        .. group_label(index, #groups, group, "tree")
      entries[#entries + 1] = { group = index, key = key, file = root.first }
      if not self.closed_dirs[key] then
        if #root.order == 0 then
          lines[#lines + 1] = "  (no changes)"
          entries[#entries + 1] = { placeholder = true }
        end
        visit(root, 1)
      end
    end
  else
    visit(roots[1], 0)
  end
  self.tree_entries = entries
  local buf = self:buffer("files", nil, true)
  for i, line in ipairs(lines) do
    lines[i] = display_label(line)
  end
  set_lines(
    buf,
    #lines > 0 and lines or { self.error and "Git error" or self.snapshot and "No changes" or "Loading…" }
  )
  self:highlight_tree()
end

function Session:highlight_tree()
  local buf = self.bufs.files
  if not valid_buf(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, tree_ns, 0, -1)
  for index, entry in ipairs(self.tree_entries or {}) do
    if entry.group then
      api.nvim_buf_set_extmark(buf, tree_ns, index - 1, 0, { line_hl_group = "RillGroup" })
    elseif entry.file and entry.file.meta.id == self.current_file then
      api.nvim_buf_set_extmark(buf, tree_ns, index - 1, 0, { line_hl_group = "RillTreeCurrent" })
    elseif entry.directory or entry.placeholder then
      api.nvim_buf_set_extmark(buf, tree_ns, index - 1, 0, { line_hl_group = "RillMuted" })
    end
  end
end

function Session:current()
  local buf = api.nvim_get_current_buf()
  local binding = M.buffers[buf]
  if binding and binding.tree then
    local entry = self.tree_entries[api.nvim_win_get_cursor(0)[1]]
    return entry and entry.file, nil, entry
  end
  local win = binding and binding.session == self and api.nvim_get_current_win()
    or self.last_code_win
    or self.main_win
  if valid_win(win) then
    local row = self.rows[api.nvim_win_get_cursor(win)[1]]
    return row and row.file, row
  end
end

function Session:cursor_changed(buf)
  local binding = M.buffers[buf]
  if not binding or binding.tree then
    return
  end
  self.last_code_win = api.nvim_get_current_win()
  local row = self.rows[api.nvim_win_get_cursor(0)[1]]
  local group = row_group(row)
  if row and row.file and self.current_file ~= row.file.meta.id then
    self.current_file, self.current_group = row.file.meta.id, group or self.current_group
    self:highlight_tree()
    self:titles()
  elseif group and group ~= self.current_group then
    -- An empty commit's rows have no file but still name their commit.
    self.current_group = group
    self:titles()
  end
  self:queue_visible()
end

-- Keep cancellation handles only while a request is in flight. A completed
-- callback can close over whole source snapshots; retaining its owner until the
-- tab closes would bypass the source-cache budget even after an eviction.
function Session:request(start, callback)
  local key, finished = {}, false
  local cancel = start(function(...)
    finished = true
    self.jobs[key] = nil
    callback(...)
  end)
  if not finished then
    self.jobs[key] = cancel
  end
end

function Session:ensure_source(file, callback)
  self.cache:touch(file)
  if file.sources then
    callback(nil)
    return
  end
  if file.source_error then
    callback(file.source_error)
    return
  end
  if file.source_waiters then
    table.insert(file.source_waiters, callback)
    return
  end
  file.source_waiters = { callback }
  local sources, errors, remaining = {}, {}, 2
  local generation = self.generation
  for _, side in ipairs({ "old", "new" }) do
    self:request(function(done)
      return require("rill.git").source(file.snapshot or self.snapshot, file.meta, side, done)
    end, function(err, source)
      if self.closed or generation ~= self.generation or file.disposed then
        return
      end
      if err then
        errors[#errors + 1] = tostring(err)
      else
        sources[side] = source
      end
      remaining = remaining - 1
      if remaining ~= 0 then
        return
      end
      local failure = errors[1]
      if not failure then
        local ok, message = require("rill.model").hydrate(file, sources.old.lines, sources.new.lines)
        if not ok then
          failure = message or "Source changed; refresh this review."
        end
      end
      if failure then
        file.source_error = failure
      else
        file.sources = sources
      end
      local waiters = file.source_waiters
      file.source_waiters = nil
      for _, waiter in ipairs(waiters) do
        waiter(failure)
      end
      self:prune_cache()
    end)
  end
end

-- Source text and capture tables have an LRU budget separate from compact patch
-- rows. Visible files and explicit context expansions pin their data; eviction
-- never changes the document's source addresses or interrupts active consumers.
function Session:prune_cache()
  if self.cache_scheduled or self.closed then
    return
  end
  self.cache_scheduled = true
  vim.schedule(function()
    self.cache_scheduled = false
    if self.closed or not valid_win(self.main_win) then
      return
    end
    local bounds = api.nvim_win_call(self.main_win, function()
      return { vim.fn.line("w0"), vim.fn.line("w$") }
    end)
    local protected = {}
    for i = math.max(1, bounds[1] - 25), math.min(#self.rows, bounds[2] + 40) do
      local file = self.rows[i].file
      if file then
        protected[file] = true
      end
    end
    self.cache_stats = self.cache:prune(self.files, protected)
  end)
end

-- Hydrating visible source reveals the exact trailing context count. Coalesce
-- projection updates across both source reads/files instead of rebuilding once
-- per capture callback. Decoration completion itself only requests a redraw.
function Session:queue_render()
  if self.render_scheduled or self.closed then
    return
  end
  self.render_scheduled = true
  vim.schedule(function()
    self.render_scheduled = false
    if not self.closed then
      self:render(self:anchor())
    end
  end)
end

function Session:queue_visible()
  if self.visible_scheduled or self.closed or not self.snapshot then
    return
  end
  self.visible_scheduled = true
  vim.schedule(function()
    self.visible_scheduled = false
    if self.closed or not valid_win(self.main_win) then
      return
    end
    local bounds = api.nvim_win_call(self.main_win, function()
      return { vim.fn.line("w0"), vim.fn.line("w$") }
    end)
    local top, bottom = bounds[1], bounds[2]
    local seen, count = {}, 0
    for i = math.max(1, top - 25), math.min(#self.rows, bottom + 40) do
      local file = self.rows[i].file
      if file and not seen[file] and not file.meta.binary and not file.meta.omitted_reason then
        seen[file], count = true, count + 1
        self.cache:touch(file)
        local function redraw()
          if not self.closed then
            self:repaint()
            self:prune_cache()
          end
        end
        if self.opts.syntax ~= false then
          local hydrated = file.hydrated
          self:ensure_source(file, function(err)
            if not err then
              require("rill.highlight").syntax(file, redraw)
              if not hydrated then
                self:queue_render()
              end
            end
          end)
        end
        if count >= 4 then
          break
        end
      end
    end
    self:prune_cache()
  end)
end

function Session:load(opts)
  if self.closed then
    return
  end
  local anchor = self:anchor()
  self.generation = self.generation + 1
  local generation = self.generation
  for _, cancel in pairs(self.jobs) do
    pcall(cancel)
  end
  self.jobs = {}
  -- Canceled readers cannot settle their old waiters. If the replacement load
  -- fails, the retained review must still be able to request its source again.
  for _, file in ipairs(self.files) do
    file.source_waiters = nil
  end
  self.opts = vim.tbl_extend("force", self.opts, opts or {})
  self.error = nil
  self:request(function(done)
    return require("rill.git").load(self.opts, done)
  end, function(err, snapshot)
    if self.closed or generation ~= self.generation then
      return
    end
    if err then
      self.error = tostring(err)
      if not self.snapshot then
        self:render()
      end
      notify(self.error, vim.log.levels.ERROR)
      return
    end
    local previous, files, by_id, focus_index = {}, {}, {}, nil
    for index, file in ipairs(self.files) do
      previous[file.meta.id] = file
      if file.meta.id == self.focus_id then
        focus_index = index
      end
    end
    for _, meta in ipairs(snapshot.files) do
      local file = require("rill.model").parse(meta)
      local old = previous[meta.id]
      if old and old.meta.patch == meta.patch and next(old.expansion) then
        file.pending_expansion = vim.deepcopy(old.expansion)
      end
      -- In commits mode each file belongs to one commit's own comparison.
      -- Source reads, Enter-to-source and context() revisions all follow
      -- file.snapshot, so they resolve against that commit, not the composite.
      local group = meta.group and snapshot.groups and snapshot.groups[meta.group]
      file.snapshot = group and group.snapshot or snapshot
      file.syntax_limits = { max_lines = self.opts.syntax_max_lines, max_bytes = self.opts.syntax_max_bytes }
      files[#files + 1] = file
      by_id[meta.id] = file
    end
    for _, file in ipairs(self.files) do
      require("rill.highlight").dispose(file)
    end
    self.snapshot, self.files, self.by_id = snapshot, files, by_id
    local target = anchor
    if self.pending_focus and #files > 0 then
      -- view = "focus" applies once, on the first load that has files: an
      -- empty comparison stays in the stream and a later refresh still
      -- focuses. After that, refreshes keep whatever the reviewer chose.
      self.pending_focus = false
      self.focus_id = anchor and by_id[anchor.file_id] and anchor.file_id or files[1].meta.id
      if self.focus_id ~= (anchor and anchor.file_id) then
        target = { file_id = self.focus_id, kind = "file" }
      end
    elseif self.focus_id and not by_id[self.focus_id] then
      -- The focused file left the comparison (committed, reverted, …). Focus
      -- whichever file now sits at its index rather than dropping the reviewer
      -- into the whole stream; only an empty comparison returns to it.
      local file = files[math.min(focus_index or 1, #files)]
      self.focus_id = file and file.meta.id
      target = file and { file_id = file.meta.id, kind = "file" } or anchor
    end
    self:render(target)
    -- Expanded rows depend on full sources. Revalidate the new comparison before
    -- restoring them, even when its compact patch looks identical: unchanged
    -- worktree text may have changed since the previous snapshot was captured.
    local pending = {}
    for _, file in ipairs(files) do
      if file.pending_expansion then
        pending[#pending + 1] = file
      end
    end
    local function restore_next(index)
      local file = pending[index]
      if not file or self.closed or generation ~= self.generation then
        return
      end
      self:ensure_source(file, function(failure)
        local current_anchor = self:anchor()
        if not failure then
          file.expansion = file.pending_expansion
        end
        file.pending_expansion = nil
        self:render(current_anchor)
        restore_next(index + 1)
      end)
    end
    restore_next(1)
  end)
end

function Session:toggle_layout()
  local anchor = self:anchor()
  self.layout = self.layout == "unified" and "split" or "unified"
  self:render(anchor)
  local win = self.layout == "split" and anchor and anchor.side == "new" and self.right_win or self.main_win
  if valid_win(win) then
    api.nvim_set_current_win(win)
  end
end

function Session:toggle_focus()
  -- An explicit gf is the reviewer's choice; the opening view = "focus"
  -- preference must not override it on a later refresh.
  self.pending_focus = false
  local file = self:current()
  if not file then
    return
  end
  local anchor = self:anchor()
  if self.focus_id then
    self.focus_id = nil
    self:render(self.stream_anchor or anchor)
    self.stream_anchor = nil
  else
    self.stream_anchor = anchor
    self.focus_id = file.meta.id
    self:render(
      anchor and anchor.file_id == self.focus_id and anchor or { file_id = self.focus_id, kind = "file" }
    )
  end
  if valid_win(self.last_code_win) then
    api.nvim_set_current_win(self.last_code_win)
  end
end

function Session:jump_file(file)
  if self.focus_id then
    self.focus_id = file.meta.id
    self:render()
  end
  local index = self.file_rows[file.meta.id]
  if index and valid_win(self.main_win) then
    api.nvim_set_current_win(self.main_win)
    api.nvim_win_set_cursor(self.main_win, { index, 0 })
    vim.cmd("normal! zt")
    local top = self:topline(index)
    if top < vim.fn.line("w0") then
      vim.fn.winrestview({ topline = top })
    end
    self:sync_scroll(self.main_win)
    self.current_file, self.current_group = file.meta.id, file.meta.group or self.current_group
    self:highlight_tree()
    self:titles()
    self:queue_visible()
  end
end

-- ]C / [C: the first file of the next / previous commit that has changes,
-- wrapping like Tab. Empty commits have no file to land on and are skipped.
function Session:move_commit(direction)
  local groups = self:groups()
  if not groups or #self.files == 0 then
    return
  end
  local first = {}
  for _, file in ipairs(self.files) do
    local group = file.meta.group
    if group and not first[group] then
      first[group] = file
    end
  end
  local file, row, entry = self:current()
  local current = (entry and entry.group)
    or row_group(row)
    or (file and file.meta.group)
    or self.current_group
    or 1
  for step = 1, #groups do
    local target = first[(current - 1 + direction * step) % #groups + 1]
    if target then
      self:jump_file(target)
      return
    end
  end
end

function Session:cycle_file(direction)
  if #self.files == 0 then
    return
  end
  local current = self:current()
  local index = direction > 0 and 0 or 1
  for i, file in ipairs(self.files) do
    if file == current then
      index = i
      break
    end
  end
  self:jump_file(self.files[(index - 1 + direction) % #self.files + 1])
end

function Session:move(kind, direction)
  local indexes = kind == "hunk" and self.hunk_rows or vim.tbl_values(self.file_rows)
  table.sort(indexes)
  local win = api.nvim_get_current_win()
  if not M.buffers[api.nvim_win_get_buf(win)] or M.buffers[api.nvim_win_get_buf(win)].tree then
    win = self.main_win
  end
  local current, target = api.nvim_win_get_cursor(win)[1], nil
  if direction > 0 then
    for _, index in ipairs(indexes) do
      if index > current then
        target = index
        break
      end
    end
  else
    for i = #indexes, 1, -1 do
      if indexes[i] < current then
        target = indexes[i]
        break
      end
    end
  end
  if target then
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { target, 0 })
    vim.cmd("normal! zz")
    self:sync_scroll(win)
  end
end

function Session:expand(edge, all_file)
  local file, row = self:current()
  if not file then
    return
  end
  if file.meta.binary or file.meta.omitted_reason then
    notify(file.meta.omitted_reason or "Binary files have no text context.")
    return
  end
  local anchor = self:anchor()
  local key = row and row.kind == "gap" and row.key
  if not key and not all_file then
    local start = valid_win(self.last_code_win) and api.nvim_win_get_cursor(self.last_code_win)[1]
      or self.file_rows[file.meta.id]
    for i = start or 1, #self.rows do
      if self.rows[i].file ~= file then
        break
      end
      if self.rows[i].kind == "gap" then
        key = self.rows[i].key
        break
      end
    end
  end
  self:ensure_source(file, function(err)
    if err then
      notify(tostring(err), vim.log.levels.WARN)
      return
    end
    local model = require("rill.model")
    if all_file then
      model.expand_all(file)
    elseif key then
      model.expand(file, key, edge, self.opts.context_step)
    else
      return
    end
    self.collapsed[file.meta.id] = nil
    self:render(anchor)
  end)
end

function Session:collapse_context()
  local file = self:current()
  if not file then
    return
  end
  local anchor = self:anchor()
  require("rill.model").collapse(file)
  self:render(anchor)
end

function Session:toggle_file()
  local file, _, entry = self:current()
  -- In the tree, za folds the node under the cursor: a commit or a directory.
  local key = entry and (entry.key or entry.directory)
  if key then
    self.closed_dirs[key] = not self.closed_dirs[key]
    self:render_tree()
    return
  end
  if not file then
    return
  end
  self.collapsed[file.meta.id] = not self.collapsed[file.meta.id]
  self:render({ file_id = file.meta.id, kind = "file" })
end

function Session:toggle_tree()
  if valid_win(self.tree_win) then
    api.nvim_win_close(self.tree_win, true)
    self.tree_win = nil
  elseif valid_win(self.main_win) then
    api.nvim_win_call(self.main_win, function()
      vim.cmd("topleft vertical " .. self.opts.tree_width .. "split")
      self.tree_win = api.nvim_get_current_win()
      api.nvim_win_set_buf(self.tree_win, self:buffer("files", nil, true))
    end)
    self:options(self.tree_win, true)
    self:titles()
    self:render_tree()
  end
end

function Session:open_source()
  local file, row, entry = self:current()
  if entry and entry.directory then
    self.closed_dirs[entry.directory] = not self.closed_dirs[entry.directory]
    self:render_tree()
    return
  end
  if entry and file then
    self:jump_file(file)
    return
  end
  if row and row.kind == "group" then
    -- A commit row has no source of its own; Enter moves to its first file.
    if file then
      self:jump_file(file)
    end
    return
  end
  if row and row.kind == "gap" then
    self:expand("top")
    return
  end
  if not file then
    return
  end
  local binding = M.buffers[api.nvim_get_current_buf()]
  local side = row and row.kind == "code" and source_side(row, binding and binding.side) or "new"
  local cell = row and cell_for(row, binding and binding.side or "unified")
  if row and row.kind == "code" and not cell then
    return
  end
  local line = cell and cell.line or 1
  local column = cell and api.nvim_win_get_cursor(0)[2] or 0
  local generation = self.generation
  self:request(function(done)
    return require("rill.source").locate(file, side, line, done)
  end, function(err, location)
    if self.closed or self.generation ~= generation then
      return
    end
    if err then
      notify(tostring(err), vim.log.levels.WARN)
      return
    end
    -- A launch from a sidebar must never replace that plugin's owned buffer.
    -- Only the launch window may be a start screen; arbitrary scratch windows
    -- elsewhere can belong to another plugin and are not editing destinations.
    local function available(win)
      return valid_win(win)
        and api.nvim_win_get_config(win).relative == ""
        and not M.buffers[api.nvim_win_get_buf(win)]
        and not vim.wo[win].previewwindow
        and not vim.wo[win].winfixwidth
        and not vim.wo[win].winfixheight
        and not vim.wo[win].winfixbuf
    end
    local function empty(buf)
      return valid_buf(buf)
        and api.nvim_buf_get_name(buf) == ""
        and not vim.bo[buf].modified
        and api.nvim_buf_line_count(buf) == 1
        and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
    end
    local function start_screen(win)
      if not available(win) then
        return false
      end
      local buf = api.nvim_win_get_buf(win)
      local ft = vim.bo[buf].filetype
      return vim.bo[buf].buftype == "nofile"
        and not vim.bo[buf].modified
        and (
          (ft == "" and empty(buf))
          or ft == "snacks_dashboard"
          or ft == "dashboard"
          or ft == "alpha"
          or ft == "starter"
          or ft == "ministarter"
        )
    end
    local function normal(win)
      return available(win) and vim.bo[api.nvim_win_get_buf(win)].buftype == ""
    end
    local target = (normal(self.origin_win) or start_screen(self.origin_win)) and self.origin_win or nil
    if not target then
      for _, win in ipairs(api.nvim_list_wins()) do
        if normal(win) then
          target = win
          break
        end
      end
    end
    local buf = vim.fn.bufadd(location.path)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    if target then
      local previous = api.nvim_win_get_buf(target)
      api.nvim_set_current_win(target)
      api.nvim_win_set_buf(target, buf)
      -- Replacing the startup's empty buffer should not leave a phantom entry
      -- in the bufferline. Keep any buffer still displayed elsewhere untouched.
      if empty(previous) and #vim.fn.win_findbuf(previous) == 0 then
        vim.bo[previous].buflisted = false
      end
    else
      -- Split directly onto the file, avoiding tabnew's extra listed buffer.
      vim.cmd("tab sbuffer " .. buf)
    end
    -- BufEnter hooks or an edit during the asynchronous Git read can change
    -- the destination again; never publish a cursor outside the actual buffer.
    local target_line = math.max(1, math.min(location.line, api.nvim_buf_line_count(buf)))
    location.exact = location.exact and target_line == location.line
    location.line = target_line
    local text = api.nvim_buf_get_lines(buf, location.line - 1, location.line, false)[1] or ""
    api.nvim_win_set_cursor(0, { location.line, math.min(column, #text) })
    vim.cmd("normal! zz")
    if not location.exact then
      local endpoint = file.snapshot.right
      notify(
        "line changed since "
          .. (endpoint.rev or endpoint.label or endpoint.kind)
          .. "; opened the nearest line"
      )
    end
  end)
end

function Session:help()
  local commits = self:groups() ~= nil
  local lines = {
    "Rill · Git review",
    "",
    commits and "Tab / S-Tab  next / previous file, across commits" or "Tab / S-Tab  next / previous file",
    "gs        unified / split",
    "gf        focus current file / return to stream",
    "[f / ]f   previous / next file",
    "[c / ]c   previous / next hunk",
    "Enter     open source · expand gap · select tree file",
    "zo / zB   reveal 20 lines from top / bottom of gap",
    "zO        expand entire gap",
    "zR        show full current file",
    "zM        collapse unchanged context",
    "za        collapse / expand current file · tree: fold commit / directory",
    "gT        toggle file tree",
    "gw        toggle wrapping (unified)",
    "gr        refresh comparison",
    "q         close review",
    "",
    "Sidekick: <leader>ai comment · aI absolute · av Claude · ax Codex",
    "           al/aL lines · af/aF file · at selection",
    "",
    "Source line numbers are in the gutter. Review-buffer row numbers differ.",
    "Enter opens the real working file; changed/deleted lines use the nearest line.",
    "Plain / searches materialized text; expand context to include hidden lines.",
    "",
    "Press q or Escape to close help.",
  }
  if commits then
    -- Right after the "[c / ]c" hunk line.
    table.insert(lines, 8, "[C / ]C   previous / next commit")
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(83, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Rill ",
  })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if valid_win(win) then
        api.nvim_win_close(win, true)
      end
    end, { buffer = buf })
  end
end

function Session:keys(buf, tree)
  local actions = {
    ["q"] = {
      "Close review",
      function()
        self:close()
      end,
    },
    ["<Tab>"] = {
      "Next file",
      function()
        self:cycle_file(1)
      end,
    },
    ["<S-Tab>"] = {
      "Previous file",
      function()
        self:cycle_file(-1)
      end,
    },
    ["gs"] = {
      "Toggle unified / split",
      function()
        self:toggle_layout()
      end,
    },
    ["gf"] = {
      "Focus file / review stream",
      function()
        self:toggle_focus()
      end,
    },
    ["<CR>"] = {
      "Open source / expand context",
      function()
        self:open_source()
      end,
    },
    ["]f"] = {
      "Next file",
      function()
        self:move("file", 1)
      end,
    },
    ["[f"] = {
      "Previous file",
      function()
        self:move("file", -1)
      end,
    },
    ["]c"] = {
      "Next hunk",
      function()
        self:move("hunk", 1)
      end,
    },
    ["[c"] = {
      "Previous hunk",
      function()
        self:move("hunk", -1)
      end,
    },
    -- Mapped in every review; a single comparison has no commits to visit.
    ["]C"] = {
      "Next commit",
      function()
        self:move_commit(1)
      end,
    },
    ["[C"] = {
      "Previous commit",
      function()
        self:move_commit(-1)
      end,
    },
    ["zo"] = {
      "Expand context from top",
      function()
        self:expand("top")
      end,
    },
    ["zB"] = {
      "Expand context from bottom",
      function()
        self:expand("bottom")
      end,
    },
    ["zO"] = {
      "Expand whole gap",
      function()
        self:expand("all")
      end,
    },
    ["zR"] = {
      "Expand full file",
      function()
        self:expand("all", true)
      end,
    },
    ["zM"] = {
      "Collapse unchanged context",
      function()
        self:collapse_context()
      end,
    },
    ["za"] = {
      "Collapse file",
      function()
        self:toggle_file()
      end,
    },
    ["gT"] = {
      "Toggle file tree",
      function()
        self:toggle_tree()
      end,
    },
    ["gr"] = {
      "Refresh review",
      function()
        self:load()
      end,
    },
    ["g?"] = {
      "Review help",
      function()
        self:help()
      end,
    },
    ["gw"] = {
      "Toggle unified wrapping",
      function()
        if self.layout == "unified" then
          self.opts.wrap = not self.opts.wrap
          self:options(self.main_win)
        end
      end,
    },
  }
  for key, action in pairs(actions) do
    vim.keymap.set("n", key, action[2], { buffer = buf, silent = true, desc = "Rill: " .. action[1] })
  end
  if self.opts.sidekick ~= false then
    require("rill.sidekick").attach(buf)
  end
end

function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  self.generation = self.generation + 1
  for _, cancel in pairs(self.jobs) do
    pcall(cancel)
  end
  self.jobs = {}
  for _, file in ipairs(self.files) do
    require("rill.highlight").dispose(file)
  end
  M.sessions[self.tab] = nil
  -- Close only this session's windows; user buffers and the originating tab are
  -- not ours to delete. TabClosed may re-enter close, hence closed is set first.
  if api.nvim_tabpage_is_valid(self.tab) then
    if #api.nvim_list_tabpages() > 1 then
      api.nvim_set_current_tabpage(self.tab)
      vim.cmd("tabclose")
    else
      for _, win in ipairs({ self.tree_win, self.right_win }) do
        if valid_win(win) then
          pcall(api.nvim_win_close, win, true)
        end
      end
      if valid_win(self.main_win) then
        api.nvim_win_set_buf(self.main_win, api.nvim_create_buf(true, false))
      end
    end
  end
  for _, buf in pairs(self.bufs) do
    M.buffers[buf] = nil
    if valid_buf(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  if valid_win(self.origin_win) then
    api.nvim_set_current_win(self.origin_win)
  end
end

function M.open(opts)
  local cache = require("rill.cache").new(opts.source_cache_bytes)
  initialize()
  local origin_win = api.nvim_get_current_win()
  vim.cmd("tab split")
  local tab = api.nvim_get_current_tabpage()
  serial = serial + 1
  local self = setmetatable({
    id = tostring(serial),
    tab = tab,
    origin_win = origin_win,
    main_win = api.nvim_get_current_win(),
    layout = opts.layout or "unified",
    opts = opts,
    -- view = "focus" is honored once, by the first load that finds files.
    pending_focus = opts.view == "focus",
    rows = {},
    files = {},
    by_id = {},
    bufs = {},
    jobs = {},
    file_rows = {},
    hunk_rows = {},
    collapsed = {},
    closed_dirs = {},
    tree_entries = {},
    generation = 0,
    cache = cache,
  }, Session)
  M.sessions[tab] = self
  self:windows()
  self:toggle_tree()
  api.nvim_set_current_win(self.main_win)
  self:render()
  self:load()
  return self
end

function M.current()
  return M.sessions[api.nvim_get_current_tabpage()]
end

-- Selection ranges use Sidekick's captured buffer coordinates. Group only
-- contiguous source lines on one side: headers/gaps break spans, and mixed
-- old/new or multi-file selections must never become one invented file range.
function M.context(ctx)
  local binding = M.buffers[ctx.buf]
  if not binding or binding.session.closed then
    return
  end
  local session = binding.session
  if not session.snapshot then
    return
  end
  local row_index = ctx.range and ctx.range.from[1] or ctx.row or 1
  if binding.tree then
    local entry = session.tree_entries[row_index]
    if not entry or not entry.file then
      return
    end
    return { root = session.snapshot.root, file = entry.file.meta, spans = {} }
  end
  local selected = require("rill.selection").rows(ctx)
  local indexes = vim.tbl_keys(selected)
  table.sort(indexes)
  local result = { root = session.snapshot.root, spans = {} }
  local active
  for _, i in ipairs(indexes) do
    local row = session.rows[i]
    if row and row.file then
      result.file = result.file or row.file.meta
    end
    local cell = row and cell_for(row, binding.side)
    if not cell then
      active = nil
    else
      local side = source_side(row, binding.side)
      local file = row.file
      local snapshot = file.snapshot or session.snapshot
      local endpoint = side == "old" and snapshot.left or snapshot.right
      local path = side == "old" and (file.meta.old_path or file.meta.path) or file.meta.path
      local value = selected[i]
      local start_col, end_col, partial = value.start_col, value.end_col, value.partial
      if
        not active
        or active.path ~= path
        or active.side ~= side
        or active.end_line + 1 ~= cell.line
        or partial
        or active.partial
      then
        active = {
          path = path,
          absolute_path = snapshot.root .. "/" .. path,
          side = side,
          revision = endpoint.rev or endpoint.label or endpoint.kind,
          start_line = cell.line,
          end_line = cell.line,
          start_col = start_col,
          end_col = end_col,
          lines = {},
          partial = partial,
        }
        result.spans[#result.spans + 1] = active
      end
      active.lines[#active.lines + 1] = value.text
      active.end_line, active.end_col = cell.line, end_col
    end
  end
  return result.file and result or nil
end

return M
