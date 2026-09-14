--- Owns read-only historical source buffers independently of review sessions.
--- A snapshot remains addressable after its review closes; only wiping that
--- buffer releases its path/revision metadata and local integration mappings.
local M = {}
local addresses = {}
local serial = 0

local function uri_label(text)
  return (text:gsub("[^%w%-%._~/]", function(character)
    return ("%%%02X"):format(character:byte())
  end))
end

---@param content {lines: string[], text?: string, eol?: boolean, crlf?: boolean}
---@param address {root: string, path: string, side: string, revision: string, name?: string}
---@param opts? {sidekick?: boolean}
---@return integer buf
function M.create(content, address, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(true, true)
  serial = serial + 1
  vim.api.nvim_buf_set_name(
    buf,
    ("rill-source://%d/%s/%s"):format(serial, address.side, uri_label(address.name or address.path))
  )
  local lines = {}
  for i, line in ipairs(content.lines) do
    lines[i] = line:gsub("\r$", "")
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  local crlf = content.crlf
  if crlf == nil then
    crlf = content.text and content.text:find("\r\n", 1, true) ~= nil
  end
  vim.bo[buf].fileformat = crlf and "dos" or "unix"
  local eol = content.eol
  if eol == nil then
    eol = content.text and content.text:sub(-1) == "\n"
  end
  vim.bo[buf].endofline = eol == true
  vim.bo[buf].fixendofline = false
  vim.bo[buf].filetype = vim.filetype.match({ filename = address.path, buf = buf }) or ""
  vim.bo[buf].modified = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false

  local stored = vim.deepcopy(address)
  stored.absolute_path = vim.fs.joinpath(stored.root, stored.path)
  stored.line_count = #lines
  addresses[buf] = stored
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      addresses[buf] = nil
    end,
  })
  if opts.sidekick ~= false then
    require("rill.sidekick").attach(buf)
  end
  return buf
end

---@param ctx table Captured source-buffer position or selection.
---@return table? context Same public source-span contract as rill.context().
function M.context(ctx)
  local address = addresses[ctx.buf]
  if not address or not vim.api.nvim_buf_is_valid(ctx.buf) then
    return
  end
  local result = {
    root = address.root,
    file = { path = address.path, absolute_path = address.absolute_path },
    spans = {},
  }
  local selected = require("rill.selection").rows(ctx)
  local rows = vim.tbl_keys(selected)
  table.sort(rows)
  local span
  for _, row in ipairs(rows) do
    -- Neovim gives an empty buffer one display row. An empty Git source has no
    -- source line 1, so it can provide a file reference but no invented span.
    if row <= address.line_count then
      local value = selected[row]
      if not span or span.end_line + 1 ~= row or span.partial or value.partial then
        span = {
          path = address.path,
          absolute_path = address.absolute_path,
          side = address.side,
          revision = address.revision,
          start_line = row,
          end_line = row,
          start_col = value.start_col,
          end_col = value.end_col,
          lines = {},
          partial = value.partial,
        }
        result.spans[#result.spans + 1] = span
      end
      span.lines[#span.lines + 1] = value.text
      span.end_line, span.end_col = row, value.end_col
    end
  end
  return result
end

return M
