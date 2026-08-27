local config = require("tri-merge.config")
local parser = require("tri-merge.parser")
local ui = require("tri-merge.ui")

local M = {}

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
  if vim.g.tri_merge_setup_done == 1 and vim.g.rubymine_merge_setup_done == 1 then return end
  vim.g.tri_merge_setup_done = 1
  vim.g.rubymine_merge_setup_done = 1
  config.setup(opts)
  local km = config.options.keymaps

  -- create user commands (pcall to avoid duplicate when plugin/ already created them)
  -- Primary: TriMerge* (new name) + Alias: RubymineMerge* (back-compat)
  for _, prefix in ipairs({ "TriMerge", "RubymineMerge" }) do
    pcall(vim.api.nvim_create_user_command, prefix, function() M.open() end, { desc = "Open RubyMine-style 3-pane merge (CURRENT | RESULT | INCOMING)" })
    pcall(vim.api.nvim_create_user_command, prefix .. "Close", function() ui.close() end, { desc = "Close merge view" })
    pcall(vim.api.nvim_create_user_command, prefix .. "TakeLeft", function() apply("left") end, { desc = "Take CURRENT/Yours (>>)" })
    pcall(vim.api.nvim_create_user_command, prefix .. "TakeRight", function() apply("right") end, { desc = "Take INCOMING/Theirs (<<)" })
    pcall(vim.api.nvim_create_user_command, prefix .. "TakeBoth", function() apply("both") end, { desc = "Take both" })
    pcall(vim.api.nvim_create_user_command, prefix .. "TakeNone", function() apply("none") end, { desc = "Dismiss conflict (X)" })
  end

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
    return
  end
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
end

return M
