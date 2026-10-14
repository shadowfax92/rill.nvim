-- Shared group names keep document, Files and winbar consistent. Worktree edits
-- are a marker rather than a numbered commit; branch merges explain their base.
local M = {}

function M.label(index, total, group, form)
  if group.kind == "uncommitted" then
    return "● Uncommitted changes"
  end
  local short, subject = group.short or "", group.subject or ""
  local note = group.note and (" · " .. group.note) or ""
  if form == "title" then
    return ("[%d/%d] %s %s%s"):format(index, total, short, subject, note)
  elseif form == "tree" then
    return ("%d/%d %s %s%s"):format(index, total, short, subject, note)
  end
  local text = ("● %d/%d  %s  %s — %s · %s"):format(
    index,
    total,
    short,
    subject,
    group.author or "",
    group.date or ""
  )
  if group.merge and not group.note then
    text = text .. " · merge vs 1st parent"
  end
  if group.root_commit then
    text = text .. " · root"
  end
  return text .. note
end

function M.commit_count(groups)
  return #groups - ((groups[#groups] or {}).kind == "uncommitted" and 1 or 0)
end

return M
