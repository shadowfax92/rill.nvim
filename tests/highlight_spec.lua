local H = require("tests.helpers")
local Highlight = require("rill.highlight")
local Model = require("rill.model")

local function await(method, file)
  local complete, failure = false, nil
  method(file, function(err)
    failure, complete = err, true
  end)
  H.ok(
    vim.wait(3000, function()
      return complete
    end, 5),
    "highlight callback was never settled"
  )
  H.eq(nil, failure)
end

local function changed(old, new)
  return Model.parse({
    path = "sample.lua",
    patch = "@@ -143 +143 @@\n-" .. old .. "\n+" .. new .. "\n",
  })
end

local function fake_parsers(query, use)
  local original_parser, original_query = vim.treesitter.get_string_parser, vim.treesitter.query.get
  local parsers = {}
  vim.treesitter.get_string_parser = function()
    local parser = { destroyed = 0 }
    function parser:parse(_, callback)
      callback()
    end
    function parser:destroy()
      self.destroyed = self.destroyed + 1
    end
    function parser:for_each_tree(callback)
      callback({
        root = function()
          return {}
        end,
      }, {
        lang = function()
          return "lua"
        end,
      })
    end
    parsers[#parsers + 1] = parser
    return parser
  end
  vim.treesitter.query.get = function()
    return query
  end
  local ok, err = xpcall(function()
    use(parsers)
  end, debug.traceback)
  vim.treesitter.get_string_parser, vim.treesitter.query.get = original_parser, original_query
  if not ok then
    error(err)
  end
end

return {
  word_ranges_follow_utf8_bytes_and_ignore_crlf = function()
    local file = changed('print("café")\r', 'print("caffè")\r')
    await(Highlight.words, file)
    H.eq({ { 10, 12 } }, file.words.old[143])
    H.eq({ { 10, 13 } }, file.words.new[143])
    local empty = changed("", "é")
    await(Highlight.words, empty)
    H.eq({}, empty.words.old[143])
    H.eq({ { 0, 2 } }, empty.words.new[143])
    local long = changed(string.rep("a", 1001), "short")
    await(Highlight.words, long)
    H.eq({}, long.words.old[143])
    H.eq({}, long.words.new[143])
  end,

  real_lua_parser_uses_complete_sources_and_releases_trees = function()
    local file = {
      meta = { path = "sample.lua" },
      old_source = { "local café = 1\r", "--[[", "return café", "]]" },
      new_source = { "return 2" },
    }
    await(Highlight.syntax, file)
    H.eq({ { 0, 12, "@comment.lua", 100 } }, file.syntax.old[3])
    H.ok(vim.tbl_contains(file.syntax.old[1], function(span)
      return vim.deep_equal(span, { 6, 11, "@variable.lua", 100 })
    end, { predicate = true }))
    H.eq({ 0, 6, "@keyword.return.lua", 100 }, file.syntax.new[1][1])
    for _, span in ipairs(file.syntax.old[1]) do
      H.ok(span[2] <= 15, "CR must not become a display column")
    end
    H.eq({}, file.parsers)
    Highlight.dispose(file)
    H.eq(nil, file.syntax)
  end,

  metadata_ranges_and_priorities_match_neovim = function()
    local metadata = {
      { priority = "150", [1] = { range = { 0, 1, 1, 0, 4, 4 }, priority = "201" } },
      { [1] = { range = { 1, 0, 2, 0 }, priority = "202" } },
      { [1] = { range = { 1, -10, 1, 5000 } } },
    }
    fake_parsers({
      captures = { "special" },
      iter_captures = function()
        local index = 0
        return function()
          index = index + 1
          if metadata[index] then
            return 1, {}, metadata[index]
          end
        end
      end,
    }, function(parsers)
      local file = { meta = { path = "file.lua" }, old_source = { "abcde\r", "fgh", "ijk" } }
      await(Highlight.syntax, file)
      H.eq({ { 1, 4, "@special.lua", 150 } }, file.syntax.old[1])
      H.eq({ { 0, 3, "@special.lua", 202 }, { 0, 3, "@special.lua", 100 } }, file.syntax.old[2])
      H.eq(nil, file.syntax.old[3], "end-exclusive capture must not highlight the following row")
      H.eq(1, parsers[1].destroyed)
    end)
  end,

  capture_traversal_yields_to_other_neovim_work = function()
    local count, responsive = 0, false
    fake_parsers({
      captures = { "variable" },
      iter_captures = function()
        return function()
          count = count + 1
          if count == 1 then
            vim.defer_fn(function()
              responsive = count < 5000
            end, 0)
          end
          if count <= 5000 then
            return 1, {}, { [1] = { range = { 0, 0, 0, 1 } } }
          end
        end
      end,
    }, function()
      local file = { meta = { path = "file.lua" }, old_source = { "x" } }
      await(Highlight.syntax, file)
      H.eq(true, responsive, "capture iteration blocked the main loop until the whole file finished")
      H.eq(5000, #file.syntax.old[1])
    end)
  end,

  disposal_cancels_deferred_capture_traversal = function()
    local count, callbacks, file = 0, 0, nil
    fake_parsers({
      captures = { "variable" },
      iter_captures = function()
        return function()
          count = count + 1
          if count == 1 then
            vim.defer_fn(function()
              Highlight.dispose(file)
            end, 0)
          end
          if count <= 5000 then
            return 1, {}, { [1] = { range = { 0, 0, 0, 1 } } }
          end
        end
      end,
    }, function(parsers)
      file = { meta = { path = "file.lua" }, old_source = { "x" } }
      Highlight.syntax(file, function(err)
        H.eq("cancelled", err)
        callbacks = callbacks + 1
      end)
      H.ok(
        vim.wait(3000, function()
          return callbacks == 1
        end, 1),
        "disposal did not settle highlight callback"
      )
      local stopped_at = count
      H.ok(stopped_at < 5000, "disposal must interrupt unfinished traversal")
      vim.wait(10, function()
        return false
      end, 1)
      H.eq(stopped_at, count, "a deferred worker resumed after its source was disposed")
      H.eq(1, callbacks)
      H.eq(1, parsers[1].destroyed)
      H.eq(nil, file.syntax)
    end)
  end,

  missing_parsers_and_oversized_sources_complete_as_plain_text = function()
    local original, attempts = vim.treesitter.get_string_parser, 0
    vim.treesitter.get_string_parser = function()
      attempts = attempts + 1
      error("parser is not installed")
    end
    local ok, err = xpcall(function()
      local absent = { meta = { path = "source.lua" }, old_source = { "return 1" } }
      await(Highlight.syntax, absent)
      H.eq({ old = {}, new = {} }, absent.syntax)
      H.eq(1, attempts)
      for _, file in ipairs({
        { meta = { path = "file.lua" }, old_source = vim.fn["repeat"]({ "line" }, 100001) },
        { meta = { path = "file.lua" }, old_source = { string.rep("a", 1024 * 1024 + 1) } },
        { meta = { path = "unrecognized.rrrunknown" }, old_source = { "plain text" } },
      }) do
        await(Highlight.syntax, file)
        H.eq({ old = {}, new = {} }, file.syntax)
        H.eq(false, file.syntax_loading)
      end
      H.eq(1, attempts, "plain/oversized sources should never start a parser")
    end, debug.traceback)
    vim.treesitter.get_string_parser = original
    if not ok then
      error(err)
    end
  end,

  source_limits_cover_readable_files_and_are_independently_configurable = function()
    local original, attempts = vim.treesitter.get_string_parser, 0
    vim.treesitter.get_string_parser = function()
      attempts = attempts + 1
      error("fixture parser intentionally unavailable")
    end
    local ok, err = xpcall(function()
      for _, file in ipairs({
        { meta = { path = "file.lua" }, old_source = vim.fn["repeat"]({ "local a = 1" }, 100001) },
        { meta = { path = "file.lua" }, old_source = { string.rep("x", 1024 * 1024) } },
        {
          meta = { path = "file.lua" },
          old_source = { "first", "second" },
          syntax_limits = { max_lines = 1 },
        },
        { meta = { path = "file.lua" }, old_source = { "local a = 1" }, syntax_limits = { max_bytes = 3 } },
      }) do
        await(Highlight.syntax, file)
        H.eq({ old = {}, new = {} }, file.syntax)
      end
      H.eq(0, attempts, "over-limit sources should never enter the native parser")
      local larger = {
        meta = { path = "file.lua" },
        old_source = vim.fn["repeat"]({ "local a = 1" }, 3001),
      }
      await(Highlight.syntax, larger)
      H.eq(1, attempts, "default coverage must include sources above the old 3000-line cutoff")
    end, debug.traceback)
    vim.treesitter.get_string_parser = original
    if not ok then
      error(err)
    end
  end,

  concurrent_cached_and_cancelled_callers_all_settle_once = function()
    local file, count = changed("local old = 1", "local new = 2"), 0
    local function completed(err)
      H.eq(nil, err)
      count = count + 1
    end
    Highlight.words(file, completed)
    Highlight.words(file, completed)
    H.ok(vim.wait(3000, function()
      return count == 2
    end, 5))
    Highlight.words(file, completed)
    H.ok(vim.wait(3000, function()
      return count == 3
    end, 5))

    local abandoned, cancelled = changed("before", "after"), 0
    local function cancel(err)
      H.eq("cancelled", err)
      cancelled = cancelled + 1
    end
    Highlight.words(abandoned, cancel)
    Highlight.words(abandoned, cancel)
    Highlight.dispose(abandoned)
    Highlight.words(abandoned, cancel)
    H.ok(vim.wait(3000, function()
      return cancelled == 3
    end, 5))
    H.eq(nil, abandoned.words)
    H.eq(false, abandoned.words_loading)
  end,

  disposal_releases_pending_parsers_and_rejects_late_parse_callbacks = function()
    local original, pending, destroyed = vim.treesitter.get_string_parser, {}, 0
    vim.treesitter.get_string_parser = function()
      return {
        parse = function(_, _, callback)
          pending[#pending + 1] = callback
        end,
        destroy = function()
          destroyed = destroyed + 1
        end,
      }
    end
    local ok, err = xpcall(function()
      local file = { meta = { path = "file.lua" }, old_source = { "local a" }, new_source = { "local b" } }
      local callbacks = 0
      local function complete(failure)
        H.eq("cancelled", failure)
        callbacks = callbacks + 1
      end
      Highlight.syntax(file, complete)
      Highlight.syntax(file, complete)
      H.ok(vim.wait(3000, function()
        return #pending == 2
      end, 5))
      Highlight.dispose(file)
      H.eq(2, destroyed)
      for _, callback in ipairs(pending) do
        callback()
      end
      H.ok(vim.wait(3000, function()
        return callbacks == 2
      end, 5))
      H.eq(nil, file.syntax)
      H.eq(false, file.syntax_loading)
    end, debug.traceback)
    vim.treesitter.get_string_parser = original
    if not ok then
      error(err)
    end
  end,
}
