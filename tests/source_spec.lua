local H = require("tests.helpers")
local Source = require("rill.source")

local function with_source(lines, callback, opts)
  local original = vim.api.nvim_get_current_buf()
  local address = { root = "/repo", path = "src/old name.lua", side = "old", revision = "abc123" }
  local content = { lines = lines, text = table.concat(lines, "\n"), eol = false }
  local buf = Source.create(content, address, opts or { sidekick = false })
  vim.api.nvim_set_current_buf(buf)
  local ok, err = xpcall(function()
    callback(buf, address, content)
  end, debug.traceback)
  if vim.api.nvim_buf_is_valid(original) then
    vim.api.nvim_set_current_buf(original)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then
    error(err)
  end
end

local function selected(buf, from, to, kind)
  return Source.context({
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    row = from[1],
    col = from[2] + 1,
    range = { from = from, to = to, kind = kind },
  })
end

return {
  source_buffers_retain_exact_address_and_optional_mappings_without_loading_sidekick = function()
    local loaded = package.loaded["sidekick.cli"]
    with_source({ "local old = true", "return old" }, function(buf, address, content)
      H.eq(true, vim.bo[buf].buflisted)
      H.eq("nofile", vim.bo[buf].buftype)
      H.eq("wipe", vim.bo[buf].bufhidden)
      H.eq(false, vim.bo[buf].modifiable)
      H.eq(true, vim.bo[buf].readonly)
      H.eq("lua", vim.bo[buf].filetype)
      H.eq(9, #vim.api.nvim_buf_get_keymap(buf, "n"))
      H.eq(loaded, package.loaded["sidekick.cli"])
      H.ok(vim.api.nvim_buf_get_name(buf):match("^rill%-source://"))
      H.ok(vim.api.nvim_buf_get_name(buf):find("old%20name.lua", 1, true))
      address.path, address.revision = "mutated.lua", "changed"
      content.lines[2] = "changed after opening"
      local context = Source.context({ buf = buf, row = 2, col = 1 })
      H.eq("src/old name.lua", context.file.path)
      local span = context.spans[1]
      H.eq("/repo/src/old name.lua", span.absolute_path)
      H.eq("abc123", span.revision)
      H.eq("old", span.side)
      H.eq(2, span.start_line)
      H.eq({ "return old" }, span.lines)
      H.ok(require("rill.sidekick").format(context):find(":L2 (old, abc123)", 1, true))
    end, { sidekick = true })
  end,

  line_and_character_ranges_preserve_true_bytes_and_composing_characters = function()
    with_source({ "αβγ", "é plus", "last" }, function(buf)
      local line = selected(buf, { 1, 0 }, { 3, vim.v.maxcol }, "line")
      H.eq(1, #line.spans)
      H.eq({ "αβγ", "é plus", "last" }, line.spans[1].lines)
      H.eq(3, line.spans[1].end_line)
      H.eq(4, line.spans[1].end_col)
      local chars = selected(buf, { 1, 4 }, { 1, 2 }, "char")
      H.eq({ "βγ" }, chars.spans[1].lines)
      H.eq(2, chars.spans[1].start_col)
      H.eq(6, chars.spans[1].end_col)
      local composed = selected(buf, { 2, 0 }, { 2, 0 }, "char")
      H.eq({ "é" }, composed.spans[1].lines)
      H.eq(3, composed.spans[1].end_col)
    end)
  end,

  visual_blocks_follow_cells_across_tabs_and_wide_characters = function()
    with_source({ "abcdef", "a\téx", "ab界ef" }, function(buf)
      vim.bo[buf].tabstop = 8
      local block = selected(buf, { 1, 2 }, { 3, 3 }, "block")
      H.eq(3, #block.spans)
      H.eq({ "cd" }, block.spans[1].lines)
      H.eq({ "  " }, block.spans[2].lines)
      H.eq(1, block.spans[2].start_col)
      H.eq(2, block.spans[2].end_col)
      H.eq({ "界" }, block.spans[3].lines)
      H.eq(2, block.spans[3].start_col)
      H.eq(5, block.spans[3].end_col)

      local partial_wide = selected(buf, { 1, 3 }, { 3, 5 }, "block")
      H.eq({ "de" }, partial_wide.spans[1].lines)
      H.eq({ " e" }, partial_wide.spans[3].lines)
    end)
  end,

  empty_sources_keep_file_references_without_inventing_lines = function()
    with_source({}, function(buf)
      local context = Source.context({ buf = buf, row = 1 })
      H.eq("src/old name.lua", context.file.path)
      H.eq({}, context.spans)
      H.eq(0, #vim.api.nvim_buf_get_keymap(buf, "n"))
      H.eq('@"src/old name.lua"', require("rill.sidekick").format(context, { kind = "file" }))
    end)
    local unrelated = vim.api.nvim_create_buf(false, true)
    H.eq(nil, Source.context({ buf = unrelated, row = 1 }))
    vim.api.nvim_buf_delete(unrelated, { force = true })
  end,

  source_metadata_lives_until_wipe_even_after_the_review_tab_closes = function()
    local origin = vim.api.nvim_get_current_win()
    local original_buf = vim.api.nvim_get_current_buf()
    vim.cmd("tabnew")
    local review_tab = vim.api.nvim_get_current_tabpage()
    local content = { lines = { "return 1\r" }, text = "return 1\r\n", eol = true, crlf = true }
    local address = { root = "/repo", path = "file.lua", side = "new", revision = "index" }
    local first = Source.create(content, address, { sidekick = false })
    local second = Source.create(content, address, { sidekick = false })
    H.ok(vim.api.nvim_buf_get_name(first) ~= vim.api.nvim_buf_get_name(second), "source URIs must be unique")
    vim.api.nvim_set_current_win(origin)
    vim.api.nvim_win_set_buf(origin, first)
    vim.api.nvim_set_current_tabpage(review_tab)
    vim.cmd("tabclose")
    H.eq("dos", vim.bo[first].fileformat)
    H.eq(true, vim.bo[first].endofline)
    H.eq({ "return 1" }, Source.context({ buf = first, row = 1 }).spans[1].lines)
    H.eq("index", Source.context({ buf = first, row = 1 }).spans[1].revision)
    vim.api.nvim_win_set_buf(origin, original_buf)
    H.eq(false, vim.api.nvim_buf_is_valid(first))
    H.eq(nil, Source.context({ buf = first, row = 1 }))
    vim.api.nvim_buf_delete(second, { force = true })
  end,
}
