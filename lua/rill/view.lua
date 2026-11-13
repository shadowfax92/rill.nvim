-- A review session owns its tab, scratch buffers, Git jobs and projected rows.
-- Source identities live on model cells; every navigation/integration operation
-- crosses the same row map, even when focus, context or layout changes its size.
local api = vim.api
local M = { sessions = {}, buffers = {} }
local Session = {}
Session.__index = Session
local ns = api.nvim_create_namespace("rill.view")
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

local Group = require("rill.group")
local Refs = require("rill.refs")
local group_label = Group.label

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
      elseif row.kind == "group" or row.kind == "commit" then
        mark(buf, line, { line_hl_group = "RillGroup", priority = 50 })
      elseif row.kind == "message" and row.muted then
        mark(buf, line, { line_hl_group = "RillMuted", priority = 50 })
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

-- Displayed commit/branch groups; nil for a combined or empty comparison.
function Session:groups()
  local groups = self.snapshot and self.snapshot.groups
  return groups and #groups > 0 and groups or nil
end

function Session:buffer(key, side)
  if valid_buf(self.bufs[key]) then
    M.buffers[self.bufs[key]].side = side
    return self.bufs[key]
  end
  local buf = api.nvim_create_buf(false, true)
  self.bufs[key] = buf
  M.buffers[buf] = { session = self, side = side }
  api.nvim_buf_set_name(buf, ("rill://%s/%s"):format(self.id, key))
  for option, value in pairs({
    buftype = "nofile",
    bufhidden = "hide",
    swapfile = false,
    undolevels = -1,
    filetype = "rill",
  }) do
    vim.bo[buf][option] = value
  end
  vim.b[buf].rill = true
  vim.bo[buf].modifiable = false
  self:keys(buf)
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

function Session:options(win)
  if not valid_win(win) then
    return
  end
  local options = {
    number = true,
    relativenumber = false,
    numberwidth = self.layout == "unified" and 13 or 7,
    signcolumn = "no",
    foldcolumn = "0",
    foldenable = false,
    spell = false,
    list = false,
    cursorline = true,
    cursorlineopt = "number",
    wrap = self.layout == "unified" and self.opts.wrap or false,
    linebreak = false,
    breakindent = false,
    conceallevel = 0,
    colorcolumn = "",
    scrolloff = 3,
    winfixwidth = false,
    scrollbind = self.layout == "split",
    cursorbind = false,
    statuscolumn = "%!v:lua.RillStatuscolumn()",
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
  local history = self.history
  if history then
    -- The listed position, with "+" while older pages remain unloaded.
    local commit = history.shown
    local index = commit and self:history_index(commit)
    local total = #history.commits .. (history.done and "" or "+")
    title = commit and ("[%s/%s] %s %s"):format(index or "?", total, commit.short, commit.subject)
      or "Loading history…"
    count = #self.files .. " files · " .. self:history_title() .. " "
  elseif groups then
    -- One composite comparison spans several commits; name the commit under
    -- the cursor instead of the first parent → last commit endpoints.
    local index = groups[self.current_group] and self.current_group or 1
    title = group_label(index, Group.commit_count(groups), groups[index], "title")
    if self.snapshot.branch then
      title = title .. " · vs " .. Refs.label(self.snapshot.branch.left)
    end
    count = #self.files .. " files · " .. Group.commit_count(groups) .. " commits "
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
        commits_view = self.snapshot and self.snapshot.commits_view,
        branch = self.opts.mode == "branch",
        history = history ~= nil,
      })
      api.nvim_set_option_value("winbar", bar, { win = win, scope = "local" })
      api.nvim_set_option_value(
        "statusline",
        "%#RillMuted# Rill · %<" .. escaped(path) .. "%=" .. count,
        { win = win, scope = "local" }
      )
    end
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
    path = row.file and row.file.meta.path,
    kind = row.kind,
    group = row_group(row),
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
    or (anchor.group and self.group_rows[anchor.group])
    or ((anchor.kind == "commit" or anchor.kind == "message") and self.message_row)
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
  self.rows, self.file_rows, self.hunk_rows, self.group_rows = {}, {}, {}, {}
  self.message_row = nil
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
      -- The blank separates bodies only: folded files stay a compact list.
      self.rows[#self.rows + 1] = { kind = "meta", file = file, text = "" }
    end
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
      if #members > 0 or not self.focus_id or self.focus_id == "group:" .. (group.oid or "worktree") then
        self.group_rows[index] = #self.rows + 1
        self.rows[#self.rows + 1] = {
          kind = "group",
          group = index,
          file = members[1],
          text = group_label(index, Group.commit_count(groups), group),
        }
        if #members == 0 then
          if not group.auto_merge then
            self.rows[#self.rows + 1] = { kind = "meta", group = index, text = "  (no changes)" }
          end
          self.rows[#self.rows + 1] = { kind = "meta", group = index, text = "" }
        end
        for _, file in ipairs(members) do
          add_file(file)
        end
      end
    end
  else
    if self.history and self.history.shown then
      self:message_rows(self.history.shown)
    end
    for _, file in ipairs(self.files) do
      if not self.focus_id or file.meta.id == self.focus_id then
        add_file(file)
      end
    end
  end
  if #self.rows == 0 then
    local empty = self.snapshot and "No changes in this comparison."
      or self.history and "Loading history…"
      or "Loading Git changes…"
    if self.snapshot and self.snapshot.branch then
      empty = "No changes vs " .. Refs.label(self.snapshot.branch.left) .. " — gb picks another base"
    end
    self.rows = {
      {
        kind = "meta",
        text = self.error or empty,
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

-- Hard-wrap one message line: the review buffer does not soft-wrap by default
-- and Git bodies are often unwrapped paragraphs. Bullets keep a hanging indent;
-- lines indented like code keep their shape and are only cut by the window.
local function wrap_message(line, width)
  -- Raw tabs would render as "\t". Expand to 8-column stops, as `git show`
  -- displays them, so tab-aligned text inside a message keeps its columns.
  if line:find("\t", 1, true) then
    local column = 0
    line = line:gsub("([^\t]*)\t", function(text)
      column = column + vim.fn.strdisplaywidth(text)
      local pad = 8 - column % 8
      column = column + pad
      return text .. string.rep(" ", pad)
    end)
  end
  if vim.fn.strdisplaywidth(line) <= width or line:match("^    ") then
    return { line }
  end
  local marker = line:match("^%s*[-*•+]%s+") or line:match("^%s*%d+[.)]%s+") or line:match("^%s*")
  local hang = string.rep(" ", vim.fn.strdisplaywidth(marker))
  local lines, current = {}, nil
  for word in line:sub(#marker + 1):gmatch("%S+") do
    if not current then
      current = marker .. word
    elseif vim.fn.strdisplaywidth(current .. " " .. word) <= width then
      current = current .. " " .. word
    else
      lines[#lines + 1] = current
      current = hang .. word
    end
  end
  lines[#lines + 1] = current or line
  return lines
end

-- A history document opens with the commit itself, as `git show` does: subject,
-- author, date, full OID and message body, then the scoped change totals. za on
-- these rows hides or shows the body for every commit in the session.
function Session:message_rows(commit)
  local rows, history = self.rows, self.history
  local body = commit.body ~= "" and vim.split(commit.body, "\n", { plain = true }) or {}
  local function add(text, muted)
    rows[#rows + 1] = { kind = "message", muted = muted, text = text }
  end
  self.message_row = #rows + 1
  rows[#rows + 1] = {
    kind = "commit",
    text = ("%s %s  %s"):format(
      #body == 0 and "●" or history.collapsed and "▸" or "▾",
      commit.short,
      commit.subject
    ),
  }
  local note = commit.merge and " · merge: changes vs first parent"
    or commit.root_commit and " · root commit"
    or ""
  add("  Author: " .. commit.author .. " <" .. commit.email .. ">", true)
  add("  Date:   " .. commit.date, true)
  add("  Commit: " .. commit.oid .. note, true)
  if #body > 0 then
    add("")
    if history.collapsed then
      add(("  … %d message %s hidden · za shows"):format(#body, #body == 1 and "line" or "lines"), true)
    else
      -- Rows are built before windows() opens or closes the split, so size
      -- from both panes' total for the layout being drawn. The gutter is
      -- digits*2+5 columns unified and digits+3 per split pane.
      local total = api.nvim_win_get_width(self.main_win)
      if valid_win(self.right_win) then
        total = total + api.nvim_win_get_width(self.right_win) + 1
      end
      local pane = self.layout == "unified" and total - 13 or math.floor((total - 1) / 2) - 7
      local width = math.max(30, math.min(100, pane - 3))
      for _, line in ipairs(body) do
        for _, piece in ipairs(wrap_message(line, width)) do
          add(piece == "" and "" or "  " .. piece)
        end
      end
    end
  end
  add("")
  local additions, deletions = 0, 0
  for _, file in ipairs(self.files) do
    additions, deletions = additions + (file.meta.additions or 0), deletions + (file.meta.deletions or 0)
  end
  local scope = self.opts.paths and #self.opts.paths > 0 and (" in " .. table.concat(self.opts.paths, ", "))
    or ""
  if #self.files == 0 then
    add("  No changes" .. scope, true)
  else
    add(
      ("  %d %s%s · +%d −%d"):format(
        #self.files,
        #self.files == 1 and "file" or "files",
        scope,
        additions,
        deletions
      ),
      true
    )
  end
  add("")
end

-- Index of a listed history commit, or nil once the list no longer holds it.
function Session:history_index(commit)
  for index, candidate in ipairs(self.history.commits) do
    if candidate == commit then
      return index
    end
  end
end

--- Load the next page of history (count commits) from the pinned head. `after`
--- runs once that page lands; while a page is in flight a newer `after` replaces
--- the pending one, so repeated Tab presses at the end take one step.
function Session:more_history(after)
  local history = self.history
  if not history or self.closed then
    return
  end
  if history.done then
    if after then
      after()
    end
    return
  end
  history.after = after or history.after
  if history.busy then
    return
  end
  history.busy = true
  self:render_tree()
  history.cancel = require("rill.git").log({
    cwd = self.opts.cwd,
    rev = self.opts.rev,
    head = history.head,
    paths = self.opts.paths,
    follow = self.opts.follow,
    skip = #history.commits,
    count = history.count,
  }, function(err, page)
    history.busy, history.cancel = false, nil
    if self.closed then
      return
    end
    local next_step = history.after
    history.after = nil
    if err then
      notify(tostring(err), vim.log.levels.ERROR)
      if #history.commits == 0 then
        self.error = tostring(err)
        self:render()
      else
        self:render_tree()
      end
      return
    end
    history.head, history.done = page.head, page.done
    vim.list_extend(history.commits, page.commits)
    if #history.commits == 0 then
      local scope = self.opts.paths
          and #self.opts.paths > 0
          and (" touch " .. table.concat(self.opts.paths, ", "))
        or ""
      self.error = "No commits" .. scope
      self:render()
      return
    end
    if not history.shown and not history.loading then
      self:load()
    else
      self:render_tree()
      self:titles()
    end
    if next_step then
      next_step()
    end
  end)
end

--- Show the listed commit at `index`. Files follows at once; the document is
--- replaced when that commit's comparison has loaded.
function Session:show_commit(index)
  local history = self.history
  local commit = history and history.commits[index]
  if not commit or self.closed then
    return
  end
  history.index = index
  -- A step queued behind a loading page belongs to an older choice; once the
  -- reviewer picks a commit directly, that page must not move them again.
  history.after = nil
  self.tree:select(function(entry)
    return entry.commit == commit
  end)
  -- Load unless this commit is already on its way, or on screen with nothing
  -- else pending (returning to it must still cancel another commit's load).
  if commit ~= history.loading and (commit ~= history.shown or history.loading) then
    self:load()
  end
end

-- Tab / S-Tab and ]C / [C in history: older (+1) or newer (-1). Stepping past
-- the last listed commit loads the next page first, so the walk never dead-ends.
function Session:step_commit(direction)
  local history = self.history
  local index = history.index + direction
  if index < 1 then
    notify("Already at the newest commit")
  elseif history.commits[index] then
    self:show_commit(index)
  elseif history.done then
    notify("Already at the oldest commit")
  else
    self:more_history(function()
      if history.commits[index] then
        self:show_commit(index)
      else
        notify("Already at the oldest commit")
      end
    end)
  end
end

function Session:load_more_commits()
  local history = self.history
  if history.done then
    notify(("All %d commits are listed"):format(#history.commits))
  elseif not history.busy then
    self:more_history()
  end
end

function Session:toggle_message()
  -- A commit without a body has nothing to hide; flipping the session-wide
  -- choice here would silently hide the next commit's message.
  if not self.history.shown or self.history.shown.body == "" then
    return
  end
  self.history.collapsed = not self.history.collapsed
  self:render({ kind = "commit" })
end

function Session:history_title()
  local paths = self.opts.paths or {}
  local root = self.snapshot and self.snapshot.root or self.opts.cwd or ""
  return "History · " .. (#paths > 0 and table.concat(paths, ", ") or vim.fs.basename(root))
end

function Session:render_tree()
  self.tree:update({
    files = self.files,
    groups = self:groups(),
    history = self.history,
    title = self.history and self:history_title() or nil,
    current_file = self.current_file,
    branch = self.opts.mode == "branch",
    message = self.error and "Git error" or self.snapshot and "No changes" or "Loading…",
  })
end

function Session:highlight_tree()
  self.tree:highlight(self.current_file)
end

function Session:current()
  local buf = api.nvim_get_current_buf()
  local binding = M.buffers[buf]
  if binding and binding.tree then
    local entry = self.tree.entries[api.nvim_win_get_cursor(0)[1]]
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
  local history = self.history
  local commit = history and history.commits[history.index]
  if history and not commit then
    -- The list comes first; its first page then loads the newest commit.
    self:more_history()
    return
  end
  -- Moving to another commit starts its document at the message, not at
  -- whatever source line happened to share a path with the previous commit.
  local new_commit = commit and commit ~= history.shown
  local anchor = not new_commit and self:anchor() or nil
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
  local load_options = vim.tbl_extend("force", {}, self.opts)
  if commit then
    -- Each history entry is an ordinary commit review: first parent → commit,
    -- limited to the listed paths (a followed rename carries both names).
    load_options.mode, load_options.rev = "commit", commit.oid
    load_options.paths = commit.paths or self.opts.paths
    history.loading = commit
  end
  -- Cached branch endpoints belong to a gm flip, never to a later refresh.
  self.opts._branch = nil
  self.error = nil
  local anchor_source
  self:request(function(done)
    local cancelled, cancel_load = false, nil
    local function load()
      if not cancelled then
        cancel_load = require("rill.git").load(load_options, done)
      end
    end
    local file = anchor and anchor.line and self.by_id[anchor.file_id]
    if file and self.snapshot and load_options.commits_view ~= self.snapshot.commits_view then
      -- Retain the old coordinate space before replacing its snapshot/object
      -- store. This reader shares the load generation and source-cache budgets.
      self:ensure_source(file, function(failure)
        if not failure then
          anchor_source = file[anchor.side == "old" and "old_source" or "new_source"]
        end
        load()
      end)
    else
      load()
    end
    return function()
      cancelled = true
      if cancel_load then
        cancel_load()
      end
    end
  end, function(err, snapshot)
    if self.closed or generation ~= self.generation then
      if snapshot and snapshot.dispose then
        snapshot.dispose()
      end
      return
    end
    if history then
      history.loading = nil
    end
    if err then
      self.error = tostring(err)
      if self.snapshot and self.snapshot.options and self.opts._base_source == "picked" then
        -- A ref can disappear while its picker is open. Keep the retained
        -- document's base authoritative so gr can recover without another pick.
        self.opts.base = self.snapshot.options.base
        self.opts._base_source = self.snapshot.options._base_source
      end
      if not self.snapshot then
        self:render()
      end
      notify(self.error, vim.log.levels.ERROR)
      return
    end
    -- The old document stays visible while Git loads, so viewport hydration
    -- may have started more readers. Stop them before releasing its objects.
    for _, cancel in pairs(self.jobs) do
      pcall(cancel)
    end
    self.jobs = {}
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
    local switching = self.snapshot and self.snapshot.commits_view ~= snapshot.commits_view
    if self.snapshot and self.snapshot ~= snapshot and self.snapshot.dispose then
      self.snapshot.dispose()
    end
    self.snapshot, self.files, self.by_id = snapshot, files, by_id
    if snapshot.commits then
      self.opts.commits = snapshot.commits
    end
    if snapshot.commits_view then
      self.opts.commits_view = snapshot.commits_view
    end
    if snapshot.combine_reason and self.last_combine_reason ~= snapshot.combine_reason then
      notify(snapshot.combine_reason .. " — showing each commit")
    end
    self.last_combine_reason = snapshot.combine_reason
    -- Combined IDs are paths; per-commit IDs include an OID. Across a switch,
    -- follow the same path (prefer its newest first-parent occurrence, not
    -- caller order), then let
    -- restore() use source coordinates rather than synthetic review row numbers.
    if switching and anchor and anchor.path then
      local match, newest_order
      for _, file in ipairs(files) do
        if file.meta.path == anchor.path then
          local group = file.meta.group and snapshot.groups[file.meta.group]
          local order = group and group.chain_order or math.huge
          if not match or order < newest_order then
            match, newest_order = file, order
          end
        end
      end
      if match then
        anchor.file_id, anchor.key = match.meta.id, nil
        if self.focus_id then
          self.focus_id = anchor.file_id
        end
      end
    end
    local empty_focus
    for _, group in ipairs(snapshot.groups or {}) do
      if self.focus_id == "group:" .. (group.oid or "worktree") then
        empty_focus = true
      end
    end
    if commit then
      history.shown = commit
    end
    if new_commit then
      -- Fold and focus choices name files of the previous commit. A focused
      -- reviewer keeps focus mode, starting at the new commit's first file.
      self.collapsed, self.stream_anchor = {}, nil
      -- The cursor opens on the message, which names no file; the previous
      -- commit's path must not stand in for this one's current file.
      self.current_file = files[1] and files[1].meta.id
      if self.fold_all then
        -- zA folded the walk down to file headers: each commit opens as its
        -- file list, and za opens just the files worth reading.
        for _, file in ipairs(files) do
          self.collapsed[file.meta.id] = true
        end
      end
      if self.focus_id then
        self.focus_id, self.pending_focus = nil, true
      end
    end
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
    elseif self.focus_id and not by_id[self.focus_id] and not empty_focus then
      -- The focused file left the comparison (committed, reverted, …). Focus
      -- whichever file now sits at its index rather than dropping the reviewer
      -- into the whole stream; only an empty comparison returns to it.
      local file = files[math.min(focus_index or 1, #files)]
      self.focus_id = file and file.meta.id
      target = file and { file_id = file.meta.id, kind = "file" } or anchor
    end
    if new_commit then
      -- Focus (above) picks the new commit's file; the cursor still opens on
      -- the message, in whichever pane the reviewer is reading.
      local side = self.layout == "split" and self.last_code_win == self.right_win and "new" or nil
      target = { kind = "commit", side = side }
    end
    self:render(target)
    for buf, binding in pairs(M.buffers) do
      if binding.session == self and api.nvim_buf_is_valid(buf) then
        self:comparison_keys(buf)
      end
    end
    -- The same path may have different source coordinates in each view: a
    -- clean merge can add upstream lines without contributing a file group.
    -- Translate from the retained old source, then reveal the mapped context.
    if switching and target and target.line and by_id[target.file_id] then
      local file = by_id[target.file_id]
      local function visible()
        for _, row in ipairs(self.rows) do
          local cell = target.side == "old" and row.old or row.new
          if row.file == file and cell and cell.line == target.line then
            return true
          end
        end
        return false
      end
      if anchor_source or not visible() then
        local projected = self:anchor()
        self:ensure_source(file, function(failure)
          -- Source reads are async. Navigation made while they run wins over
          -- this restoration; otherwise a delayed gm could pull the cursor back.
          local current = self:anchor()
          if
            failure
            or not projected
            or not current
            or current.file_id ~= projected.file_id
            or current.line ~= projected.line
            or current.kind ~= projected.kind
            or current.side ~= projected.side
          then
            return
          end
          if anchor_source then
            local after = file[target.side == "old" and "old_source" or "new_source"]
            target.line = require("rill.source").translate_line(anchor_source, after, target.line)
          end
          if not visible() then
            require("rill.model").expand_all(file)
          end
          self:render(target)
        end)
      end
    end
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

--- Change a branch comparison in place. Picker work belongs to this session,
--- independently of diff generations: gr may refresh beneath an open picker,
--- while a newer picker or close invalidates its eventual user decision.
function Session:select_base(rev)
  if self.closed then
    return
  end
  if self.opts.mode ~= "branch" then
    notify("Open a branch review to choose its base (:Rill branch)")
    return
  end
  if rev ~= nil and (type(rev) ~= "string" or rev == "") then
    error("Rill base must be a non-empty revision")
  end
  if self.base_cancel then
    self.base_cancel()
    self.base_cancel = nil
  end
  local picker = {}
  self.base_picker = picker
  local function active()
    return not self.closed
      and self.opts.mode == "branch"
      and M.sessions[self.tab] == self
      and self.base_picker == picker
  end
  local function choose(base)
    if not base or not active() then
      return
    end
    self.base_picker = nil
    -- Store the name, not today's OID, so refresh follows a later fetch. load()
    -- clears gm's cached endpoints and keeps layout, focus and path filters.
    self:load({ base = base, _base_source = "picked" })
  end
  if rev then
    choose(rev)
    return
  end
  local completed = false
  local cancel = require("rill.git").bases(
    vim.tbl_extend("force", self.opts, {
      cwd = self.snapshot and self.snapshot.root or self.opts.cwd,
      left = self.snapshot and self.snapshot.left,
      head = self.snapshot and self.snapshot.branch and self.snapshot.branch.right.head,
    }),
    function(err, items)
      completed = true
      if not active() then
        return
      end
      self.base_cancel = nil
      if err then
        notify(tostring(err), vim.log.levels.ERROR)
        return
      end
      if #items == 0 then
        notify("No other branches found; use :RillBase <revision>")
        return
      end
      vim.ui.select(items, {
        prompt = "Compare base:",
        kind = "rill_base",
        format_item = function(item)
          local hints = #item.hints > 0 and "  (" .. table.concat(item.hints, " · ") .. ")" or ""
          return item.label .. "  " .. (item.tip or ""):sub(1, 8) .. hints
        end,
      }, function(item)
        if item then
          choose(item.ref)
        elseif active() then
          self.base_picker = nil
        end
      end)
    end
  )
  if not completed then
    self.base_cancel = cancel
  end
end

-- View switches reuse the session's load generation and cancellation boundary;
-- there is never a second review owning windows, readers or source identities.
function Session:toggle_commits()
  if not self.snapshot or not self.snapshot.commits_view then
    return
  end
  if self.snapshot.commits_view == "commits" and not self.snapshot.combined then
    notify("Cannot combine: " .. (self.snapshot.combine_reason or "selection is not contiguous"))
    return
  end
  self:load({
    commits_view = self.snapshot.commits_view == "combined" and "commits" or "combined",
    _branch = self.snapshot.branch,
  })
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
  local anchor = self:anchor()
  if self.focus_id then
    self.focus_id = nil
    self:render(file and self.stream_anchor or anchor)
    self.stream_anchor = nil
  else
    -- Off a file (a history commit opens on its message), focus the review's
    -- current file, which a new commit sets to its first.
    file = file or self.by_id[self.current_file] or self.files[1]
    if not file then
      return
    end
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

-- Empty branch merges still convey useful history and are selectable in focus.
-- A synthetic focus identity lets the header survive layout changes and refresh.
function Session:jump_group(index)
  local group = (self:groups() or {})[index]
  if not group then
    return
  end
  if self.focus_id then
    self.focus_id = "group:" .. (group.oid or "worktree")
  end
  self.current_group = index
  self:render({ group = index, kind = "group" })
  api.nvim_set_current_win(self.main_win)
end

-- ]C / [C: the first file of the next / previous commit that has changes,
-- wrapping like Tab. Selections skip empty commits; branches retain merge markers.
function Session:move_commit(direction)
  local groups = self:groups()
  if not groups then
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
    local index = (current - 1 + direction * step) % #groups + 1
    local target = first[index]
    if target then
      self:jump_file(target)
      return
    elseif self.snapshot.branch then
      self:jump_group(index)
      return
    end
  end
end

function Session:cycle_file(direction)
  if #self.files == 0 then
    return
  end
  -- On a row without a file (a history message), step from the focused file.
  local current = self:current() or (self.focus_id and self.by_id[self.focus_id])
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
  if kind == "file" and self.focus_id then
    -- Focus draws one file, so there is no next file row to move to: switch
    -- the focused file instead. History needs this, as its Tab walks commits.
    self:cycle_file(direction)
    return
  end
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
  local file, row, entry = self:current()
  -- In the tree, za folds the node under the cursor: a commit or a directory.
  local key = entry and (entry.key or entry.directory)
  if key then
    self.tree:toggle(entry)
    return
  end
  if entry and entry.commit then
    -- Only the shown history commit has files to fold; za opens any other.
    self:show_commit(self:history_index(entry.commit))
    return
  end
  if self.history and not entry and row and (row.kind == "commit" or row.kind == "message") then
    self:toggle_message()
    return
  end
  if not file then
    return
  end
  self.collapsed[file.meta.id] = not self.collapsed[file.meta.id]
  self:render({ file_id = file.meta.id, kind = "file" })
end

-- zA: fold every file body to its header, or open them all when every file is
-- already folded, so a large comparison reads as a file list opened file by
-- file with za. A history walk keeps the choice for the commits it reaches.
function Session:toggle_all_files()
  local open = false
  for _, file in ipairs(self.files) do
    if not self.collapsed[file.meta.id] then
      open = true
      break
    end
  end
  local anchor = self:anchor()
  self.fold_all, self.collapsed = open, {}
  if open then
    for _, file in ipairs(self.files) do
      self.collapsed[file.meta.id] = true
    end
  end
  -- A folded file's code rows vanish; keep the cursor on that file's header.
  if anchor and anchor.file_id and open then
    anchor = { file_id = anchor.file_id, kind = "file" }
  end
  self:render(anchor)
end

function Session:toggle_tree()
  if self.tree:is_open() then
    self.tree:close()
  else
    self.tree:open(self.main_win)
    self:render_tree()
  end
end

function Session:open_source()
  local file, row, entry = self:current()
  if entry and entry.directory then
    self.tree:toggle(entry)
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
      -- Splitting the current buffer creates no empty buffer. Then install the
      -- source explicitly: :tab sbuffer honors switchbuf and could jump back
      -- into a sidebar/preview window that the destination checks rejected.
      vim.cmd("tab split")
      api.nvim_win_set_buf(0, buf)
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
    "zA        collapse / expand every file (a file list to open with za)",
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
  if self.snapshot and self.snapshot.commits_view then
    table.insert(lines, 6, "gm        combined / per commit (gaps stay per commit)")
  end
  if self.snapshot and self.snapshot.branch then
    table.insert(lines, 6, "gb        choose comparison base")
    table.insert(lines, #lines - 2, "Branch: first-parent commits, then Uncommitted changes (when dirty).")
    table.insert(
      lines,
      #lines - 2,
      "Merges: resolutions/edits beyond Git's automatic merge; clean merges are empty."
    )
    table.insert(lines, #lines - 2, "Octopus/old Git: first-parent diff, labelled in the group header.")
  end
  if commits then
    -- Right after the "[c / ]c" hunk line.
    table.insert(lines, 8, "[C / ]C   previous / next commit")
  end
  if self.history then
    lines[1] = "Rill · Git history"
    lines[3] = "Tab / S-Tab  older / newer commit (Tab past the last loads more)"
    table.insert(lines, 4, "]C / [C   older / newer commit")
    table.insert(lines, 5, ("C-e       load %d more commits"):format(self.history.count))
    table.insert(lines, 6, "za        on the message: hide / show commit bodies")
    table.insert(lines, #lines - 2, "Each commit is its first-parent change, limited to the history's paths.")
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

-- Comparison-specific keys follow the loaded mode. In particular gb remains
-- available in an empty branch review, and gm cannot leave stale commit jumps.
function Session:comparison_keys(buf)
  if self.opts.mode == "branch" then
    vim.keymap.set("n", "gb", function()
      self:select_base()
    end, { buffer = buf, silent = true, desc = "Rill: choose comparison base" })
  else
    pcall(vim.keymap.del, "n", "gb", { buffer = buf })
  end
  for key, direction in pairs({ ["]C"] = 1, ["[C"] = -1 }) do
    if self.history then
      vim.keymap.set("n", key, function()
        self:step_commit(direction)
      end, { buffer = buf, silent = true, desc = "Rill: older / newer commit" })
    elseif self:groups() then
      vim.keymap.set("n", key, function()
        self:move_commit(direction)
      end, { buffer = buf, silent = true, desc = "Rill: move commit" })
    else
      pcall(vim.keymap.del, "n", key, { buffer = buf })
    end
  end
end

function Session:keys(buf)
  local actions = {
    ["q"] = {
      "Close review",
      function()
        self:close()
      end,
    },
    -- History walks commits with Tab; ]f / [f still move between its files.
    ["<Tab>"] = {
      self.history and "Older commit" or "Next file",
      function()
        if self.history then
          self:step_commit(1)
        else
          self:cycle_file(1)
        end
      end,
    },
    ["<S-Tab>"] = {
      self.history and "Newer commit" or "Previous file",
      function()
        if self.history then
          self:step_commit(-1)
        else
          self:cycle_file(-1)
        end
      end,
    },
    ["gs"] = {
      "Toggle unified / split",
      function()
        self:toggle_layout()
      end,
    },
    ["gm"] = {
      "Toggle combined / per commit",
      function()
        self:toggle_commits()
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
    ["zA"] = {
      "Collapse / expand every file",
      function()
        self:toggle_all_files()
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
  if self.history then
    -- The commit pickers' paging key. In a history review it outranks
    -- scrolling one line, which j/k and Ctrl-d already cover.
    actions["<C-e>"] = {
      "Load more commits",
      function()
        self:load_more_commits()
      end,
    }
  end
  for key, action in pairs(actions) do
    vim.keymap.set("n", key, action[2], { buffer = buf, silent = true, desc = "Rill: " .. action[1] })
  end
  self:comparison_keys(buf)
  if self.opts.sidekick ~= false then
    require("rill.sidekick").attach(buf)
  end
end

function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  if self.base_cancel then
    self.base_cancel()
    self.base_cancel = nil
  end
  if self.history and self.history.cancel then
    self.history.cancel()
    self.history.cancel = nil
  end
  self.base_picker = nil
  self.generation = self.generation + 1
  for _, cancel in pairs(self.jobs) do
    pcall(cancel)
  end
  self.jobs = {}
  for _, file in ipairs(self.files) do
    require("rill.highlight").dispose(file)
  end
  if self.snapshot and self.snapshot.dispose then
    self.snapshot.dispose()
  end
  M.sessions[self.tab] = nil
  self.tree:dispose()
  -- Close only this session's windows; user buffers and the originating tab are
  -- not ours to delete. TabClosed may re-enter close, hence closed is set first.
  if api.nvim_tabpage_is_valid(self.tab) then
    if #api.nvim_list_tabpages() > 1 then
      api.nvim_set_current_tabpage(self.tab)
      vim.cmd("tabclose")
    else
      for _, win in ipairs({ self.right_win }) do
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
    generation = 0,
    cache = cache,
    -- History sessions page through `git log` and show one commit at a time:
    -- `commits` is every listed commit (newest first), `index` the one asked
    -- for, `shown` the commit whose comparison is on screen (it trails `index`
    -- while that commit's diff loads). Other modes leave this nil.
    history = opts.mode == "history" and {
      commits = {},
      index = 1,
      count = opts.count or 20,
      done = false,
      busy = false,
      collapsed = false,
    } or nil,
  }, Session)
  -- The panel owns its buffer/window lifecycle. The session registry only
  -- binds its rows to review identities for navigation and Sidekick capture.
  self.tree = require("rill.tree").new({
    id = self.id,
    initial_width = opts.tree_width,
    options = opts.tree,
    attach = function(buf)
      M.buffers[buf] = { session = self, tree = true }
      self:keys(buf)
    end,
    detach = function(buf)
      M.buffers[buf] = nil
    end,
    on_select = function(entry)
      if entry.more then
        self:load_more_commits()
      elseif entry.commit and entry.commit == self.history.shown and not self.history.loading then
        -- The shown commit: read its message at the top of the document.
        self:render({ kind = "commit" })
        api.nvim_set_current_win(self.main_win)
      elseif entry.commit then
        self:show_commit(self:history_index(entry.commit))
      elseif entry.file then
        self:jump_file(entry.file)
      elseif entry.group and self.snapshot and self.snapshot.branch then
        self:jump_group(entry.group)
      end
    end,
    -- za folds file bodies as well as tree nodes; keep the session's existing
    -- action, which delegates keyed directory/commit entries back to the panel.
    on_toggle = function()
      self:toggle_file()
    end,
  })
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
-- The tree resolves its own row identities to references, without source spans.
function M.context(ctx)
  local binding = M.buffers[ctx.buf]
  if not binding or binding.session.closed then
    return
  end
  local session = binding.session
  if not session.snapshot then
    return
  end
  if binding.tree then
    return session.tree:context(ctx, session.snapshot)
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
