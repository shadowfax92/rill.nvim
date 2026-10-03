local H = require("tests.helpers")

-- Shared setup for every attached-terminal case. Themes reproduce dim comments
-- and diagnostic colors independently of an optional theme plugin.
local PRELUDE = [==[
vim.opt.rtp:prepend(PLUGIN_ROOT)
vim.o.termguicolors = true
vim.o.laststatus = 3
-- Claude Code's diff bands, sampled from its terminal rendering; light themes
-- use delta's matching pale bands.
local BANDS = {
  dark = { add = 0x022800, delete = 0x3d0101 },
  light = { add = 0xd0ffd0, delete = 0xffe0e0 },
}
local original_comment, palette
local function theme(light)
  palette = light and BANDS.light or BANDS.dark
  vim.api.nvim_set_hl(0, "Normal", { fg = light and "#282828" or "#ebdbb2", bg = light and "#faf9f5" or "#282828" })
  vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = light and "#387440" or "#b3f6c0" })
  vim.api.nvim_set_hl(0, "DiagnosticError", { fg = "#fb4934" })
  vim.api.nvim_set_hl(0, "@keyword.lua", { fg = light and "#000088" or "#00ffff" })
  vim.api.nvim_set_hl(0, "@number.lua", { fg = "#b16286" })
  vim.api.nvim_set_hl(0, "@comment.lua", { fg = light and "#cccccc" or "#665c54", italic = true })
  original_comment = vim.api.nvim_get_hl(0, { name = "@comment.lua", link = false })
end
theme(false)
local function luminance(rgb)
  local total = 0
  for i, weight in ipairs({0.2126, 0.7152, 0.0722}) do
    local channel = math.floor(rgb / 2 ^ ((3 - i) * 8)) % 256 / 255
    total = total + weight * (channel <= 0.04045 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4)
  end
  return total
end
local function contrast(a, b)
  a, b = luminance(a), luminance(b)
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05)
end
local function finish(ok, err)
  vim.fn.writefile({ ok and "PASS" or ("FAIL " .. tostring(err):gsub("\n", " ")) }, OUTPUT_PATH)
  vim.cmd("qa!")
end
-- A changed screen row carries its band through every gutter cell, and the
-- numbers and sign drawn there stay readable on it. Returns the drawn glyphs.
local function gutter(win, row, text_col, band)
  local glyphs = {}
  for col = vim.fn.win_screenpos(win)[2], text_col - 1 do
    local cell = vim.api.nvim__inspect_cell(1, row - 1, col - 1)
    assert(cell[2].background == band, "the diff band must continue through the gutter")
    if cell[1] ~= " " then
      assert(contrast(cell[2].foreground, band) >= 4.5, "gutter numbers and signs are unreadable on the band")
      glyphs[#glyphs + 1] = cell[1]
    end
  end
  return table.concat(glyphs)
end
-- Git serves one modified file. Sources arrive after the initial paint, so
-- completed syntax must repaint lines that were already drawn.
local function fixture(file, sources)
  package.loaded["rill.git"] = {
    load = function(_, callback)
      vim.schedule(function()
        callback(nil, {
          root = "/tmp", label = "base → head",
          left = { kind = "commit", label = "base" }, right = { kind = "commit", label = "head" },
          files = { vim.tbl_extend("keep", file, { id = "fixture.lua", path = "fixture.lua", status = "M" }) },
        })
      end)
      return function() end
    end,
    source = function(_, _, side, callback)
      local lines = sources[side]
      vim.defer_fn(function() callback(nil, { lines = lines, text = table.concat(lines, "\n") }) end, 100)
      return function() end
    end,
  }
end
-- Pixels are read only after syntax completes and the plugin repaints, without
-- dirtying the grid from the assertion itself.
local function painted(review, inspect)
  local started = vim.uv.hrtime()
  local function check()
    local file = review.files[1]
    if not file or not file.syntax then
      if vim.uv.hrtime() - started > 5000000000 then finish(false, "syntax did not complete"); return end
      vim.defer_fn(check, 20)
      return
    end
    vim.defer_fn(function() inspect() end, 30)
  end
  check()
end
]==]

-- A real TUI is essential: valid extmark options and cached captures do not
-- prove the rendered grid changes. In particular, :redraw can leave cached
-- syntax invisible until a user scrolls a previously clean screen line. Each
-- case runs as an init script in a detached tmux session and reports PASS/FAIL.
local function paint(code)
  if vim.fn.executable("tmux") ~= 1 then
    print("SKIP terminal paint: tmux is required for the attached UI regression")
    return
  end
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local output, script = root .. "/result", root .. "/init.lua"
  local session = "rill-paint-test-" .. tostring(vim.uv.hrtime()):gsub("%W", "")
  code = (PRELUDE .. code):gsub("PLUGIN_ROOT", function()
    return string.format("%q", vim.fn.getcwd())
  end)
  code = code:gsub("OUTPUT_PATH", function()
    return string.format("%q", output)
  end)
  vim.fn.writefile(vim.split(code, "\n", { plain = true }), script)
  local ok, err = xpcall(function()
    H.command({
      "tmux",
      "new-session",
      "-d",
      "-s",
      session,
      "-x",
      "150",
      "-y",
      "30",
      vim.v.progpath,
      "--clean",
      "-u",
      script,
    })
    H.ok(
      vim.wait(8000, function()
        return vim.fn.filereadable(output) == 1
      end, 20),
      "terminal paint timed out"
    )
    H.eq("PASS", table.concat(vim.fn.readfile(output), "\n"))
  end, debug.traceback)
  vim.system({ "tmux", "kill-session", "-t", session }):wait()
  vim.fn.delete(root, "rf")
  if not ok then
    error(err, 0)
  end
end

return {
  ["terminal paint keeps code and comments readable across layouts and themes"] = function()
    paint([==[
local sources = {}
for _, side in ipairs({ "old", "new" }) do
  local name = side == "old" and "old_value" or "new_value"
  local lines = { "local " .. name .. " = " .. (side == "old" and "1 -- previous value" or "2 -- current value"), "return " .. name }
  -- Enough source to make syntax indexing yield across several timer turns.
  for i = 1, 600 do lines[#lines + 1] = "local value_" .. i .. " = " .. i end
  sources[side] = lines
end
fixture({ additions = 2, deletions = 2,
  patch = "@@ -1,2 +1,2 @@\n-local old_value = 1 -- previous value\n-return old_value\n+local new_value = 2 -- current value\n+return new_value\n" }, sources)
vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function()
  vim.api.nvim__inspect_cell(1, 0, 0)
  local review = require("rill").open({ sidekick = false })
  local function inspect()
    local checked, comments = 0, 0
    local panes = review.layout == "unified" and {{review.main_win, "unified"}}
      or {{review.main_win, "old"}, {review.right_win, "new"}}
    for _, pane in ipairs(panes) do
      for index, row in ipairs(review.rows) do
        local position = vim.fn.screenpos(pane[1], index, 1)
        if row.kind == "file" then
          local winpos = vim.fn.win_screenpos(pane[1])
          local band = vim.api.nvim__inspect_cell(1, position.row - 1, winpos[2] + vim.api.nvim_win_get_width(pane[1]) - 3)
          assert(band[2].background == vim.api.nvim_get_hl(0, { name = "RillHeader" }).bg,
            "file header band must extend across the pane")
        elseif row.kind == "code" then
          local side = pane[2] == "unified" and (row.new and "new" or "old") or pane[2]
          local cell = row[side]
          if cell then
            local kind = side == "old" and "delete" or "add"
            local expected = palette[kind]
            local comment_start = cell.text:find("--", 1, true)
            for column = 1, #cell.text do
              local pixel = vim.api.nvim__inspect_cell(1, position.row - 1, position.col + column - 2)
              assert(pixel[2].background == expected, "changed code must sit on its uniform " .. kind .. " band")
              if comment_start and column >= comment_start and cell.text:sub(column, column) ~= " " then
                assert(contrast(pixel[2].foreground, pixel[2].background) >= 4.5,
                  "dim comment text is unreadable against the diff background")
                assert(pixel[2].italic == true, "comment styling must survive its contrast adjustment")
                comments = comments + 1
              end
            end
            local eol = vim.api.nvim__inspect_cell(1, position.row - 1, position.col + #cell.text + 4)
            assert(eol[2].background == expected, kind .. " band missing after end of line")
            local keyword
            for _, span in ipairs(row.file.syntax[side][cell.line] or {}) do
              if span[1] == 0 then keyword = vim.api.nvim_get_hl(0, { name = span[3], link = false }).fg end
            end
            local first = vim.api.nvim__inspect_cell(1, position.row - 1, position.col - 1)
            assert(first[2].foreground == keyword, "completed syntax is invisible until scrolling")
            local glyphs = gutter(pane[1], position.row, position.col, expected)
            assert(glyphs:find(kind == "add" and "+" or "−", 1, true), "changed rows must keep their gutter sign")
            checked = checked + 1
          end
        end
      end
    end
    assert(checked == 4 and comments > 0, "expected code and comments on both diff sides")
    assert(vim.deep_equal(original_comment, vim.api.nvim_get_hl(0, { name = "@comment.lua", link = false })),
      "review comment colors must not change ordinary source buffers")
  end
  -- Phases: unified dark, split dark, split light, unified light. Cached
  -- captures must follow the ColorScheme change without reparsing.
  local phase = 1
  local function step()
    local ok, err = xpcall(inspect, debug.traceback)
    if not ok then finish(false, err); return end
    if phase == 4 then finish(true); return end
    if phase == 2 then
      theme(true)
      vim.api.nvim_exec_autocmds("ColorScheme", {})
    else
      review:toggle_layout()
    end
    phase = phase + 1
    painted(review, step)
  end
  painted(review, step)
end })
]==])
  end,

  ["wrapped changed lines keep their band through the gutter"] = function()
    paint([==[
local long = "local wrapped = '" .. string.rep("abcdefghij", 40) .. "'"
fixture({ additions = 1, deletions = 1, patch = "@@ -1 +1 @@\n-local short = 1\n+" .. long .. "\n" },
  { old = { "local short = 1" }, new = { long } })
vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function()
  vim.api.nvim__inspect_cell(1, 0, 0)
  local review = require("rill").open({ sidekick = false, wrap = true })
  painted(review, function()
    local ok, err = xpcall(function()
      for index, row in ipairs(review.rows) do
        if row.kind == "code" and row.new then
          local position = vim.fn.screenpos(review.main_win, index, 1)
          assert(gutter(review.main_win, position.row, position.col, palette.add):find("+", 1, true),
            "the first screen row keeps its gutter sign")
          assert(gutter(review.main_win, position.row + 1, position.col, palette.add) == "",
            "wrapped rows continue the band without repeating numbers or signs")
          return
        end
      end
      error("the long added line was not rendered")
    end, debug.traceback)
    finish(ok, err)
  end)
end })
]==])
  end,
}
