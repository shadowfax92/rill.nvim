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

-- Position changes when commits arrive or gm rebuilds the groups. Fold state
-- belongs to the commit itself, including the synthetic worktree marker.
local function group_key(index, group)
  return "@" .. (group.oid or (group.kind == "uncommitted" and "worktree") or group.short or tostring(index))
end

-- Fold keys include the commit group, so repeated paths in a multi-commit
-- review remain independent. Compact directory chains leave room for filenames.
-- A history review lists every loaded commit as one row and nests files only
-- under the commit on screen (`owner`), keyed by its OID like a group.
local function entries(data, folded)
  local files, groups, history = data.files or {}, data.groups, data.history
  local shown = history and history.shown
  local roots = {}
  for i = 1, groups and #groups or 1 do
    local key = groups and group_key(i, groups[i]) or shown and ("@" .. shown.oid) or ""
    roots[i] = { children = {}, order = {}, key = key }
  end
  for _, file in ipairs(files) do
    local group = groups and file.meta.group or 1
    local node, path, relative = roots[group], roots[group] and roots[group].key or "", ""
    if node then
      node.first = node.first or file
      local parts = vim.split(file.meta.path, "/", { plain = true })
      for i, name in ipairs(parts) do
        path = path == "" and name or path .. "/" .. name
        relative = relative == "" and name or relative .. "/" .. name
        if not node.children[name] then
          node.children[name] = {
            name = name,
            path = path,
            relative = relative,
            group_index = groups and group or nil,
            owner = shown,
            children = {},
            order = {},
          }
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
      local entry = {
        label = escape(label),
        prefix = prefix,
        parent = parent,
        group_index = child.group_index,
        owner = child.owner,
      }
      if child.file then
        entry.file = child.file
      else
        entry.directory, entry.key = child.relative, child.path
      end
      result[#result + 1] = entry
      if not child.file and not folded[child.path] then
        visit(child, indent .. (last and "   " or "│  "), child.path)
      end
    end
  end
  if history then
    for _, commit in ipairs(history.commits) do
      local entry = { commit = commit, prefix = "", label = escape(commit.short .. " " .. commit.subject) }
      result[#result + 1] = entry
      if commit == shown then
        entry.key = roots[1].key
        if not folded[entry.key] then
          if #roots[1].order == 0 then
            result[#result + 1] =
              { placeholder = true, prefix = "  ", label = "(no changes)", parent = entry.key }
          end
          visit(roots[1], "  ", entry.key)
        end
      end
    end
    if #history.commits > 0 then
      local label = history.busy and "Loading more commits…"
        or history.done and ("All " .. #history.commits .. " commits listed")
        or ("C-e / Enter: " .. history.count .. " more")
      result[#result + 1] = { more = true, prefix = "", label = label }
    end
  elseif groups then
    for index, group in ipairs(groups) do
      local key, root = roots[index].key, roots[index]
      result[#result + 1] = {
        group = index,
        key = key,
        file = root.first,
        prefix = "",
        label = escape(
          require("rill.group").label(index, require("rill.group").commit_count(groups), group, "tree")
        ),
      }
      if not folded[key] then
        if #root.order == 0 and not group.auto_merge then
          result[#result + 1] = {
            placeholder = true,
            prefix = "  ",
            label = "(" .. (group.note or "no changes") .. ")",
            parent = key,
          }
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

function Tree:limits(manual)
  -- Content fitting must not let a long subject take over the review. An
  -- intentional resize can exceed that cap while leaving 40 columns for code.
  local maximum = math.max(1, vim.o.columns - 41)
  if not manual then
    maximum = math.max(
      1,
      math.min(
        maximum,
        math.floor(self.options.max_width),
        math.floor(vim.o.columns * self.options.max_ratio)
      )
    )
  end
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
    winbar = "%#RillHeader# " .. (self.title or "Files"):gsub("%%", "%%%%"),
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
      "Toggle directory / commit / file body",
      function()
        if self.on_toggle then
          self.on_toggle(self:selected())
        else
          self:toggle()
        end
      end,
    },
    zA = {
      "Toggle all tree folds",
      function()
        self:fold("toggle", "all")
      end,
    },
    zM = {
      "Collapse all tree nodes",
      function()
        self:fold("close", "all")
      end,
    },
    zR = {
      "Expand all tree nodes",
      function()
        self:fold("open", "all")
      end,
    },
    zo = {
      "Open tree node",
      function()
        self:fold("open", "node")
      end,
    },
    zc = {
      "Close tree node",
      function()
        self:fold("close", "node")
      end,
    },
    zO = {
      "Open tree subtree",
      function()
        self:fold("open", "subtree")
      end,
    },
    zC = {
      "Close tree subtree",
      function()
        self:fold("close", "subtree")
      end,
    },
    zB = { "No diff context action in Files", function() end },
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
    ["}"] = {
      "Widen Files panel",
      function()
        self:resize(self.options.resize_step)
      end,
    },
    ["{"] = {
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
  local low, high = self:limits(preferred_width ~= nil)
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
    local tab = api.nvim_win_get_tabpage(self.win)
    local ordinary = vim.tbl_filter(function(win)
      return api.nvim_win_get_config(win).relative == ""
    end, api.nvim_tabpage_list_wins(tab))
    if #api.nvim_list_tabpages() == 1 and #ordinary == 1 then
      -- :only/:tabonly can remove the document before scheduled session
      -- cleanup runs. Neovim requires one ordinary window; hand it back to
      -- editing before deleting the panel, including its window-only size lock.
      api.nvim_win_set_buf(self.win, api.nvim_create_buf(true, false))
      api.nvim_set_option_value("winfixwidth", false, { win = self.win, scope = "local" })
    else
      api.nvim_win_close(self.win, true)
    end
  end
  self.win = nil
end

function Tree:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  -- A third-party window-close hook must not prevent registry, augroup and
  -- scratch-buffer cleanup. The session may already be marked closed.
  local closed, close_error = pcall(self.close, self)
  if valid(self.help_win) then
    api.nvim_win_close(self.help_win, true)
  end
  api.nvim_del_augroup_by_id(self.augroup)
  if self.buf then
    if self.detach then
      self.detach(self.buf)
    end
    if api.nvim_buf_is_valid(self.buf) then
      pcall(api.nvim_buf_delete, self.buf, { force = true })
    end
  end
  if not closed then
    vim.notify("Rill Files cleanup: " .. tostring(close_error), vim.log.levels.WARN)
  end
end

function Tree:resize(delta)
  if not self:is_open() then
    return
  end
  local low, high = self:limits(true)
  local actual = api.nvim_win_get_width(self.win)
  local width = math.max(low, math.min(high, actual + math.floor(delta)))
  if width == actual then
    return
  end
  preferred_width = width
  self:render()
end

function Tree:update(data)
  -- Walking history moves the open commit. Its files stay folded or open as
  -- the reviewer left the previous commit's, so one za holds for the walk.
  local shown = data.history and data.history.shown
  if shown and self.shown and shown ~= self.shown then
    self.folded["@" .. shown.oid] = self.folded["@" .. self.shown.oid]
  end
  self.shown = shown
  self.data = data
  self.current_file = data.current_file
  if data.title ~= self.title then
    self.title = data.title
    self:options_local()
  end
  self:render()
end

--- Move the cursor to the first row `match(entry)` accepts, if it is drawn.
function Tree:select(match)
  if not self:is_open() then
    return
  end
  for index, entry in ipairs(self.entries) do
    if match(entry) then
      api.nvim_win_set_cursor(self.win, { index, 0 })
      return
    end
  end
end

function Tree:render()
  if not self:is_open() or self.rendering then
    return
  end
  self.rendering = true
  self:capture_width()
  local prior = self.entries[api.nvim_win_get_cursor(self.win)[1]]
  local parents = {}
  for _, entry in ipairs(self.entries) do
    if entry.key then
      parents[entry.key] = entry.parent
    end
  end
  self.entries = entries(self.data, self.folded)
  local natural = self.initial_width
  for _, entry in ipairs(self.entries) do
    if entry.group or entry.directory then
      entry.symbol, entry.hl = self.folded[entry.key] and "▸" or "▾", "Directory"
      entry.suffix = entry.directory and "/" or ""
    elseif entry.commit then
      -- Only the shown commit has a key (and files); the rest open on Enter.
      entry.symbol, entry.hl = entry.key and not self.folded[entry.key] and "▾" or "▸", "Directory"
    elseif entry.more then
      entry.symbol, entry.hl = "↓", "RillMuted"
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
  local low, high = self:limits(preferred_width ~= nil)
  local width = math.max(
    low,
    math.min(high, preferred_width or (self.options.adaptive and natural or self.initial_width))
  )
  if api.nvim_win_get_width(self.win) ~= width then
    api.nvim_win_set_width(self.win, width)
  end
  self.width, self.columns = api.nvim_win_get_width(self.win), vim.o.columns
  local lines, cursor, by_key = {}, nil, {}
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
    -- Commit subjects keep their start; paths keep their filename end.
    lines[index] = prefix .. fit(label, room, not (entry.group or entry.commit or entry.more))
    if entry.key then
      by_key[entry.key] = index
    end
    if
      prior
      and (
        (entry.key and prior.key == entry.key)
        -- History rows keep identity as the shown commit (and its key) moves.
        or (prior.commit and entry.commit == prior.commit)
        or (prior.more and entry.more)
        or (
          not prior.key
          and not entry.group
          and entry.file
          and prior.file
          and prior.file.meta.id == entry.file.meta.id
        )
      )
    then
      cursor = index
    end
  end
  -- A collapsed ancestor removes the old row. Follow its identity through the
  -- previous parent chain instead of selecting an unrelated row at that number.
  local parent = prior and prior.parent
  while not cursor and parent do
    cursor, parent = by_key[parent], parents[parent]
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
  local ancestors = {}
  local shown = self.data.history and self.data.history.shown
  for _, file in ipairs(self.data.files or {}) do
    if file.meta.id == self.current_file then
      local group = self.data.groups and self.data.groups[file.meta.group]
      local key = group and group_key(file.meta.group, group) or shown and ("@" .. shown.oid) or ""
      if key ~= "" then
        ancestors[key] = true
      end
      local parts = vim.split(file.meta.path, "/", { plain = true })
      for i = 1, #parts - 1 do
        key = key == "" and parts[i] or key .. "/" .. parts[i]
        ancestors[key] = true
      end
      break
    end
  end
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
    if entry.commit then
      span(#entry.paint_indent + #entry.symbol + 1, #entry.commit.short, "RillMuted")
    elseif entry.more then
      span(0, #line, "RillMuted")
    end
    -- File navigation respects explicit tree folds. Highlight the closed
    -- ancestor that contains the review's current file instead of reopening it.
    local selected = not entry.group and entry.file and entry.file.meta.id == self.current_file
      or entry.key and self.folded[entry.key] and ancestors[entry.key]
    -- In history only the shown commit carries a key; it reads as the open group.
    local hl = selected and "RillTreeCurrent" or (entry.group or entry.commit and entry.key) and "RillGroup"
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
  elseif entry and (entry.file or entry.group or entry.commit or entry.more) and self.on_select then
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

--- Apply fold operations to the tree projection, independently of diff bodies
--- and source expansion. Enumerating the fully open projection preserves merged
--- directory chains and includes descendants hidden by an already closed node.
function Tree:fold(action, scope)
  local node = self:selected()
  if scope ~= "all" and (not node or not node.key) then
    return
  end
  local complete = entries(self.data, {})
  local close = action == "close"
  if action == "toggle" then
    -- Hidden descendants do not make a visibly closed tree open. Direction
    -- follows the current projection; application still covers every node.
    for _, entry in ipairs(self.entries) do
      if entry.key and not self.folded[entry.key] then
        close = true
        break
      end
    end
  end
  if scope == "all" then
    self.folded = {}
  else
    self.folded[node.key] = close or nil
  end
  for _, entry in ipairs(complete) do
    if
      entry.key
      and (
        scope == "all"
        or entry.key == node.key
        or scope == "subtree" and entry.key:sub(1, #node.key + 1) == node.key .. "/"
      )
    then
      self.folded[entry.key] = close or nil
    end
  end
  self:render()
end

--- Snapshot selected tree identities while their row mapping is current. Visual
--- columns may cover part of a decorated/truncated label; they still identify
--- whole entries, never source lines or an instruction to traverse directories.
function Tree:context(ctx, snapshot)
  local first = ctx.range and math.min(ctx.range.from[1], ctx.range.to[1]) or ctx.row or 1
  local last = ctx.range and math.max(ctx.range.from[1], ctx.range.to[1]) or first
  local result = { root = snapshot.root, label = snapshot.label, entries = {}, spans = {} }
  local seen, selected_file = {}, nil
  for row = math.max(1, first), math.min(#self.entries, last) do
    local entry = self.entries[row]
    -- History rows name their commit directly; groups resolve by position.
    local group = entry.commit
      or entry.owner
      or snapshot.groups and snapshot.groups[entry.group or entry.group_index]
    local revision = group and (group.kind == "uncommitted" and "worktree" or group.oid or group.short)
    local item
    if entry.group or entry.commit then
      item = {
        kind = group.kind == "uncommitted" and "uncommitted" or "commit",
        revision = revision,
        subject = group.subject,
      }
    elseif entry.directory then
      item = { kind = "directory", path = entry.directory, revision = revision }
    elseif entry.file then
      local meta = entry.file.meta
      item = {
        kind = "file",
        path = meta.path,
        old_path = meta.old_path,
        status = meta.status,
        revision = revision,
      }
    end
    if item then
      if item.path then
        item.absolute_path = snapshot.root .. "/" .. item.path
      end
      local identity = table.concat({ item.kind, item.path or "", item.revision or "" }, "\0")
      if not seen[identity] then
        seen[identity] = true
        result.entries[#result.entries + 1] = item
        selected_file = entry.file and entry.file.meta or nil
      end
    end
  end
  if #result.entries == 0 then
    return
  end
  if #result.entries == 1 then
    if result.entries[1].kind == "file" then
      result.file = selected_file
    elseif result.entries[1].kind == "directory" then
      result.directory = result.entries[1]
    end
  end
  return result
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
    "za             Toggle directory / commit / file body",
    "zA             Toggle all tree folds",
    "zM / zR        Collapse / expand all tree nodes",
    "zo / zc        Open / close the current tree node",
    "zO / zC        Open / close its whole subtree",
    "} / {, > / <   Widen / narrow (session-persistent)",
    "Ctrl-w < / >   Native resize; separator drag also works",
    "q              Close Files panel",
    "gT             Reopen Files panel",
    "",
    "Rill: gm combined / per commit, gs layout, gf focus, gr refresh",
    "Sidekick: select files/folders/commits; <leader>ai asks about them",
    "",
    "q / Escape     Close help",
  }
  if self.data.branch then
    table.insert(lines, #lines - 1, "gb             Choose comparison base")
  end
  if self.data.history then
    lines[1] = "History"
    lines[3] = "Enter / o / l  Show commit · open file · expand directory"
    table.insert(lines, 4, "Tab / S-Tab    Older / newer commit")
    table.insert(lines, 5, "C-e            Load more commits (also Enter on the last row)")
    for index, line in ipairs(lines) do
      if vim.startswith(line, "Rill:") then
        lines[index] = "Rill: gs layout, gf focus, gr reload commit, za on message hides bodies"
      end
    end
  end
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
    on_toggle = opts.on_toggle,
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
