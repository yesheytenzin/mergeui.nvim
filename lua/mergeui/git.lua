local M = {}

local function git_cmd(args, cwd)
  local cmd = { "git" }
  for _, a in ipairs(args) do table.insert(cmd, a) end
  local out = vim.system(cmd, { cwd = cwd, text = true }):wait()
  if out.code ~= 0 then return nil end
  return out.stdout
end

function M.is_git_repo(cwd)
  return git_cmd({ "rev-parse", "--is-inside-work-tree" }, cwd) ~= nil
end

-- Try to get :2: (ours/current) and :3: (theirs/incoming) versions
-- Returns { ours = string or nil, theirs = string or nil, base = string or nil }
function M.get_stage_versions(filepath, cwd)
  cwd = cwd or vim.fn.fnamemodify(filepath, ":h")
  local rel = filepath
  -- make relative to git root if possible
  local git_root = git_cmd({ "rev-parse", "--show-toplevel" }, cwd)
  if git_root then
    git_root = vim.trim(git_root)
    if vim.startswith(filepath, git_root) then
      rel = filepath:sub(#git_root + 2)
    end
  end
  local function show(stage)
    local data = git_cmd({ "show", stage .. ":" .. rel }, cwd)
    if data then return data end
    return nil
  end
  local ours = show(":2")
  local theirs = show(":3")
  local base = show(":1")
  if ours or theirs then
    return { ours = ours, theirs = theirs, base = base }
  end
  return nil
end

return M
