local H = require("tests.helpers")
local model = require("rill.model")

local function fixture()
  local old = {}
  for line = 1, 20 do
    old[line] = "line" .. line
  end
  local new = {}
  for line = 1, 3 do
    new[#new + 1] = old[line]
  end
  new[#new + 1] = "replacement"
  for line = 6, 11 do
    new[#new + 1] = old[line]
  end
  new[#new + 1] = "inserted"
  for line = 12, 20 do
    new[#new + 1] = old[line]
  end
  local file = model.parse({
    id = "fixture",
    path = "source.lua",
    status = "M",
    patch = table.concat({
      "diff --git a/source.lua b/source.lua",
      "--- a/source.lua",
      "+++ b/source.lua",
      "@@ -3,5 +3,4 @@ first function",
      " line3",
      "-line4",
      "-line5",
      "+replacement",
      " line6",
      " line7",
      "@@ -10,4 +9,5 @@ second function",
      " line10",
      " line11",
      "+inserted",
      " line12",
      " line13",
      "",
    }, "\n"),
  })
  return file, old, new
end

local function addressed(rows, side)
  local values = {}
  for _, row in ipairs(rows) do
    if row[side] then
      values[#values + 1] = { row[side].line, row[side].text }
    elseif row.kind ~= "code" then
      H.eq(nil, row.old, "presentation rows have no old source")
      H.eq(nil, row.new, "presentation rows have no new source")
    end
  end
  return values
end

local function complete_source(source)
  local result = {}
  for line, text in ipairs(source) do
    result[#result + 1] = { line, text }
  end
  return result
end

return {
  ["unified and split carry identical source addresses without filler addresses"] = function()
    local file = fixture()
    H.eq(nil, file.error)
    local unified, split = model.project(file, "unified"), model.project(file, "split")
    H.eq(addressed(unified, "old"), addressed(split, "old"))
    H.eq(addressed(unified, "new"), addressed(split, "new"))
    H.eq({
      { 3, "line3" },
      { 4, "replacement" },
      { 5, "line6" },
      { 6, "line7" },
      { 9, "line10" },
      { 10, "line11" },
      { 11, "inserted" },
      { 12, "line12" },
      { 13, "line13" },
    }, addressed(unified, "new"))
    local paired, deletion, addition = false, false, false
    for _, row in ipairs(split) do
      if row.change == "change" then
        H.eq({ 4, "line4" }, { row.old.line, row.old.text })
        H.eq({ 4, "replacement" }, { row.new.line, row.new.text })
        paired = true
      elseif row.change == "delete" then
        H.eq(5, row.old.line)
        H.eq(nil, row.new)
        deletion = true
      elseif row.change == "add" then
        H.eq(11, row.new.line)
        H.eq(nil, row.old)
        addition = true
      end
    end
    H.ok(paired and deletion and addition)
  end,

  ["each gap expands independently from both ends with stable keys"] = function()
    local file, old, new = fixture()
    H.ok(model.hydrate(file, old, new))
    local initial = model.project(file, "unified")
    local gap_keys = {}
    for _, row in ipairs(initial) do
      if row.kind == "gap" then
        gap_keys[#gap_keys + 1] = row.key
      end
    end
    H.eq(3, #gap_keys)
    H.ok(model.expand(file, gap_keys[3], "top", 2))
    H.ok(model.expand(file, gap_keys[3], "bottom", 1))
    local expanded = model.project(file, "unified")
    local tail = {}
    for _, row in ipairs(expanded) do
      if row.new and row.new.line >= 14 then
        tail[#tail + 1] = row.new.line
      end
      if row.key == gap_keys[3] then
        H.eq(16, row.new_start)
        H.eq(4, row.new_count)
      end
    end
    H.eq({ 14, 15, 20 }, tail)
    H.ok(model.expand(file, gap_keys[1], "all"))
    H.eq({ 1, "line1" }, addressed(model.project(file, "split"), "new")[1])
    H.ok(model.collapse(file))
    H.eq(initial, model.project(file, "unified"))
  end,

  ["fully expanded document covers both entire source files exactly once"] = function()
    local file, old, new = fixture()
    H.ok(model.hydrate(file, old, new))
    H.ok(model.expand_all(file))
    for _, layout in ipairs({ "unified", "split" }) do
      local rows = model.project(file, layout)
      H.eq(complete_source(old), addressed(rows, "old"))
      H.eq(complete_source(new), addressed(rows, "new"))
      for _, row in ipairs(rows) do
        H.ok(row.kind ~= "gap")
      end
    end
  end,

  ["hydration rejects races in changed lines and in previously hidden context"] = function()
    local file, old, new = fixture()
    H.ok(model.hydrate(file, old, new))
    H.ok(model.expand_all(file))
    local original = model.project(file, "unified")
    local changed = vim.deepcopy(new)
    changed[4] = "new edit"
    local ok, err = model.hydrate(file, old, changed)
    H.eq(false, ok)
    H.ok(err:find("new line 4", 1, true))
    changed = vim.deepcopy(new)
    changed[20] = "hidden new edit"
    ok, err = model.hydrate(file, old, changed)
    H.eq(false, ok)
    H.ok(err:find("Unchanged source context changed", 1, true))
    H.eq(original, model.project(file, "unified"), "failed hydrate must be atomic")
    changed = vim.deepcopy(new)
    changed[21] = "appended"
    ok, err = model.hydrate(file, old, changed)
    H.eq(false, ok)
    H.ok(err:find("Source length changed", 1, true))
  end,

  ["insertion and deletion zero-count boundaries preserve beginning and end lines"] = function()
    local cases = {
      { patch = "@@ -0,0 +1,2 @@\n+first\n+second\n", old = {}, new = { "first", "second" } },
      { patch = "@@ -1,2 +0,0 @@\n-first\n-second\n", old = { "first", "second" }, new = {} },
      {
        patch = "@@ -2,2 +1,0 @@\n-second\n-third\n",
        old = { "first", "second", "third" },
        new = { "first" },
      },
      { patch = "@@ -1,0 +2 @@\n+second\n", old = { "first" }, new = { "first", "second" } },
      { patch = "@@ -1 +0,0 @@\n-first\n", old = { "first", "second" }, new = { "second" } },
    }
    for _, case in ipairs(cases) do
      local file = model.parse({ path = "file", patch = case.patch })
      H.eq(nil, file.error)
      H.ok(model.hydrate(file, case.old, case.new))
      H.ok(model.expand_all(file))
      for _, layout in ipairs({ "unified", "split" }) do
        local rows = model.project(file, layout)
        H.eq(complete_source(case.old), addressed(rows, "old"))
        H.eq(complete_source(case.new), addressed(rows, "new"))
      end
    end
  end,

  ["patch files can contain nested headers and hunk syntax as ordinary source"] = function()
    local file = model.parse({
      path = "outer.patch",
      old_path = "old name.patch",
      patch = table.concat({
        "diff --git a/not-the-path b/not-the-path",
        "--- a/not-the-path",
        "+++ b/not-the-path",
        "@@ -1,4 +1,4 @@",
        "--- inner old",
        "-+++ inner old",
        "-@@ -0,0 +1 @@",
        "-diff --git a/x b/x",
        "+--- inner new",
        "++++ inner new",
        "+@@ -0,0 +2 @@",
        "+diff --git a/y b/y",
        "",
      }, "\n"),
    })
    H.eq(nil, file.error)
    H.eq(1, #file.hunks)
    H.eq("outer.patch", file.meta.path)
    H.eq(
      { { 1, "-- inner old" }, { 2, "+++ inner old" }, { 3, "@@ -0,0 +1 @@" }, { 4, "diff --git a/x b/x" } },
      addressed(model.project(file, "unified"), "old")
    )
    H.eq(
      { { 1, "--- inner new" }, { 2, "+++ inner new" }, { 3, "@@ -0,0 +2 @@" }, { 4, "diff --git a/y b/y" } },
      addressed(model.project(file, "split"), "new")
    )
  end,

  ["no-newline markers belong to source cells and never consume source rows"] = function()
    local file = model.parse({
      path = "text",
      patch = "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n",
    })
    H.eq(nil, file.error)
    H.eq(2, #file.hunks[1].rows)
    H.eq(true, file.hunks[1].rows[1].old.no_newline)
    H.eq(true, file.hunks[1].rows[2].new.no_newline)
    H.ok(model.hydrate(file, { "old" }, { "new" }))
    H.eq({ { 1, "old" } }, addressed(model.project(file, "split"), "old"))
    H.eq({ { 1, "new" } }, addressed(model.project(file, "unified"), "new"))
  end,

  ["CRLF bodies compare as logical lines while raw supplied sources remain intact"] = function()
    local file = model.parse({ path = "text", patch = "@@ -1,2 +1,2 @@\n same\r\n-old\r\n+new\r\n" })
    H.ok(model.hydrate(file, { "same\r", "old\r" }, { "same\r", "new\r" }))
    H.eq({ "same\r", "old\r" }, file.old_source)
    H.eq({ { 1, "same" }, { 2, "new" } }, addressed(model.project(file, "unified"), "new"))
    H.ok(model.hydrate(file, { "same", "old" }, { "same", "new" }))
  end,

  ["renames and mode-only entries can expand the complete unchanged file"] = function()
    local file = model.parse({
      path = "new.lua",
      old_path = "old.lua",
      status = "R100",
      patch = "old mode 100644\nnew mode 100755\n",
    })
    H.eq(0, #file.hunks)
    local collapsed = model.project(file, "unified")
    H.eq("Renamed from old.lua", collapsed[1].text)
    H.eq("old mode 100644", collapsed[2].text)
    H.eq(true, collapsed[#collapsed].unknown)
    H.ok(model.hydrate(file, { "first", "last" }, { "first", "last" }))
    H.ok(model.expand_all(file))
    H.eq({ { 1, "first" }, { 2, "last" } }, addressed(model.project(file, "split"), "new"))
  end,

  ["binary omitted and empty files retain explicit presentation without source addresses"] = function()
    local binary = model.parse({ path = "image.png", binary = true, patch = "" })
    H.eq({ { kind = "meta", text = "Binary file" } }, model.project(binary, "unified"))
    H.eq(false, model.hydrate(binary, {}, {}))
    local omitted = model.parse({ path = "large.txt", omitted_reason = "File exceeds limit" })
    H.eq({ { kind = "meta", text = "File exceeds limit" } }, model.project(omitted, "split"))
    local empty = model.parse({ path = "empty", patch = "" })
    H.ok(model.hydrate(empty, {}, {}))
    H.ok(model.expand_all(empty))
    H.eq({ { kind = "meta", text = "Empty file" } }, model.project(empty, "unified"))
  end,

  ["unknown context requires hydration and zero-length context produces no false lines"] = function()
    local file = model.parse({ path = "text", patch = "@@ -1 +1 @@\n-old\n+new\n" })
    H.eq(false, model.expand_all(file))
    H.eq(false, model.expand(file, "gap:2", "all"))
    H.ok(model.hydrate(file, { "old" }, { "new" }))
    H.eq(false, model.expand(file, "invalid", "all"))
    H.eq(false, model.expand(file, "gap:2", "wrong"))
    H.eq(false, model.expand(file, "gap:2", "top", -1))
    H.ok(model.expand_all(file))
    H.eq(2, #model.project(file, "unified"))
    H.eq(1, #model.project(file, "split"))
  end,

  ["malformed and truncated hunks never publish partial source coordinates"] = function()
    local patches = {
      "@@ -1,3 +1,3 @@\n first\n-second\n+new\n",
      "@@ -1 +1 @@\n-old\n-extra\n+new\n",
      "@@ -0 +1 @@\n-old\n+new\n",
      "@@ -1 +3 @@\n-old\n+new\n",
    }
    for _, patch in ipairs(patches) do
      local file = model.parse({ path = "text", patch = patch })
      H.ok(file.error)
      H.eq({}, addressed(model.project(file, "unified"), "new"))
      H.eq(false, model.hydrate(file, {}, {}))
    end
    local file = model.parse({ path = "text", patch = "@@ -100,0 +100,0 @@\n" })
    H.eq(
      false,
      model.hydrate(file, {}, {}),
      "invalid empty-hunk boundary must return an error without throwing"
    )
  end,
}
