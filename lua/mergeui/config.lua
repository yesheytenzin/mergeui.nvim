local M = {}

M.defaults = {
  -- view: "triple" = 3 panes | CURRENT | RESULT | INCOMING | (RubyMine), "single" = only RESULT (middle)
  view = "triple", -- "triple" or "single"
  layout = "vertical", -- deprecated: use view; kept for backward compat ("vertical"=triple, "horizontal"=single)
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
  opts = opts or {}
  -- backward compat: layout "vertical" -> view "triple", "horizontal" -> "single"
  if opts.view == nil and opts.layout ~= nil then
    if opts.layout == "horizontal" or opts.layout == "single" then opts.view = "single"
    elseif opts.layout == "vertical" or opts.layout == "triple" then opts.view = "triple" end
  end
  -- also support panels = 1 or 3
  if opts.view == nil and opts.panels ~= nil then
    opts.view = (opts.panels == 1 and "single" or "triple")
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- normalize
  if M.options.view ~= "single" and M.options.view ~= "triple" then M.options.view = "triple" end
end

return M
