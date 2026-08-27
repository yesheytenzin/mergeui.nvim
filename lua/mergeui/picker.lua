local M = {}
local git = require("mergeui.git")
local parser = require("mergeui.parser")

-- get all conflict files via git (unmerged) + fallback grep for markers
function M.get_conflict_files()
  local files = {}
  -- 1. git diff --name-only --diff-filter=U
  local out = vim.system({"git","diff","--name-only","--diff-filter=U"}, {text=true}):wait()
  if out.code == 0 and out.stdout and vim.trim(out.stdout) ~= "" then
    for _, f in ipairs(vim.split(vim.trim(out.stdout), "\n")) do
      if f ~= "" then table.insert(files, f) end
    end
  else
    -- fallback: git ls-files --unmerged
    local out2 = vim.system({"git","ls-files","--unmerged"}, {text=true}):wait()
    if out2.code == 0 and out2.stdout and vim.trim(out2.stdout) ~= "" then
      local seen={}
      for _, line in ipairs(vim.split(vim.trim(out2.stdout), "\n")) do
        -- format: 100644 <hash> 2<TAB>file
        local f = line:match("\t(.+)$")
        if f and not seen[f] then seen[f]=true; table.insert(files,f) end
      end
    end
  end
  -- 2. fallback if not git repo or still empty: search cwd for markers
  if #files == 0 then
    local cwd = vim.fn.getcwd()
    local is_git = git.is_git_repo(cwd)
    if not is_git then
      -- avoid grepping $HOME huge tree; only check cwd if it contains a file with markers via quick scan limited to 2 levels
      if cwd == vim.fn.expand("~") or cwd == "/" then return files end
      -- grep for <<<<<<< in cwd (limit)
      local grep = vim.system({"grep","-r","--include=*.rb","--include=*.js","--include=*.ts","--include=*.py","--include=*.lua","--include=*.json","--include=*.yml","--include=*.yaml","-l","<<<<<<<","."}, {text=true, cwd=cwd}):wait()
      if grep.code==0 and grep.stdout and vim.trim(grep.stdout)~="" then
        for _, f in ipairs(vim.split(vim.trim(grep.stdout),"\n")) do
          if f~="" then table.insert(files, (f:gsub("^%./",""))) end
        end
      end
    end
  end
  -- filter to only files that still have markers (git diff may include already resolved but not staged)
  local filtered={}
  for _, f in ipairs(files) do
    local full = vim.fn.fnamemodify(f, ":p")
    -- if file exists and has markers, keep
    if vim.fn.filereadable(full)==1 then
      local content = ""
      pcall(function() content = table.concat(vim.fn.readfile(full), "\n") end)
      if content:match("<<<<<<<") then
        table.insert(filtered, f)
      else
        -- also keep if git still marks unmerged (even if markers gone but not staged, we keep for safety)
        -- Check if file is still in unmerged list via second check? keep if in original files but markers gone -> maybe resolved, so skip
        -- skip to filter resolved
      end
    end
  end
  -- if filtered empty but original files had content, return original (for case where file staged)
  if #filtered==0 and #files>0 then
    -- check if files still unmerged via git (they will be in git diff), so return files even if markers gone? but we filtered, so return empty to indicate done
    return filtered
  end
  return #filtered>0 and filtered or files
end

local picker_ns = vim.api.nvim_create_namespace("mergeui-picker")
local picker_state = { buf=nil, win=nil }

function M.get_state() return picker_state end

function M.refresh()
  local files = M.get_conflict_files()
  if not picker_state.buf or not vim.api.nvim_buf_is_valid(picker_state.buf) then return files end
  vim.api.nvim_buf_set_option(picker_state.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(picker_state.buf, 0, -1, false, {})
  if #files==0 then
    vim.api.nvim_buf_set_lines(picker_state.buf, 0, -1, false, {
      "  ✓ No conflicts — all resolved!",
      "",
      "  Press q to close, r to refresh",
    })
  else
    local lines = {}
    table.insert(lines, string.format("  MERGE CONFLICTS (%d) — <CR> to open 3-pane  |  r refresh  |  q close", #files))
    table.insert(lines, string.rep("─", 60))
    for i,f in ipairs(files) do
      table.insert(lines, string.format("%2d  %s", i, f))
    end
    table.insert(lines, "")
    table.insert(lines, "  Tip: :MergeUI <file> to open directly | :MergeUIClose to close merge")
    vim.api.nvim_buf_set_lines(picker_state.buf, 0, -1, false, lines)
    -- highlight first line
    pcall(vim.api.nvim_buf_set_extmark, picker_state.buf, picker_ns, 0,0,{ end_row=1, hl_group="Title", hl_eol=true })
  end
  vim.api.nvim_buf_set_option(picker_state.buf, "modifiable", false)
  return files
end

function M.open_picker()
  local files = M.get_conflict_files()
  -- reuse or create picker buffer
  if picker_state.buf and vim.api.nvim_buf_is_valid(picker_state.buf) then
    -- just focus
    local wins = vim.fn.win_findbuf(picker_state.buf)
    if wins and #wins>0 then
      vim.api.nvim_set_current_win(wins[1])
    else
      vim.cmd("enew")
      vim.api.nvim_win_set_buf(0, picker_state.buf)
    end
  else
    picker_state.buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(picker_state.buf, "MERGEUI://Conflicts")
    vim.api.nvim_set_current_buf(picker_state.buf)
  end
  picker_state.win = vim.api.nvim_get_current_win()
  vim.bo[picker_state.buf].buftype = "nofile"
  vim.bo[picker_state.buf].bufhidden = "hide"
  vim.bo[picker_state.buf].filetype = "mergeui-picker"
  vim.bo[picker_state.buf].modifiable = false
  vim.wo[picker_state.win].cursorline = true
  vim.wo[picker_state.win].winbar = " MERGEUI  │  Conflicts List "
  -- refresh content
  files = M.refresh()
  -- keymaps (Enter or single/double click to open — no extra <CR> needed)
  local opts = { buffer=picker_state.buf, silent=true, noremap=true }
  local function open_selected()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(picker_state.buf, lnum-1, lnum, false)[1] or ""
    local file = line:match("^%s*%d+%s+(.+)$")
    if not file then
      file = vim.fn.expand("<cfile>")
      if file=="" then vim.notify("No file on line", vim.log.levels.WARN); return end
    end
    file = vim.trim(file)
    if file:match("^─") or file:match("^MERGE") or file:match("^Tip:") then return end
    if vim.fn.filereadable(file)==0 then
      local out = vim.system({"git","rev-parse","--show-toplevel"}, {text=true}):wait()
      if out.code==0 then
        local root = vim.trim(out.stdout)
        local full = root.."/"..file
        if vim.fn.filereadable(full)==1 then file=full end
      end
    end
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.schedule(function()
      local bufnr = vim.api.nvim_get_current_buf()
      if require("mergeui.parser").has_conflicts(bufnr) then
        require("mergeui").open(bufnr)
      else
        vim.notify("No conflicts in " .. file, vim.log.levels.INFO)
      end
    end)
  end
  vim.keymap.set("n", "<CR>", open_selected, opts)
  -- single click = open immediately (without needing Enter)
  vim.keymap.set("n", "<LeftMouse>", function()
    -- let Neovim move cursor first, then open
    vim.schedule(open_selected)
  end, opts)
  vim.keymap.set("n", "<2-LeftMouse>", open_selected, opts)
  vim.keymap.set("n", "q", function() 
    if vim.api.nvim_win_is_valid(picker_state.win) then pcall(vim.api.nvim_win_close, picker_state.win, false) end
    picker_state.win=nil
  end, opts)
  vim.keymap.set("n", "r", function() M.refresh(); vim.notify("Refreshed " .. #M.get_conflict_files() .. " conflicts", vim.log.levels.INFO) end, opts)
  vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, picker_state.win, false) end, opts)
  -- auto-preview: selecting file in list (j/k) shows 3-pane without needing <CR>
  local preview_timer = nil
  local last_lnum = -1
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = picker_state.buf,
    callback = function()
      local lnum = vim.api.nvim_win_get_cursor(picker_state.win)[1]
      if lnum == last_lnum then return end
      last_lnum = lnum
      if preview_timer then vim.fn.timer_stop(preview_timer) end
      preview_timer = vim.fn.timer_start(120, function()
        -- reuse open_selected but without notify spam
        local line = vim.api.nvim_buf_get_lines(picker_state.buf, lnum-1, lnum, false)[1] or ""
        local file = line:match("^%s*%d+%s+(.+)$")
        if not file or file:match("^─") or file:match("^MERGE") or file:match("^Tip:") then return end
        file = vim.trim(file)
        if vim.fn.filereadable(file)==0 then
          local out = vim.system({"git","rev-parse","--show-toplevel"}, {text=true}):wait()
          if out.code==0 then
            local root = vim.trim(out.stdout)
            local full = root.."/"..file
            if vim.fn.filereadable(full)==1 then file=full else return end
          else return end
        end
        vim.schedule(function()
          -- open without re-creating picker, keep picker visible
          vim.cmd("edit " .. vim.fn.fnameescape(file))
          vim.schedule(function()
            local bufnr = vim.api.nvim_get_current_buf()
            if require("mergeui.parser").has_conflicts(bufnr) then
              require("mergeui").open(bufnr)
            end
          end)
        end)
      end)
    end,
  })
  vim.notify(string.format("MergeUI: %d file(s) — j/k to preview, <CR>/click to open", #files), vim.log.levels.INFO)
  return files
end

return M
