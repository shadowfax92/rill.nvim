--- Resolves captured Neovim selections into exact text and touched byte ranges.
--- Neovim owns visual-cell rules: a rectangular selection may include only part
--- of a tab or wide character, represented as spaces rather than source bytes.
local M = {}

---@param ctx table Captured {buf,win,row,col,range}; see rill-context.
---@return table<integer, {start_col: integer, end_col: integer, text: string, partial: boolean}>
function M.rows(ctx)
  local buf = ctx.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return {}
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if not ctx.range then
    local row = ctx.row or 1
    if row < 1 or row > count then
      return {}
    end
    local text = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    return { [row] = { start_col = 0, end_col = #text, text = text, partial = false } }
  end

  local range = ctx.range
  local function position(value)
    -- Linewise Visual marks use MAXCOL already; adding one would overflow
    -- getregion's column sentinel and make an otherwise valid selection empty.
    local column = math.max(1, math.min(vim.v.maxcol, value[2] + 1))
    local row = math.max(1, math.min(count, value[1]))
    local text = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    if range.kind == "line" then
      column = 1
    elseif column ~= vim.v.maxcol then
      column = math.min(column, #text + 1)
    end
    return { buf, row, column, value[3] or 0 }
  end
  local from, to = position(range.from), position(range.to)
  local kind = range.kind == "line" and "V" or range.kind == "block" and "\22" or "v"
  local function read()
    local options = { type = kind, exclusive = false }
    local text = vim.fn.getregion(from, to, options)
    options.eol = true
    local positions = vim.fn.getregionpos(from, to, options)
    local rows = {}
    for i, pair in ipairs(positions) do
      local row = pair[1][2]
      local source = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
      -- getregionpos includes the final character's bytes, including composing
      -- marks. Its 1-based inclusive end is already our 0-based exclusive end.
      -- Partial visual cells still address their whole underlying source byte.
      local first = math.max(0, math.min(#source, pair[1][3] - 1))
      local last = math.max(first, math.min(#source, pair[2][3]))
      rows[row] = {
        start_col = first,
        end_col = last,
        text = text[i] or "",
        partial = kind == "\22" or first > 0 or last < #source or text[i] ~= source,
      }
    end
    return rows
  end

  -- getregion uses the current window's tab/virtualedit/list options even when
  -- reading another buffer. Re-enter the captured window without moving focus
  -- permanently; a hidden source buffer uses its own temporary buffer context.
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_win_get_buf(ctx.win) == buf then
    return vim.api.nvim_win_call(ctx.win, read)
  end
  return vim.api.nvim_buf_call(buf, read)
end

return M
