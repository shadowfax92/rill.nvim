vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = "./lua/?.lua;./lua/?/init.lua;./?.lua;" .. package.path
local passed, failed = 0, 0
local filter = arg and arg[1]
local files = vim.fn.glob("tests/*_spec.lua", false, true)
table.sort(files)
for _, path in ipairs(files) do
  if not filter or path:find(filter, 1, true) then
    local loaded, cases = pcall(dofile, path)
    if not loaded then
      failed = failed + 1
      print("FAIL " .. path .. "\n" .. tostring(cases))
    else
      for _, name in ipairs(vim.tbl_keys(cases)) do
        local ok, err = xpcall(cases[name], debug.traceback)
        if ok then
          passed = passed + 1
          print("PASS " .. path .. " · " .. name)
        else
          failed = failed + 1
          print("FAIL " .. path .. " · " .. name .. "\n" .. err)
        end
      end
    end
  end
end
print(("\n%d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cquit 1")
