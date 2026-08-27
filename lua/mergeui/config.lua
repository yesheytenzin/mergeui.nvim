local M = {}

M.defaults = {
  -- layout: "horizontal" uses 3 vertical splits (RubyMine style)
  -- "vertical" would stack horizontally; keep vertical splits by default
  layout = "vertical", -- vertical splits: | left | middle | right |
  keymaps = {
    take_left = "<leader>mh",   --  >>  (take CURRENT/Yours)
    take_right = "<leader>ml",  --  <<  (take INCOMING/Theirs)
    take_both = "<leader>mb",   -- take both sides
    take_none = "<leader>mx",   -- X - dismiss conflict (take none, keep empty)
    next_conflict = "]c",
    prev_conflict = "[c",
    quit = "<leader>mq",
  },
  -- highlight groups (fallback to Diff* if not defined)
  highlights = {
    current = "DiffAdd",
    incoming = "DiffText",
    conflict = "DiffDelete",
  },
  -- show virtual text indicators (>>, <<, X) like RubyMine
  show_indicators = true,
  -- auto open when file has conflicts on BufRead?
  auto_open = false,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
