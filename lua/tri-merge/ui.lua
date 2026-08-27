local config = require("tri-merge.config")
local parser = require("tri-merge.parser")

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
  active = false,
}

function M.get_state() return state end

local function ensure_hl()
  -- Exact RubyMine Darcula 3-way colors
  vim.api.nvim_set_hl(0, "RubymineCurrent", { bg = "#2e3440", fg = "#d8dee9", default = true }) -- left pane base
  vim.api.nvim_set_hl(0, "RubymineIncoming", { bg = "#2e3440", fg = "#d8dee9", default = true }) -- right pane base
  vim.api.nvim_set_hl(0, "RubymineResult", { bg = "#3b4252", fg = "#eceff4", default = true }) -- center pane active
  vim.api.nvim_set_hl(0, "RubymineConflict", { bg = "#4a2a2a", fg = "#ffcccc", default = false }) -- ruby red conflict block like RubyMine
  vim.api.nvim_set_hl(0, "RubymineCurrentLine", { bg = "#3a4a6a", fg = "#88c0d0", default = true }) -- blue left diff
  vim.api.nvim_set_hl(0, "RubymineIncomingLine", { bg = "#3a4a3a", fg = "#a3be8c", default = true }) -- green right diff
  vim.api.nvim_set_hl(0, "RubymineIndicator", { fg = "#88c0d0", bg = "#3b4252", bold = true, default = true }) -- >> blue
  vim.api.nvim_set_hl(0, "RubymineIndicatorRight", { fg = "#a3be8c", bg = "#3b4252", bold = true, default = true }) -- << green
  vim.api.nvim_set_hl(0, "RubymineIndicatorX", { fg = "#bf616a", bg = "#3b4252", bold = true, default = true }) -- X red
  vim.api.nvim_set_hl(0, "RubymineArrow", { fg = "#81a1c1", bold = true, default = true })
  vim.api.nvim_set_hl(0, "RubymineArrowRight", { fg = "#a3be8c", bold = true, default = true })
  vim.api.nvim_set_hl(0, "RubymineWinbar", { bg = "#434c5e", fg = "#eceff4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "RubymineWinbarNC", { bg = "#3b4252", fg = "#88c0d0", default = true })
end

function M.clear_indicators(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

-- Add >> / << / X virtual text indicators like RubyMine
function M.render_indicators()
  if not config.options.show_indicators then return end
  ensure_hl()
  for _, bufnr in ipairs({ state.middle_buf, state.left_buf, state.right_buf }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      M.clear_indicators(bufnr)
    end
  end

  for idx, c in ipairs(state.conflicts) do
    -- Middle: RubyMine gutter exactly: header + 3 clickable icons in signcolumn + virt_text
    if state.middle_buf and vim.api.nvim_buf_is_valid(state.middle_buf) then
      local virt = {
        { string.format("  Conflict %d/%d  ", idx, #state.conflicts), "RubymineConflict" },
        { "  ", "Comment" },
        { " >> ", "RubymineIndicator" }, -- RubyMine blue chevron (Yours -> Result)
        { " ", "Comment" },
        { " X ", "RubymineIndicatorX" }, -- RubyMine red X
        { " ", "Comment" },
        { " << ", "RubymineIndicatorRight" }, -- RubyMine green chevron (Theirs -> Result)
        { "  B ", "RubymineIndicator" },
      }
      pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.start - 1, 0, {
        virt_text = virt,
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
      -- RubyMine signcolumn gutters: >> on left edge, X in middle, << on right edge (like IDE)
      pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.start - 1, 0, {
        sign_text = ">>",
        sign_hl_group = "RubymineIndicator",
        priority = 100,
      })
      pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.mid - 1, 0, {
        sign_text = " X",
        sign_hl_group = "RubymineIndicatorX",
        priority = 100,
      })
      pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.finish - 1, 0, {
        sign_text = "<<",
        sign_hl_group = "RubymineIndicatorRight",
        priority = 100,
      })
      -- highlight conflict region exactly like RubyMine red block
      pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.start - 1, 0, {
        end_row = c.finish,
        hl_group = "RubymineConflict",
        hl_eol = true,
      })
      -- line highlights: ours=blue, theirs=green like RubyMine
      pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.start - 1, 0, {
        end_row = c.mid,
        hl_group = "RubymineCurrentLine",
        hl_eol = true,
      })
      pcall(vim.api.nvim_buf_set_extmark, state.middle_buf, ns, c.mid - 1, 0, {
        end_row = c.finish,
        hl_group = "RubymineIncomingLine",
        hl_eol = true,
      })
    end
  end
  -- Side buffers: ONE header per buffer with big pipeline arrow TO MIDDLE (outside loop so not duplicated)
  if state.left_buf and vim.api.nvim_buf_is_valid(state.left_buf) then
    pcall(vim.api.nvim_buf_set_extmark, state.left_buf, ns, 0, 0, {
      virt_text = {
        { "  CURRENT ", "RubymineIndicator" },
        { " ──────►► ", "RubymineArrow" },
        { ">>", "RubymineIndicator" },
        { " ──► Result ", "Comment" },
      },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
    -- RubyMine gutter: single >> chevron in signcolumn per window (not spammed every line)
    pcall(vim.api.nvim_buf_set_extmark, state.left_buf, ns, 0, 0, {
      sign_text = ">>",
      sign_hl_group = "RubymineIndicator",
    })
  end
  if state.right_buf and vim.api.nvim_buf_is_valid(state.right_buf) then
    pcall(vim.api.nvim_buf_set_extmark, state.right_buf, ns, 0, 0, {
      virt_text = {
        { " Result ◄── ", "Comment" },
        { "<<", "RubymineIndicatorRight" },
        { " ◄◄────── ", "RubymineArrowRight" },
        { "INCOMING  ", "RubymineIndicatorRight" },
      },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
    pcall(vim.api.nvim_buf_set_extmark, state.right_buf, ns, 0, 0, {
      sign_text = "<<",
      sign_hl_group = "RubymineIndicatorRight",
    })
  end
end

function M.create_buffers(filepath, middle_bufnr)
  local git = require("tri-merge.git")
  local stage = git.get_stage_versions(filepath)

  local conflicts = parser.parse(middle_bufnr)
  state.conflicts = conflicts

  -- Left: ours, Right: theirs
  local left_lines, right_lines
  if stage and stage.ours and stage.theirs then
    left_lines = vim.split(stage.ours, "\n")
    right_lines = vim.split(stage.theirs, "\n")
  else
    -- fallback: build from parsed conflicts to simulate RubyMine base
    -- For fallback we reconstruct files by taking ours/theirs selections
    local all = vim.api.nvim_buf_get_lines(middle_bufnr, 0, -1, false)
    -- left = replace each conflict with ours
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
          for _, l in ipairs(c_idx.ours) do table.insert(left_lines, l) end
          for _, l in ipairs(c_idx.theirs) do table.insert(right_lines, l) end
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

  state.left_buf = vim.api.nvim_create_buf(false, true)
  state.right_buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(state.left_buf, 0, -1, false, left_lines)
  vim.api.nvim_buf_set_lines(state.right_buf, 0, -1, false, right_lines)

  local ft = vim.bo[middle_bufnr].filetype
  vim.bo[state.left_buf].filetype = ft
  vim.bo[state.right_buf].filetype = ft
  vim.bo[state.left_buf].modifiable = false
  vim.bo[state.right_buf].modifiable = false
  vim.api.nvim_buf_set_name(state.left_buf, "CURRENT (Yours) - " .. filepath)
  vim.api.nvim_buf_set_name(state.right_buf, "INCOMING (Theirs) - " .. filepath)
  return left_lines, right_lines
end

function M.open_layout(middle_bufnr, filepath)
  ensure_hl()
  state.middle_buf = middle_bufnr
  state.middle_win = vim.api.nvim_get_current_win()

  M.create_buffers(filepath, middle_bufnr)

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
  vim.wo[state.left_win].signcolumn = "yes:1"
  vim.wo[state.left_win].foldcolumn = "0"
  vim.api.nvim_win_set_option(state.left_win, "winhl", "Normal:RubymineCurrent,SignColumn:RubymineCurrent,CursorLine:RubymineCurrentLine")

  -- go back to middle (Result)
  vim.api.nvim_set_current_win(state.middle_win)
  -- right split (Theirs)
  vim.cmd("rightbelow vsplit")
  state.right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.right_win, state.right_buf)
  vim.wo[state.right_win].number = false
  vim.wo[state.right_win].cursorline = true
  vim.wo[state.right_win].winfixwidth = false
  vim.wo[state.right_win].signcolumn = "yes:1"
  vim.wo[state.right_win].foldcolumn = "0"
  vim.api.nvim_win_set_option(state.right_win, "winhl", "Normal:RubymineIncoming,SignColumn:RubymineIncoming,CursorLine:RubymineIncomingLine")

  -- middle (Result) - editable, centered like RubyMine
  vim.api.nvim_set_current_win(state.middle_win)
  vim.wo[state.middle_win].number = false
  vim.wo[state.middle_win].cursorline = true
  vim.wo[state.middle_win].winfixwidth = false
  vim.wo[state.middle_win].signcolumn = "yes:2"
  vim.wo[state.middle_win].foldcolumn = "0"
  vim.api.nvim_win_set_option(state.middle_win, "winhl", "Normal:RubymineResult,SignColumn:RubymineResult,CursorLine:Visual")

  -- FORCE 3 EQUAL COLUMNS like RubyMine (33% / 33% / 33%) — this was missing, caused uneven widths
  vim.o.equalalways = true
  vim.o.eadirection = "hor"
  vim.cmd("wincmd =")
  local total = vim.o.columns
  local w = math.floor((total - 4) / 3) -- -4 for separators
  pcall(vim.api.nvim_win_set_width, state.left_win, w)
  pcall(vim.api.nvim_win_set_width, state.middle_win, w)
  pcall(vim.api.nvim_win_set_width, state.right_win, w)
  vim.cmd("wincmd =") -- re-equalize after explicit widths

  -- titles + winbar 1:1 RubyMine header — Yours | Result | Theirs with file tab on top like IDE
  pcall(function()
    local fname = vim.fn.fnamemodify(filepath, ":t")
    -- Top file tab (like RubyMine title bar)
    vim.wo[state.left_win].winbar = "%#RubymineWinbarNC# " .. fname .. "  │  Yours (HEAD)    %#RubymineArrow# ──────►►  %#RubymineIndicator# >> "
    vim.wo[state.middle_win].winbar = "%#RubymineWinbar#  " .. fname .. "  │  Result  %#RubymineIndicatorRight# <<%#RubymineWinbar#  %#RubymineIndicatorX# X %#RubymineWinbar#  %#RubymineIndicator# >> "
    vim.wo[state.right_win].winbar = "%#RubymineIndicatorRight# << %#RubymineArrowRight# ◄◄────── %#RubymineWinbarNC#  Theirs (MERGE_HEAD)  │ " .. fname .. " "
    -- Statusline footer (like RubyMine bottom bar) - keep minimal, show keybinds
    vim.api.nvim_win_set_option(state.left_win, "statusline", "%#RubymineWinbarNC#  Yours  ──►►  %#RubymineIndicator#>>%#RubymineWinbarNC# take  %< " .. fname)
    vim.api.nvim_win_set_option(state.middle_win, "statusline", "%#RubymineWinbar#  %f  %#Comment#  gh:>>  gl:<<  gX:X  %=%#RubymineWinbar# Result ● " .. string.format("%d conflicts", #state.conflicts))
    vim.api.nvim_win_set_option(state.right_win, "statusline", "%#RubymineIndicatorRight#<<%#RubymineWinbarNC#  ◄◄── Theirs  %< " .. fname)
  end)
  -- nicer vertical separators
  pcall(function() vim.opt.fillchars:append({ vert = "│", verthoriz = "┤", horiz = "─", horizup = "┴", horizdown = "┬" }) end)

  -- sync scroll
  for _, w in ipairs({ state.left_win, state.middle_win, state.right_win }) do
    vim.api.nvim_win_set_option(w, "scrollbind", true)
    vim.api.nvim_win_set_option(w, "cursorbind", true)
  end
  vim.cmd("syncbind")

  state.active = true
  M.render_indicators()

  -- keymaps are set in init.lua
  vim.notify(string.format("RubymineMerge: %d conflict(s) — %s / %s / %s  [>> << X]", #state.conflicts, ">>=left", "<<=right", "X=dismiss"), vim.log.levels.INFO)
end

function M.close()
  if not state.active then return end
  for _, w in ipairs({ state.left_win, state.right_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_close(w, true)
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
  state.conflicts = {}
  if state.middle_win and vim.api.nvim_win_is_valid(state.middle_win) then
    vim.api.nvim_set_current_win(state.middle_win)
  end
end

-- Re-parse after edits
function M.refresh()
  if not state.middle_buf or not vim.api.nvim_buf_is_valid(state.middle_buf) then
    M.close()
    return
  end
  state.conflicts = parser.parse(state.middle_buf)
  if #state.conflicts == 0 then
    vim.notify("RubymineMerge: All conflicts resolved!", vim.log.levels.INFO)
    M.render_indicators()
    -- optionally auto-close? keep open until user quits
  else
    M.render_indicators()
  end
end

return M
