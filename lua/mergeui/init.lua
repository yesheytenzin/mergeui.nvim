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

  -- Manual movement in RESULT selects the conflict under its cursor. Side panes use
  -- the explicit selection maintained by [c/]c, so differing revision lengths do
  -- not select the wrong block.
  if state.middle_win and vim.api.nvim_win_is_valid(state.middle_win)
      and vim.api.nvim_get_current_win() == state.middle_win then
    local lnum = vim.api.nvim_win_get_cursor(state.middle_win)[1]
    for i, conflict in ipairs(state.conflicts) do
      if lnum >= conflict.start and lnum <= conflict.finish then
        state.active_conflict = i
        return i
      end
    end
  end

  state.active_conflict = math.max(1, math.min(state.active_conflict or 1, #state.conflicts))
  return state.active_conflict
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

  -- Keep the same conflict slot selected; after removal this naturally selects
  -- the next unresolved block. Focus stays in whichever pane invoked the action.
  state.active_conflict = math.max(1, math.min(idx, #state.conflicts))
  local next_conflict = state.conflicts[state.active_conflict]
  local new_lnum = next_conflict and next_conflict.start or math.max(1, c.start)
  pcall(vim.api.nvim_win_set_cursor, state.middle_win, { new_lnum, 0 })

  local labels = { left = ">> CURRENT (yours)", right = "<< INCOMING (theirs)", both = "both", none = "X dismissed" }
  vim.notify(string.format("Conflict %d: took %s", idx, labels[choice]), vim.log.levels.INFO)
end

local function jump(dir)
  local state = ui.get_state()
  local count = #state.conflicts
  if count == 0 then
    vim.notify("No conflicts", vim.log.levels.INFO)
    return
  end

  local idx = current_conflict_idx() or 1
  if dir == "next" then
    idx = (idx % count) + 1
  else
    idx = ((idx - 2) % count) + 1
  end
  state.active_conflict = idx

  local target = state.conflicts[idx].start
  pcall(vim.api.nvim_win_set_cursor, state.middle_win, { target, 0 })
  if state.middle_win and vim.api.nvim_win_is_valid(state.middle_win) then
    vim.api.nvim_win_call(state.middle_win, function() vim.cmd("normal! zz") end)
  end
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
  -- view toggle: single (only RESULT) vs triple (CURRENT|RESULT|INCOMING)
  pcall(vim.api.nvim_create_user_command, "MergeUIToggle", function() require("mergeui.ui").toggle_view() end, { desc = "MergeUI: toggle single ↔ triple view" })
  pcall(vim.api.nvim_create_user_command, "MergeUISingle", function() require("mergeui.config").options.view="single"; vim.notify("MergeUI: single pane (RESULT only)", vim.log.levels.INFO) end, { desc = "MergeUI: single pane" })
  pcall(vim.api.nvim_create_user_command, "MergeUITriple", function() require("mergeui.config").options.view="triple"; vim.notify("MergeUI: triple pane (CURRENT|RESULT|INCOMING)", vim.log.levels.INFO) end, { desc = "MergeUI: triple pane" })

  pcall(vim.api.nvim_create_user_command, "MergeUIWriteQuit", M.write_quit, {
    desc = "Write result, close all merge panes, and return to conflict list",
  })
  _G.MergeUIExpandWriteQuit = M._expand_write_quit
  vim.cmd([[cnoreabbrev <expr> wq v:lua.MergeUIExpandWriteQuit()]])

  -- keep indicators fresh only on normal-mode changes and after insert leaves (avoids per-keystroke refresh)
  local grp = vim.api.nvim_create_augroup("RubymineMerge", { clear = true })
  local refresh_timer = nil
  local function schedule_refresh(buf)
    if refresh_timer then vim.fn.timer_stop(refresh_timer) end
    refresh_timer = vim.fn.timer_start(120, function()
      local st = ui.get_state()
      if st.active and buf == st.middle_buf and vim.api.nvim_buf_is_valid(buf) then
        ui.refresh()
      end
    end)
  end
  vim.api.nvim_create_autocmd({ "TextChanged", "BufWritePost" }, {
    group = grp,
    callback = function(ev)
      local st = ui.get_state()
      if st.active and ev.buf == st.middle_buf then schedule_refresh(ev.buf) end
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = grp,
    callback = function(ev)
      local st = ui.get_state()
      if st.active and ev.buf == st.middle_buf then schedule_refresh(ev.buf) end
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

  -- Install identical actions in all three panes. This prevents global mappings
  -- (notably gl diagnostics) from taking over when CURRENT/INCOMING has focus.
  local km = config.options.keymaps
  local function set_merge_keymaps(target_buf)
    local opts = { buffer = target_buf, silent = true, noremap = true }
    local function map(lhs, rhs, desc)
      vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", opts, { desc = desc }))
    end

    map(km.take_left, function() apply("left") end, "Merge: take CURRENT >>")
    map(km.take_right, function() apply("right") end, "Merge: take INCOMING <<")
    map(km.take_both, function() apply("both") end, "Merge: take both")
    map(km.take_none, function() apply("none") end, "Merge: discard conflict")
    map(km.next_conflict, function() jump("next") end, "Merge: next conflict")
    map(km.prev_conflict, function() jump("prev") end, "Merge: previous conflict")
    map(km.quit, function() ui.close() end, "Merge: close view")
    map("gh", function() apply("left") end, "Merge: take CURRENT >>")
    map("gl", function() apply("right") end, "Merge: take INCOMING <<")
    map("gB", function() apply("both") end, "Merge: take both")
    map("gX", function() apply("none") end, "Merge: discard conflict")
  end

  local merge_state = ui.get_state()
  for _, target_buf in ipairs({ merge_state.left_buf, merge_state.middle_buf, merge_state.right_buf }) do
    if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
      set_merge_keymaps(target_buf)
    end
  end
  -- toggle view from any merge pane
  for _, target_buf in ipairs({ merge_state.left_buf, merge_state.middle_buf, merge_state.right_buf }) do
    if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
      vim.keymap.set("n", "<leader>mt", function() require("mergeui.ui").toggle_view() end, { buffer=target_buf, silent=true, desc="MergeUI: toggle single/triple" })
      vim.keymap.set("n", "<leader>m1", function() require("mergeui.config").options.view="single"; vim.notify("single") end, { buffer=target_buf, silent=true })
      vim.keymap.set("n", "<leader>m3", function() require("mergeui.config").options.view="triple"; vim.notify("triple") end, { buffer=target_buf, silent=true })
    end
  end

  merge_state.active_conflict = 1
  if merge_state.conflicts[1] then
    pcall(vim.api.nvim_win_set_cursor, merge_state.middle_win, { merge_state.conflicts[1].start, 0 })
    vim.api.nvim_win_call(merge_state.middle_win, function() vim.cmd("normal! zz") end)
  end
  pcall(function() vim.api.nvim_set_current_win(merge_state.middle_win) end)

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
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        local ok, has = pcall(parser.has_conflicts, bufnr)
        if ok and not has and M._picker_return and vim.api.nvim_buf_is_valid(M._picker_return) then
          pcall(picker.refresh)
        end
      end)
    end,
  })
end

return M
