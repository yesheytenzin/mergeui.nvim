local config = require("mergeui.config")
local parser = require("mergeui.parser")

local M = {}
local ns = vim.api.nvim_create_namespace("rubymine-merge")

local state = {
  middle_buf = nil,
  middle_win = nil,
  left_buf = nil,
  left_win = nil,
  right_buf = nil,
  right_win = nil,
  conflicts = {},
  active_conflict = 1,
  active = false,
}

function M.get_state() return state end

local function ensure_hl()
  -- Follow system theme (light/dark) via standard highlight links + background-aware fallback
  local is_dark = vim.o.background == "dark"
  -- Base panes follow Normal so they match any colorscheme (Omarchy, Tokyonight, etc.)
  vim.api.nvim_set_hl(0, "RubymineCurrent", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "RubymineIncoming", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "RubymineResult", { link = "Normal", default = true })
  -- Conflict/marker use theme's Diff/Comment so they adapt to light/dark
  vim.api.nvim_set_hl(0, "RubymineConflict", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "RubymineConflictMarker", { link = "Comment", default = true })
  -- Changed blocks: theme-aware red/green (only on conflicting code) — a bit more darker
  if is_dark then
    vim.api.nvim_set_hl(0, "RubymineCurrentLine", { bg = "#4a2e2e", fg = "#ffcccc" }) -- more darker
    vim.api.nvim_set_hl(0, "RubymineIncomingLine", { bg = "#2e4a2e", fg = "#ccffcc" }) -- more darker
  else
    vim.api.nvim_set_hl(0, "RubymineCurrentLine", { bg = "#ffd8d8", fg = "#5a1a1a" }) -- a bit more darker
    vim.api.nvim_set_hl(0, "RubymineIncomingLine", { bg = "#d8ffd8", fg = "#1a4d1a" }) -- a bit more darker
  end
  vim.api.nvim_set_hl(0, "RubymineIndicator", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "RubymineIndicatorRight", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "RubymineIndicatorX", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "RubymineActionBar", { link = "StatusLineNC", default = true })
  vim.api.nvim_set_hl(0, "RubymineWinbar", { link = "WinBar", default = true })
  vim.api.nvim_set_hl(0, "RubymineWinbarNC", { link = "WinBarNC", default = true })
  -- Auto-update on colorscheme/background change
  pcall(vim.api.nvim_create_autocmd, {"ColorScheme", "OptionSet"}, {
    pattern = {"*", "background"},
    group = vim.api.nvim_create_augroup("MergeUIThemeSync", {clear=true}),
    callback = function() vim.schedule(ensure_hl) end,
  })
end

function M.clear_indicators(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

-- ---------- conflict-aware side alignment (RubyMine-style) ----------
-- LEFT/RIGHT have different line counts than MIDDLE (no markers, only
-- their own side of each conflict), so equal toplines show different code.
-- Instead we locate each conflict's block in the side buffers (in order)
-- and explicitly centre all three panes on the same conflict.
local function split_stage(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  -- vim.split keeps a trailing "" for the final newline; buffers don't.
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  return lines
end

local function find_block(lines, block, from)
  if not block or #block == 0 then return nil end
  from = math.max(1, from or 1)
  local n, m = #lines, #block
  if m > n then return nil end
  for s = from, n - m + 1 do
    if lines[s] == block[1] then
      local ok = true
      for k = 2, m do
        if lines[s + k - 1] ~= block[k] then ok = false break end
      end
      if ok then return s, s + m - 1 end
    end
  end
  return nil
end

-- Locate every conflict's ours/theirs block in the side lines, in order
-- (order-constrained search avoids matching identical code elsewhere).
-- Annotates each conflict with left_start/left_end (1-indexed, nil when
-- empty/missing) and returns highlight ranges (0-indexed, end-inclusive).
local function resolve_stage_positions(left_lines, right_lines, conflicts)
  local l_ranges, r_ranges = {}, {}
  local l_pos, r_pos = 1, 1
  local l_extra, r_extra = 0, 0
  for _, c in ipairs(conflicts) do
    c.left_start, c.left_end = nil, nil
    c.left_insert, c.left_fallback = nil, nil
    c.right_start, c.right_end = nil, nil
    c.right_insert, c.right_fallback = nil, nil
    if #c.ours > 0 then
      local s, e = find_block(left_lines, c.ours, l_pos)
      if s then
        c.left_start, c.left_end = s, e
        table.insert(l_ranges, { s - 1, e - 1 })
        l_pos = e + 1
      else
        c.left_fallback = math.max(1, math.min(c.start - l_extra, math.max(1, #left_lines)))
      end
    else
      c.left_insert = math.max(1, math.min(l_pos, math.max(1, #left_lines)))
    end
    if #c.theirs > 0 then
      local s, e = find_block(right_lines, c.theirs, r_pos)
      if s then
        c.right_start, c.right_end = s, e
        table.insert(r_ranges, { s - 1, e - 1 })
        r_pos = e + 1
      else
        c.right_fallback = math.max(1, math.min(c.start - r_extra, math.max(1, #right_lines)))
      end
    else
      c.right_insert = math.max(1, math.min(r_pos, math.max(1, #right_lines)))
    end
    l_extra = l_extra + #c.theirs + 3 -- MIDDLE carries theirs + 3 markers extra vs LEFT
    r_extra = r_extra + #c.ours + 3   -- MIDDLE carries ours + 3 markers extra vs RIGHT
  end
  return l_ranges, r_ranges
end

local function paint_side(bufnr, ranges, hl_group)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, r in ipairs(ranges or {}) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, r[1], 0, {
      end_row = r[2] + 1, hl_group = hl_group, hl_eol = true,
    })
  end
end

local function center_win(win, lnum)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local count = vim.api.nvim_buf_line_count(buf)
  if count < 1 then return end
  lnum = math.max(1, math.min(lnum or 1, count))
  pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
  pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zz") end)
end

local function side_target(c, side)
  if side == "left" then
    return c.left_start or c.left_insert or c.left_fallback
  end
  return c.right_start or c.right_insert or c.right_fallback
end

-- Display labels always reflect the effective keymaps: strip a leading
-- <leader> for compact display ("<leader>mh" -> "mh"), keep anything
-- else verbatim ("<C-h>" stays "<C-h>").
local function short_lhs(lhs)
  if not lhs or lhs == "" then return "?" end
  local s = lhs:gsub("^<[Ll]eader>", "")
  return s == "" and lhs or s
end

-- Middle-pane statusline built from the active keymaps, so what the buffer
-- shows always matches what actually works (incl. user overrides via
-- setup({ keymaps = ... })).
local function middle_statusline()
  local km = config.options.keymaps
  return string.format(
    "%%#RubymineWinbar#  %s Current  %s Incoming  %s Both  %s Discard  %%=%%#RubymineWinbar#%s/%s  %s Quit  %d conflicts ",
    short_lhs(km.take_left),
    short_lhs(km.take_right),
    short_lhs(km.take_both),
    short_lhs(km.take_none),
    km.next_conflict, km.prev_conflict,
    short_lhs(km.quit),
    #state.conflicts)
end

function M.update_statusline()
  if state.middle_win and vim.api.nvim_win_is_valid(state.middle_win) then
    pcall(vim.api.nvim_win_set_option, state.middle_win, "statusline", middle_statusline())
  end
end

-- Centre all three panes on conflict idx (RubyMine-style). Does not change
-- which window has focus. center_middle=false only moves the side panes
-- (used for cursor-follow while typing/navigating in RESULT).
function M.sync_conflict(idx, opts)
  opts = opts or {}
  if not config.options.sync_sides then return end
  if not state.active then return end
  if state._syncing then return end
  local c = state.conflicts[idx]
  if not c then return end
  state.active_conflict = idx
  state._syncing = true
  local center_middle = opts.center_middle
  if center_middle == nil then center_middle = true end
  if center_middle and state.middle_win and vim.api.nvim_win_is_valid(state.middle_win) then
    center_win(state.middle_win, c.start)
  end
  local lt = side_target(c, "left")
  if lt and state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
    center_win(state.left_win, lt)
  end
  local rt = side_target(c, "right")
  if rt and state.right_win and vim.api.nvim_win_is_valid(state.right_win) then
    center_win(state.right_win, rt)
  end
  state._syncing = false
end

-- Add >> / << / X virtual text indicators like RubyMine
function M.render_indicators()
  -- Statusline always reflects the effective keys + live conflict count,
  -- even when virtual-text indicators are disabled.
  M.update_statusline()
  if not config.options.show_indicators then return end
  ensure_hl()
  for _, bufnr in ipairs({ state.middle_buf }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      M.clear_indicators(bufnr)
    end
  end
  -- keep side pane highlights (light red/green) persistent; only clear middle

  for idx, c in ipairs(state.conflicts) do
    if state.middle_buf and vim.api.nvim_buf_is_valid(state.middle_buf) then
      -- One action strip above the conflict, labelled with the effective
      -- keys so the buffer matches the README (and user overrides).
      local km = config.options.keymaps
      pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.start - 1, 0, {
        virt_lines = { {
          { string.format("  %d/%d  ", idx, #state.conflicts), "RubymineActionBar" },
          { string.format(" >> CURRENT %s ", short_lhs(km.take_left)), "RubymineIndicator" },
          { string.format("  × DISCARD %s  ", short_lhs(km.take_none)), "RubymineIndicatorX" },
          { string.format(" << INCOMING %s ", short_lhs(km.take_right)), "RubymineIndicatorRight" },
          { string.format("  BOTH %s ", short_lhs(km.take_both)), "RubymineActionBar" },
        } },
        virt_lines_above = true,
      })
      pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.start - 1, 0, {
        sign_text = "◆ ",
        sign_hl_group = "RubymineIndicatorX",
        priority = 100,
      })
      -- Keep marker lines quiet; color only the actual alternatives.
      for _, row in ipairs({ c.start - 1, c.mid - 1, c.finish - 1 }) do
        pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, row, 0, {
          line_hl_group = "RubymineConflictMarker",
        })
      end
      if c.mid > c.start + 1 then
        pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.start, 0, {
          end_row = c.mid - 1,
          hl_group = "RubymineCurrentLine",
          hl_eol = true,
        })
      end
      if c.finish > c.mid + 1 then
        pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.mid, 0, {
          end_row = c.finish - 1,
          hl_group = "RubymineIncomingLine",
          hl_eol = true,
        })
      end
    end
  end
end

function M.create_buffers(filepath, middle_bufnr)
  local git = require("mergeui.git")
  local stage = git.get_stage_versions(filepath)

  local conflicts = parser.parse(middle_bufnr)
  state.conflicts = conflicts
  state.active_conflict = 1

  -- Left: ours, Right: theirs (no === markers, pure code)
  local left_lines, right_lines
  local left_hl_ranges, right_hl_ranges = {}, {}
  if stage and stage.ours and stage.theirs then
    left_lines = split_stage(stage.ours)
    right_lines = split_stage(stage.theirs)
    -- Order-constrained search: finds each conflict's block where it
    -- actually lives in :2:/:3: (correct even when earlier conflicts have
    -- different ours/theirs lengths or other auto-merged changes shifted
    -- line numbers). Falls back to corrected arithmetic per conflict.
    left_hl_ranges, right_hl_ranges = resolve_stage_positions(left_lines, right_lines, conflicts)
  else
    -- fallback: reconstruct from markers
    local all = vim.api.nvim_buf_get_lines(middle_bufnr, 0, -1, false)
    left_lines = {}
    right_lines = {}
    local i = 1
    while i <= #all do
      if all[i]:match("^<<<<<<<") then
        local c_idx
        for _, c in ipairs(conflicts) do
          if c.start == i then c_idx = c break end
        end
        if c_idx then
          if #c_idx.ours > 0 then
            local l_start = #left_lines + 1 -- 1-indexed sync target
            for _, l in ipairs(c_idx.ours) do table.insert(left_lines, l) end
            c_idx.left_start, c_idx.left_end = l_start, #left_lines
            table.insert(left_hl_ranges, {l_start - 1, #left_lines - 1})
          else
            c_idx.left_insert = math.max(1, #left_lines == 0 and 1 or #left_lines)
          end
          if #c_idx.theirs > 0 then
            local r_start = #right_lines + 1 -- 1-indexed sync target
            for _, l in ipairs(c_idx.theirs) do table.insert(right_lines, l) end
            c_idx.right_start, c_idx.right_end = r_start, #right_lines
            table.insert(right_hl_ranges, {r_start - 1, #right_lines - 1})
          else
            c_idx.right_insert = math.max(1, #right_lines == 0 and 1 or #right_lines)
          end
          i = c_idx.finish + 1
        else
          table.insert(left_lines, all[i])
          table.insert(right_lines, all[i])
          i = i + 1
        end
      else
        table.insert(left_lines, all[i])
        table.insert(right_lines, all[i])
        i = i + 1
      end
    end
  end
  state._left_hl_ranges = left_hl_ranges
  state._right_hl_ranges = right_hl_ranges

  state.left_buf = vim.api.nvim_create_buf(false, true)
  state.right_buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(state.left_buf, 0, -1, false, left_lines)
  vim.api.nvim_buf_set_lines(state.right_buf, 0, -1, false, right_lines)

  local ft = vim.bo[middle_bufnr].filetype
  vim.bo[state.left_buf].filetype = ft
  vim.bo[state.right_buf].filetype = ft
  vim.bo[state.left_buf].modifiable = false
  vim.bo[state.right_buf].modifiable = false
  vim.bo[state.left_buf].buftype = "nofile"
  vim.bo[state.right_buf].buftype = "nofile"
  vim.bo[state.left_buf].bufhidden = "wipe"
  vim.bo[state.right_buf].bufhidden = "wipe"
  -- :w / :q for side panes is handled via BufWriteCmd/QuitPre in init.lua (redirects to RESULT)
  vim.api.nvim_buf_set_name(state.left_buf, "CURRENT (Yours) - " .. filepath)
  vim.api.nvim_buf_set_name(state.right_buf, "INCOMING (Theirs) - " .. filepath)

  -- highlight changed blocks in side panes with light red / light green (no === markers)
  vim.schedule(function()
    paint_side(state.left_buf, state._left_hl_ranges, "RubymineCurrentLine")
    paint_side(state.right_buf, state._right_hl_ranges, "RubymineIncomingLine")
  end)

  return left_lines, right_lines
end

function M.open_layout(middle_bufnr, filepath)
  ensure_hl()
  state.middle_buf = middle_bufnr
  state.middle_win = vim.api.nvim_get_current_win()

  M.create_buffers(filepath, middle_bufnr)

  local view = require("mergeui.config").options.view
  -- Single pane: only RESULT (middle), no side windows
  if view == "single" then
    state.left_win = nil
    state.right_win = nil
    vim.api.nvim_set_current_win(state.middle_win)
    vim.wo[state.middle_win].number = false
    vim.wo[state.middle_win].cursorline = true
    vim.wo[state.middle_win].winfixwidth = false
    vim.wo[state.middle_win].signcolumn = "yes:1"
    vim.wo[state.middle_win].foldcolumn = "0"
    vim.api.nvim_win_set_option(state.middle_win, "winhl", "Normal:RubymineResult,SignColumn:RubymineResult,CursorLine:Visual")
    pcall(function()
      local fname = vim.fn.fnamemodify(filepath, ":t")
      vim.wo[state.middle_win].winbar = "%#RubymineWinbar#  RESULT · " .. fname .. "  %=%#RubymineWinbar# SINGLE "
      vim.api.nvim_win_set_option(state.middle_win, "statusline", middle_statusline())
    end)
  else
    -- RubyMine style: | LEFT (Current) | MIDDLE (Result) | RIGHT (Incoming) |  — 3 EQUAL COLUMNS like IDE
    vim.api.nvim_set_current_win(state.middle_win)
    -- left split (Yours)
    vim.cmd("leftabove vsplit")
    state.left_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.left_win, state.left_buf)
    vim.wo[state.left_win].number = false
    vim.wo[state.left_win].relativenumber = false
    vim.wo[state.left_win].cursorline = true
    vim.wo[state.left_win].winfixwidth = false
    vim.wo[state.left_win].signcolumn = "no"
    vim.wo[state.left_win].foldcolumn = "0"
    vim.api.nvim_win_set_option(state.left_win, "winhl", "Normal:RubymineCurrent,SignColumn:RubymineCurrent,CursorLine:CursorLine")

    -- go back to middle (Result)
    vim.api.nvim_set_current_win(state.middle_win)
    -- right split (Theirs)
    vim.cmd("rightbelow vsplit")
    state.right_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.right_win, state.right_buf)
    vim.wo[state.right_win].number = false
    vim.wo[state.right_win].cursorline = true
    vim.wo[state.right_win].winfixwidth = false
    vim.wo[state.right_win].signcolumn = "no"
    vim.wo[state.right_win].foldcolumn = "0"
    vim.api.nvim_win_set_option(state.right_win, "winhl", "Normal:RubymineIncoming,SignColumn:RubymineIncoming,CursorLine:CursorLine")

    -- middle (Result) - editable, centered like RubyMine
    vim.api.nvim_set_current_win(state.middle_win)
    vim.wo[state.middle_win].number = false
    vim.wo[state.middle_win].cursorline = true
    vim.wo[state.middle_win].winfixwidth = false
    vim.wo[state.middle_win].signcolumn = "yes:1"
    vim.wo[state.middle_win].foldcolumn = "0"
    vim.api.nvim_win_set_option(state.middle_win, "winhl", "Normal:RubymineResult,SignColumn:RubymineResult,CursorLine:Visual")

    -- FORCE 3 EQUAL COLUMNS like RubyMine (33% / 33% / 33%)
    vim.o.equalalways = true
    vim.o.eadirection = "hor"
    vim.cmd("wincmd =")
    local total = vim.o.columns
    local w = math.floor((total - 4) / 3)
    pcall(vim.api.nvim_win_set_width, state.left_win, w)
    pcall(vim.api.nvim_win_set_width, state.middle_win, w)
    pcall(vim.api.nvim_win_set_width, state.right_win, w)
    vim.cmd("wincmd =")

    -- Clean pane titles; directional actions live beside the conflict they affect.
    -- Winbars show the effective take keys so each pane matches the README.
    pcall(function()
      local fname = vim.fn.fnamemodify(filepath, ":t")
      local km = config.options.keymaps
      vim.wo[state.left_win].winbar = "%#RubymineWinbarNC#  CURRENT · HEAD  %=%#RubymineIndicator# " .. short_lhs(km.take_left) .. " >> RESULT "
      vim.wo[state.middle_win].winbar = "%#RubymineWinbar#  RESULT · " .. fname .. "  %=%#RubymineWinbar# EDITABLE "
      vim.wo[state.right_win].winbar = "%#RubymineIndicatorRight# RESULT << " .. short_lhs(km.take_right) .. " %#RubymineWinbarNC#%=  INCOMING · MERGE_HEAD  "
      vim.api.nvim_win_set_option(state.left_win, "statusline", "%#RubymineWinbarNC#  CURRENT  %=%l:%c ")
      vim.api.nvim_win_set_option(state.middle_win, "statusline", middle_statusline())
      vim.api.nvim_win_set_option(state.right_win, "statusline", "%#RubymineWinbarNC#  INCOMING  %=%l:%c ")
    end)
  end
  -- nicer vertical separators
  pcall(function() vim.opt.fillchars:append({ vert = "│", verthoriz = "┤", horiz = "─", horizup = "┴", horizdown = "┬" }) end)

  -- No scrollbind: the three revisions have different line counts (MIDDLE
  -- has markers + both sides, LEFT/RIGHT only their own side), so equal
  -- toplines would show different code. We centre all three panes on the
  -- same conflict explicitly via sync_conflict (RubyMine-style).
  for _, w in ipairs({ state.left_win, state.middle_win, state.right_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_set_option, w, "scrollbind", false)
      pcall(vim.api.nvim_win_set_option, w, "cursorbind", false)
    end
  end

  state.active = true
  M.render_indicators()
  -- Centre all three panes on the first conflict once layout settles.
  vim.schedule(function()
    if state.active and #state.conflicts > 0 then
      M.sync_conflict(state.active_conflict or 1)
    end
  end)

  -- keymaps are set in init.lua
end


function M.toggle_view()
  local cfg = require("mergeui.config")
  cfg.options.view = (cfg.options.view == "single" and "triple" or "single")
  local cur = M.get_state()
  if cur.active and cur.middle_buf and vim.api.nvim_buf_is_valid(cur.middle_buf) then
    local buf = cur.middle_buf
    local file = vim.api.nvim_buf_get_name(buf)
    M.close()
    vim.schedule(function() require("mergeui").open(buf) end)
    vim.notify("MergeUI view: " .. cfg.options.view, vim.log.levels.INFO)
    return cfg.options.view
  else
    vim.notify("MergeUI view set to " .. cfg.options.view .. " (next :MergeUI will use it)", vim.log.levels.INFO)
    return cfg.options.view
  end
end

function M.close()
  if not state.active then return end
  -- prevent re-entrancy during :q
  if state._closing then return end
  state._closing = true
  for _, w in ipairs({ state.left_win, state.right_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  if state.left_buf and vim.api.nvim_buf_is_valid(state.left_buf) then
    vim.api.nvim_buf_delete(state.left_buf, { force = true })
  end
  if state.right_buf and vim.api.nvim_buf_is_valid(state.right_buf) then
    vim.api.nvim_buf_delete(state.right_buf, { force = true })
  end
  for _, w in ipairs({ state.middle_win, state.left_win, state.right_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_set_option, w, "scrollbind", false)
      pcall(vim.api.nvim_win_set_option, w, "cursorbind", false)
    end
  end
  if state.middle_buf and vim.api.nvim_buf_is_valid(state.middle_buf) then
    M.clear_indicators(state.middle_buf)
  end
  state.active = false
  state._closing = false
  state.conflicts = {}
  state.active_conflict = 1
  if state.middle_win and vim.api.nvim_win_is_valid(state.middle_win) then
    vim.api.nvim_set_current_win(state.middle_win)
  end
end

-- Re-parse after edits (side buffers are unchanged, so re-resolve the
-- remaining conflicts' positions in them and repaint side highlights).
function M.refresh()
  if not state.middle_buf or not vim.api.nvim_buf_is_valid(state.middle_buf) then
    M.close()
    return
  end
  state.conflicts = parser.parse(state.middle_buf)
  state.active_conflict = math.max(1, math.min(state.active_conflict or 1, math.max(1, #state.conflicts)))
  if #state.conflicts == 0 then
    vim.notify("RubymineMerge: All conflicts resolved!", vim.log.levels.INFO)
    M.render_indicators()
    -- optionally auto-close? keep open until user quits
  else
    if state.left_buf and vim.api.nvim_buf_is_valid(state.left_buf)
      and state.right_buf and vim.api.nvim_buf_is_valid(state.right_buf) then
      local ok_l, left_lines = pcall(vim.api.nvim_buf_get_lines, state.left_buf, 0, -1, false)
      local ok_r, right_lines = pcall(vim.api.nvim_buf_get_lines, state.right_buf, 0, -1, false)
      if ok_l and ok_r then
        local l_ranges, r_ranges = resolve_stage_positions(left_lines, right_lines, state.conflicts)
        state._left_hl_ranges, state._right_hl_ranges = l_ranges, r_ranges
        paint_side(state.left_buf, l_ranges, "RubymineCurrentLine")
        paint_side(state.right_buf, r_ranges, "RubymineIncomingLine")
      end
    end
    M.render_indicators()
  end
end

return M
