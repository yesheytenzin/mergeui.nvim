local M = {}

-- Parse conflicts from buffer lines
-- Returns list of { start = lnum, mid = lnum, finish = lnum, ours = {}, theirs = {} }
function M.parse(bufnr)
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local conflicts = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line:match("^<<<<<<<") then
      local start = i
      local mid, finish
      local ours = {}
      local theirs = {}
      i = i + 1
      -- collect ours until =======
      while i <= #lines do
        if lines[i]:match("^=======") then
          mid = i
          break
        end
        table.insert(ours, lines[i])
        i = i + 1
      end
      if not mid then break end
      i = i + 1
      while i <= #lines do
        if lines[i]:match("^>>>>>>>") then
          finish = i
          break
        end
        table.insert(theirs, lines[i])
        i = i + 1
      end
      if not finish then break end
      table.insert(conflicts, {
        start = start,
        mid = mid,
        finish = finish,
        ours = ours,
        theirs = theirs,
      })
    end
    i = i + 1
  end
  return conflicts
end

function M.has_conflicts(bufnr)
  return #M.parse(bufnr) > 0
end

return M
