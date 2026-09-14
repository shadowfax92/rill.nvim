--- Bridges source-addressed Rill selections to Sidekick's existing message flow.
--- Context is captured before opening a comment popup, so refreshes and window
--- changes cannot alter the code or revision attached to an in-progress comment.
local M = {}

local function path_for(context, entry, absolute)
  if absolute then
    return entry.absolute_path or (context.root .. "/" .. entry.path)
  end
  return entry.path
end

local function reference(path)
  -- Git allows whitespace and control characters in filenames. Keep a filename
  -- on one reference line, and make its exact spelling recoverable by the agent.
  if path:find('[%s"`\\%c]') then
    path = vim.json.encode(path)
  end
  return "@" .. path
end

local function fence(lines)
  local longest = 2
  for _, line in ipairs(lines) do
    for run in line:gmatch("`+") do
      longest = math.max(longest, #run)
    end
  end
  return string.rep("`", longest + 1)
end

---@param context table? Rill source context, never review-buffer coordinates.
---@param opts? {absolute?: boolean, kind?: 'line'|'file'}
---@return string
function M.format(context, opts)
  opts = opts or {}
  if not context then
    return ""
  end

  local result = {}
  if opts.kind == "file" then
    local seen = {}
    local entries = context.spans or {}
    if #entries == 0 and context.file then
      entries = { context.file }
    end
    for _, entry in ipairs(entries) do
      local path = path_for(context, entry, opts.absolute)
      if path and not seen[path] then
        seen[path] = true
        result[#result + 1] = reference(path)
      end
    end
    return table.concat(result, "\n")
  end

  for _, span in ipairs(context.spans or {}) do
    local location = reference(path_for(context, span, opts.absolute)) .. " :L" .. span.start_line
    if span.end_line ~= span.start_line then
      location = location .. "-L" .. span.end_line
    end
    -- Both sides can be historical (branch/range/commit review). An old-side
    -- location must never masquerade as a line in the current working file.
    local revision = tostring(span.revision or "unknown revision"):gsub("[%c]", " ")
    location = location .. " (" .. span.side .. ", " .. revision .. ")"
    local boundary = fence(span.lines)
    result[#result + 1] = location
      .. "\n"
      .. boundary
      .. "\n"
      .. table.concat(span.lines, "\n")
      .. "\n"
      .. boundary
  end
  return table.concat(result, "\n\n")
end

local function warn(message)
  vim.notify("Rill: " .. message, vim.log.levels.WARN)
end

---@param opts? {comment?: boolean, absolute?: boolean, kind?: 'line'|'file', filter?: table, focus?: boolean}
---@return boolean sent Whether Sidekick accepted the context for sending/commenting.
function M.send(opts)
  opts = opts or {}
  -- Optional integration: attaching mappings must neither require Sidekick nor
  -- trigger its agent discovery. Lazy plugin managers load it on invocation.
  local ok, cli = pcall(require, "sidekick.cli")
  if not ok then
    warn("Sidekick is unavailable; install/configure sidekick.nvim to send review context.")
    return false
  end
  local action = opts.comment and cli.send_with_comment or cli.send
  if type(action) ~= "function" then
    warn("this Sidekick installation does not support comments.")
    return false
  end

  local captured = require("sidekick.cli.context").ctx()
  local context = require("rill").context(captured)
  local formatted = M.format(context, opts)
  if formatted == "" then
    warn("select source code to send, or use Send File on a file header.")
    return false
  end

  local tokens = require("sidekick.config").cli.context
  local previous = tokens.rill_review
  tokens.rill_review = function()
    return formatted
  end

  -- Sidekick renders templates synchronously, before any popup or agent picker.
  -- opts.text alone bypasses its preview/draft context, so use a temporary token
  -- and restore it immediately; asynchronous delivery owns the rendered snapshot.
  local sent, err = pcall(action, {
    msg = "{rill_review}",
    filter = opts.filter,
    focus = opts.focus,
  })
  tokens.rill_review = previous
  if not sent then
    warn("Sidekick could not open the review context: " .. tostring(err))
  end
  return sent
end

---@param buf integer
function M.attach(buf)
  local bindings = {
    { "ai", { comment = true }, "Send with Comment" },
    { "aI", { comment = true, absolute = true }, "Send with Comment (abs path)" },
    { "av", { filter = { name = "claude" }, focus = false }, "Send line to Claude" },
    { "ax", { filter = { name = "codex" }, focus = false }, "Send line to Codex" },
    { "at", {}, "Send This", { "n", "x" } },
    { "af", { kind = "file" }, "Send File" },
    { "aF", { kind = "file", absolute = true }, "Send File (abs path)" },
    { "al", {}, "Send Line" },
    { "aL", { absolute = true }, "Send Line (abs path)" },
  }
  for _, binding in ipairs(bindings) do
    local options = binding[2]
    vim.keymap.set(binding[4] or { "n", "v" }, "<leader>" .. binding[1], function()
      M.send(options)
    end, { buffer = buf, silent = true, desc = "Rill: " .. binding[3] })
  end
end

return M
