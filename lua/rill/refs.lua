--- Inventories comparison bases under the Git request's cancellation owner.
--- Defaults and picker hints share this inventory; no checkout, fetch or config
--- writes happen here, and ref count never multiplies the number of Git jobs.
local M = {}

local function label(ref)
  return ref:gsub("^refs/heads/", ""):gsub("^refs/remotes/", "")
end

function M.label(left)
  return left.label .. (left.base_source and " (" .. left.base_source .. ")" or "")
end

function M.read(owner, root, head, options, done)
  owner:run(root, { "symbolic-ref", "--quiet", "--short", "HEAD" }, options, function(name_err, name)
    name = not name_err and vim.trim(name) or "HEAD"
    owner:run(
      root,
      {
        "for-each-ref",
        "--sort=-committerdate",
        "--format=%(refname) %(objectname) %(symref) %(upstream)",
        "refs/heads",
        "refs/remotes",
      },
      options,
      function(err, output)
        if err then
          done(err)
          return
        end
        local context = { name = name, head = head, refs = {}, by_ref = {} }
        for record in output:gmatch("[^\n]+") do
          local ref, tip, symref, upstream = record:match("^(%S+) (%S+) (%S*) (%S*)$")
          local entry = {
            ref = ref,
            tip = tip,
            label = label(ref),
            upstream = upstream,
            branch = ref:match("^refs/heads/(.+)$") or ref:match("^refs/remotes/[^/]+/(.+)$"),
          }
          context.by_ref[ref] = entry
          if symref == "" then
            context.refs[#context.refs + 1] = entry
          elseif ref == "refs/remotes/origin/HEAD" then
            context.default_ref = symref
          end
        end
        local refs = context.by_ref
        context.default = refs[context.default_ref or ""]
          or refs["refs/remotes/origin/main"]
          or refs["refs/remotes/origin/master"]
          or refs["refs/heads/main"]
          or refs["refs/heads/master"]
        context.trunk = context.default and context.default.branch
        local current = refs["refs/heads/" .. name]
        context.tracking = current and current.upstream ~= "" and current.upstream or nil
        if name == "HEAD" then
          done(nil, context)
          return
        end
        -- gh records an intentional stacked PR target here. Graph proximity cannot
        -- distinguish that parent from a child branch merged back into this one.
        owner:run(
          root,
          { "config", "--get", "branch." .. name .. ".gh-merge-base" },
          options,
          function(config_err, value, result)
            -- Missing keys are ordinary Git exit 1. Other failures must stay
            -- visible instead of silently switching to another comparison base.
            if config_err and result and result.code == 1 then
              done(nil, context)
            elseif config_err then
              done(config_err)
            else
              value = vim.trim(value)
              if value ~= "" then
                local configured = refs[value]
                  or refs["refs/remotes/origin/" .. value]
                  or refs["refs/heads/" .. value]
                  or refs["refs/remotes/" .. value]
                context.configured = configured and configured.ref or value
              end
              done(nil, context)
            end
          end
        )
      end
    )
  end)
end

--- Rank useful bases first without walking history separately for every ref.
--- Keep full refs as identities: a tag or a local branch can share a short name
--- with a remote, while the row's label remains readable.
function M.choices(context, left)
  local choices, found = {}, false
  for order, entry in ipairs(context.refs) do
    if entry.ref ~= "refs/heads/" .. context.name and not entry.ref:match("/HEAD$") then
      local item = vim.tbl_extend("force", {}, entry)
      local exact_ref = left and left.ref and left.ref:match("^refs/")
      local in_use = left
        and (exact_ref and entry.ref == left.ref or not exact_ref and entry.label == left.label)
      local configured = entry.ref == context.configured
      local default = context.default and entry.ref == context.default.ref
      local upstream = entry.ref == context.tracking
      item.rank = in_use and 0 or configured and 1 or default and 2 or upstream and 3 or 4
      item.order, item.hints = order, {}
      for _, hint in ipairs({
        in_use and "in use" or "",
        configured and "gh-merge-base" or "",
        default and "default" or "",
        upstream and "upstream · unpushed only" or "",
        entry.tip == context.head and "= HEAD, no commits" or "",
      }) do
        if hint ~= "" then
          item.hints[#item.hints + 1] = hint
        end
      end
      found = found or in_use
      choices[#choices + 1] = item
    end
  end
  -- Explicit tags, SHAs and expressions are valid bases even though the branch
  -- inventory does not contain them. Keep that comparison visible in the picker.
  if left and not found and left.ref ~= "refs/heads/" .. context.name and left.label ~= context.name then
    choices[#choices + 1] = {
      ref = left.ref or left.label,
      label = left.label,
      tip = left.rev,
      rank = 0,
      order = 0,
      hints = { "in use" },
    }
  end
  table.sort(choices, function(a, b)
    return a.rank < b.rank or (a.rank == b.rank and a.order < b.order)
  end)
  return choices
end

return M
