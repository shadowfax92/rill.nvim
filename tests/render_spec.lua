local H = require("tests.helpers")

return {
  ["terminal paint shows diff backgrounds and completed syntax without scrolling"] = function()
    if vim.fn.executable("tmux") ~= 1 then
      print("SKIP terminal paint: tmux is required for the attached UI regression")
      return
    end
    local root, result = vim.fn.tempname(), nil
    vim.fn.mkdir(root, "p")
    local output, script = root .. "/result", root .. "/init.lua"
    local session = "rill-paint-test-" .. tostring(vim.uv.hrtime()):gsub("%W", "")
    -- A real TUI is essential: valid extmark options and cached captures do not
    -- prove the rendered grid changes. In particular, :redraw can leave cached
    -- syntax invisible until a user scrolls a previously clean screen line.
    local code = [[
vim.opt.rtp:prepend(PLUGIN_ROOT)
vim.o.termguicolors = true
vim.o.laststatus = 3
vim.api.nvim_set_hl(0, "Normal", { fg = "#dddddd", bg = "#282828" })
vim.api.nvim_set_hl(0, "@keyword.lua", { fg = "#00ffff" })
package.loaded["rill.git"] = {
  load = function(_, callback)
    vim.schedule(function()
      callback(nil, {
        root = "/tmp", label = "base → head",
        left = { kind = "commit", label = "base" }, right = { kind = "commit", label = "head" },
        files = { { id = "fixture.lua", path = "fixture.lua", status = "M", additions = 2, deletions = 2,
          patch = "@@ -1,2 +1,2 @@\n-local old_value = 1\n-return old_value\n+local new_value = 2\n+return new_value\n" } },
      })
    end)
    return function() end
  end,
  source = function(_, _, side, callback)
    local name = side == "old" and "old_value" or "new_value"
    local lines = { "local " .. name .. " = " .. (side == "old" and "1" or "2"), "return " .. name }
    -- Enough hidden source to make capture indexing yield after hydration has
    -- already repainted the compact diff. This reproduces late syntax arrival.
    for i = 1, 600 do lines[#lines + 1] = "local value_" .. i .. " = " .. i end
    vim.defer_fn(function() callback(nil, { lines = lines, text = table.concat(lines, "\n") }) end, 100)
    return function() end
  end,
}
local function finish(ok, err)
  vim.fn.writefile({ ok and "PASS" or ("FAIL " .. tostring(err):gsub("\n", " ")) }, OUTPUT_PATH)
  vim.cmd("qa!")
end
vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function()
  -- Prime UI highlight-state inspection before the first review paint.
  vim.api.nvim__inspect_cell(1, 0, 0)
  local review = require("rill").open({ sidekick = false })
  local started = vim.uv.hrtime()
  local function check()
    local file = review.files[1]
    if not file or not file.syntax or not file.words then
      if vim.uv.hrtime() - started > 5000000000 then finish(false, "syntax did not complete"); return end
      vim.defer_fn(check, 20)
      return
    end
    -- Leave a timer turn for the plugin's scheduled repaint, without forcing a
    -- redraw from the test. The assertion reads the actual terminal grid.
    vim.defer_fn(function()
      finish(xpcall(function()
        local checked = 0
        for index, row in ipairs(review.rows) do
          if row.kind == "file" then
            local position = vim.fn.screenpos(review.main_win, index, 1)
            local band = vim.api.nvim__inspect_cell(1, position.row - 1, vim.o.columns - 4)
            assert(band[2].background == vim.api.nvim_get_hl(0, { name = "RillHeader" }).bg,
              "file header band must extend across the pane")
          elseif row.kind == "code" then
            local cell, side = row.new or row.old, row.new and "new" or "old"
            local position = vim.fn.screenpos(review.main_win, index, 1)
            local screen = vim.api.nvim__inspect_cell(1, position.row - 1, position.col - 1)
            local group = side == "old" and "RillDelete" or "RillAdd"
            local expected = vim.api.nvim_get_hl(0, { name = group }).bg
            assert(screen[2].background == expected, group .. " background missing from painted code")
            local eol = vim.api.nvim__inspect_cell(1, position.row - 1, position.col + #cell.text + 4)
            assert(eol[2].background == expected, group .. " background missing after end of line: " .. vim.inspect({ position, eol, screen, text = cell.text, width = vim.o.columns }))
            local keyword
            for _, span in ipairs(file.syntax[side][cell.line] or {}) do
              if span[1] == 0 then keyword = vim.api.nvim_get_hl(0, { name = span[3], link = false }).fg end
            end
            assert(keyword and keyword ~= 0xdddddd, "fixture requires distinct syntax captures")
            assert(screen[2].foreground == keyword, "completed syntax is invisible until scrolling")
            checked = checked + 1
          end
        end
        assert(checked == 4, "expected both painted diff sides")
      end, debug.traceback))
    end, 30)
  end
  check()
end })
]]
    code = code:gsub("PLUGIN_ROOT", function()
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
      result = table.concat(vim.fn.readfile(output), "\n")
      H.eq("PASS", result)
    end, debug.traceback)
    vim.system({ "tmux", "kill-session", "-t", session }):wait()
    vim.fn.delete(root, "rf")
    if not ok then
      error(err, 0)
    end
  end,
}
