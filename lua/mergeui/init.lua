local config = require("mergeui.config")
local parser = require("mergeui.parser")
local ui = require("mergeui.ui")
local picker = require("mergeui.picker")

local M = {}

local function return_to_picker()
  local files = picker.open_picker()
  if #files == 0 then
    vim.notify("MergeUI: all conflicts resolved ✓", vim.log.levels.INFO)
  end
end

function M.write_quit()
  local state = ui.get_state()
  if not state.active then
    vim.cmd("wq")
    return
  end

  local result_buf = state.middle_buf
  if result_buf and vim.api.nvim_buf_is_valid(result_buf) then
    vim.api.nvim_buf_call(result_buf, function() vim.cmd("silent write") end)
  end

  ui.close()
  if result_buf and vim.api.nvim_buf_is_valid(result_buf) then
    pcall(vim.api.nvim_buf_delete, result_buf, { force = false })
  end
  return_to_picker()
end

function M._expand_write_quit()
  if vim.fn.getcmdtype() == ":" and vim.fn.getcmdline() == "wq" and ui.get_state().active then
    return "MergeUIWriteQuit"
  end
  return "wq"
end

local function current_conflict_idx()
  local state = ui.get_state()
  if #state.conflicts == 0 then return nil end
  local cursor = vim.api.nvim_win_get_cursor(state.middle_win or 0)
  local lnum = cursor[1]
  -- find conflict at or after cursor
  for i, c in ipairs(state.conflicts) do
    if lnum >= c.start and lnum <= c.finish then return i end
  end
  -- else nearest after
  for i, c in ipairs(state.conflicts) do
    if c.start > lnum then return i end
  end
  return 1
end

local function apply(choice)
  local state = ui.get_state()
  if not state.active then
    vim.notify("RubymineMerge not active. Run :RubymineMerge", vim.log.levels.WARN)
    return
  end
  local idx = current_conflict_idx()
  if not idx then
    vim.notify("No conflict under cursor", vim.log.levels.WARN)
    return
  end
  local c = state.conflicts[idx]
  local bufnr = state.middle_buf
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local replacement = {}
  if choice == "left" then
    replacement = c.ours
  elseif choice == "right" then
    replacement = c.theirs
  elseif choice == "both" then
    vim.list_extend(replacement, c.ours)
    vim.list_extend(replacement, c.theirs)
  elseif choice == "none" then
    replacement = {} -- X - dismiss
  end

  -- make buffer modifiable temporarily
  vim.bo[bufnr].modifiable = true
  -- replace lines start-finish with replacement (nvim_buf_set_lines is 0-indexed, end exclusive)
  vim.api.nvim_buf_set_lines(bufnr, c.start - 1, c.finish, false, replacement)
  ui.refresh()

  -- move cursor to replacement area
  local new_lnum = c.start
  if #replacement > 0 then
    pcall(vim.api.nvim_win_set_cursor, state.middle_win, { new_lnum, 0 })
  else
    pcall(vim.api.nvim_win_set_cursor, state.middle_win, { math.max(1, new_lnum), 0 })
  end

  local labels = { left = ">> CURRENT (yours)", right = "<< INCOMING (theirs)", both = "both", none = "X dismissed" }
  vim.notify(string.format("Conflict %d: took %s", idx, labels[choice]), vim.log.levels.INFO)
end

local function jump(dir)
  local state = ui.get_state()
  if #state.conflicts == 0 then
    vim.notify("No conflicts", vim.log.levels.INFO)
    return
  end
  local cur = vim.api.nvim_win_get_cursor(state.middle_win)[1]
  local target
  if dir == "next" then
    for _, c in ipairs(state.conflicts) do
      if c.start > cur then target = c.start break end
    end
    if not target then target = state.conflicts[1].start end
  else
    for i = #state.conflicts, 1, -1 do
      local c = state.conflicts[i]
      if c.start < cur then target = c.start break end
    end
    if not target then target = state.conflicts[#state.conflicts].start end
  end
  pcall(vim.api.nvim_win_set_cursor, state.middle_win, { target, 0 })
  vim.api.nvim_set_current_win(state.middle_win)
  vim.cmd("normal! zz")
end

function M.setup(opts)
  if vim.g.mergeui_setup_done == 1 then return end
  vim.g.mergeui_setup_done = 1
  vim.g.tri_merge_setup_done = 1
  vim.g.rubymine_merge_setup_done = 1
  config.setup(opts)
  local km = config.options.keymaps

  -- create user commands (pcall to avoid duplicate when plugin/ already created them)
  -- Primary: MergeUI + Alias: TriMerge/RubymineMerge ; :MergeUI [file] -> picker list, <file> -> direct 3-pane
  for _, prefix in ipairs({ "MergeUI", "TriMerge", "RubymineMerge" }) do
    pcall(vim.api.nvim_create_user_command, prefix, function(opts)
      if opts.args and opts.args ~= "" then
        local f = vim.trim(opts.args)
        if vim.fn.filereadable(f)==0 then
          -- try git root relative
          local out = vim.system({"git","rev-parse","--show-toplevel"}, {text=true}):wait()
          if out.code==0 then
            local cand = vim.trim(out.stdout) .. "/" .. f
            if vim.fn.filereadable(cand)==1 then f=cand end
          end
        end
        vim.cmd("edit " .. vim.fn.fnameescape(f))
        vim.schedule(function() M.open(vim.api.nvim_get_current_buf()) end)
      else
        -- no arg: open conflist picker (like :G mergetool list)
        picker.open_picker()
      end
    end, { desc = "Open MergeUI picker or 3-pane ( :MergeUI [file] )", nargs="?", complete="file" })
    -- picker list command
    pcall(vim.api.nvim_create_user_command, prefix .. "List", function() picker.open_picker() end, { desc = "MergeUI: list conflict files" })
    pcall(vim.api.nvim_create_user_command, prefix .. "Close", function() 
      ui.close() 
      -- after close, return to picker filtered to remaining
      vim.schedule(function()
        local st = picker.get_state()
        if st.buf and vim.api.nvim_buf_is_valid(st.buf) then
          local files = picker.refresh()
          if #files>0 then
            -- ensure picker visible if not already
            local wins = vim.fn.win_findbuf(st.buf)
            if not wins or #wins==0 then picker.open_picker() end
          end
        end
      end)
    end, { desc = "Close merge view" })
    pcall(vim.api.nvim_create_user_command, prefix .. "TakeLeft", function() apply("left") end, { desc = "Take CURRENT/Yours (>>)" })
    pcall(vim.api.nvim_create_user_command, prefix .. "TakeRight", function() apply("right") end, { desc = "Take INCOMING/Theirs (<<)" })
    pcall(vim.api.nvim_create_user_command, prefix .. "TakeBoth", function() apply("both") end, { desc = "Take both" })
    pcall(vim.api.nvim_create_user_command, prefix .. "TakeNone", function() apply("none") end, { desc = "Dismiss conflict (X)" })
  end

  pcall(vim.api.nvim_create_user_command, "MergeUIWriteQuit", M.write_quit, {
    desc = "Write result, close all merge panes, and return to conflict list",
  })
  _G.MergeUIExpandWriteQuit = M._expand_write_quit
  vim.cmd([[cnoreabbrev <expr> wq v:lua.MergeUIExpandWriteQuit()]])

  -- autocmd to keep indicators fresh
  local grp = vim.api.nvim_create_augroup("RubymineMerge", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = grp,
    callback = function(ev)
      local st = ui.get_state()
      if st.active and ev.buf == st.middle_buf then
        -- debounce a bit
        vim.defer_fn(function() ui.refresh() end, 50)
      end
    end,
  })
  if config.options.auto_open then
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = grp,
      callback = function(ev)
        if parser.has_conflicts(ev.buf) then
          vim.defer_fn(function() M.open(ev.buf) end, 100)
        end
      end,
    })
  end

  -- expose for keymaps
  M._apply = apply
  M._jump = jump
end

function M.open(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not parser.has_conflicts(bufnr) then
    vim.notify("No merge conflicts in this file", vim.log.levels.WARN)
    -- even if no markers, try picker
    if #picker.get_conflict_files()>0 then picker.open_picker() end
    return
  end
  -- remember picker to return to after :wq/:q
  M._picker_return = picker.get_state().buf and vim.api.nvim_buf_is_valid(picker.get_state().buf) and picker.get_state().buf or nil

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then filepath = vim.fn.expand("%:p") end

  local st = ui.get_state()
  if st.active then ui.close() end

  -- ensure buffer is loaded and current
  if vim.api.nvim_get_current_buf() ~= bufnr then
    vim.api.nvim_set_current_buf(bufnr)
  end

  ui.open_layout(bufnr, filepath)

  -- set buffer-local keymaps on MIDDLE (Result) like RubyMine's >> << X
  local km = config.options.keymaps
  local opts = { buffer = bufnr, silent = true, noremap = true }
  -- >> take left (CURRENT)
  vim.keymap.set("n", km.take_left, function() apply("left") end, vim.tbl_extend("force", opts, { desc = "Merge: take CURRENT >> (left)" }))
  vim.keymap.set("n", km.take_right, function() apply("right") end, vim.tbl_extend("force", opts, { desc = "Merge: take INCOMING << (right)" }))
  vim.keymap.set("n", km.take_both, function() apply("both") end, vim.tbl_extend("force", opts, { desc = "Merge: take BOTH" }))
  vim.keymap.set("n", km.take_none, function() apply("none") end, vim.tbl_extend("force", opts, { desc = "Merge: dismiss X" }))
  vim.keymap.set("n", km.next_conflict, function() jump("next") end, vim.tbl_extend("force", opts, { desc = "Next conflict" }))
  vim.keymap.set("n", km.prev_conflict, function() jump("prev") end, vim.tbl_extend("force", opts, { desc = "Prev conflict" }))
  vim.keymap.set("n", km.quit, function() ui.close() end, vim.tbl_extend("force", opts, { desc = "Close merge view" }))

  -- also allow clicking indicators via extra keys: gl, gh for familiarity
  vim.keymap.set("n", "gh", function() apply("left") end, vim.tbl_extend("force", opts, { desc = "Merge: gh take left >>" }))
  vim.keymap.set("n", "gl", function() apply("right") end, vim.tbl_extend("force", opts, { desc = "Merge: gl take right <<" }))
  vim.keymap.set("n", "gB", function() apply("both") end, vim.tbl_extend("force", opts, { desc = "Merge: take both" }))
  vim.keymap.set("n", "gX", function() apply("none") end, vim.tbl_extend("force", opts, { desc = "Merge: dismiss" }))

  -- also map >> and << as 2-char sequences if user wants RubyMine click feel
  -- we keep leader maps as primary to not clash with shift operators in visual mode

  -- mouse: clicking virtual text not natively clickable, but we can make <LeftMouse> check position
  -- simple: clicking in middle near conflict will not auto-apply; user uses keybind

  jump("next") -- jump to first conflict
  -- center view
  pcall(function() vim.api.nvim_set_current_win(ui.get_state().middle_win) end)

  -- :w writes RESULT and keeps the panes open. Active-session :wq is expanded
  -- to :MergeUIWriteQuit, which writes, closes all three, and restores the list.
  local grp2 = vim.api.nvim_create_augroup("MergeUIFlow", { clear = true })
  -- :w in side panes should write the middle RESULT instead of scratch
  for _, b in ipairs({ ui.get_state().left_buf, ui.get_state().right_buf }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = grp2,
        buffer = b,
        callback = function()
          -- redirect :w from CURRENT/INCOMING to RESULT
          local st = ui.get_state()
          if st.middle_buf and vim.api.nvim_buf_is_valid(st.middle_buf) then
            vim.api.nvim_buf_call(st.middle_buf, function() vim.cmd("silent write") end)
            vim.notify("MergeUI: wrote RESULT (" .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(st.middle_buf), ":t") .. ")", vim.log.levels.INFO)
          end
        end,
      })
        -- Plain :q closes the merge layout. :wq is handled by MergeUIWriteQuit.
      vim.api.nvim_create_autocmd("QuitPre", {
        group = grp2,
        buffer = b,
        callback = function()
          vim.schedule(function() pcall(ui.close) end)
        end,
      })
    end
  end
  -- Plain :q from RESULT closes the merge layout.
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_create_autocmd("QuitPre", {
      group = grp2,
      buffer = bufnr,
      callback = function()
        vim.schedule(function() pcall(ui.close) end)
      end,
    })
    -- Normal :w is not intercepted and leaves the three panes open.
  end
  -- Fallback: if user does :qa or window closed, cleanup
  vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
    group = grp2,
    callback = function(ev)
      local st = ui.get_state()
      if st.active and (ev.buf == st.left_buf or ev.buf == st.right_buf or ev.buf == st.middle_buf) then
        vim.schedule(function()
          if st.active then pcall(ui.close) end
          -- return to picker filtered (only remaining)
          vim.schedule(function()
            local pb = M._picker_return or (picker.get_state().buf and picker.get_state().buf or nil)
            if pb and vim.api.nvim_buf_is_valid(pb) then
              local files = picker.refresh()
              local wins = vim.fn.win_findbuf(pb)
              if #files>0 and (not wins or #wins==0) then
                -- reopen picker if it was hidden by :wq closing last window
                picker.open_picker()
              elseif #files==0 then
                vim.notify("MergeUI: All conflicts resolved ✓", vim.log.levels.INFO)
              end
            end
          end)
        end)
      end
    end,
  })
  -- Refresh the hidden list after :w, but keep the three panes open.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = grp2,
    buffer = bufnr,
    callback = function()
      vim.schedule(function()
        -- if file no longer has markers after write, refresh picker (so :wq list is filtered)
        if not parser.has_conflicts(bufnr) and M._picker_return and vim.api.nvim_buf_is_valid(M._picker_return) then
          picker.refresh()
        end
      end)
    end,
  })
end

return M
