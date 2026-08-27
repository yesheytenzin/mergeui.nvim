if vim.g.loaded_tri_merge == 1 then return end
vim.g.loaded_tri_merge = 1

-- Auto-setup with defaults if user didn't call setup()
-- User can still override via require("tri-merge").setup({...})
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    local ok, mod = pcall(require, "tri-merge")
    if ok and not vim.g.tri_merge_setup_done then
      -- don't auto-setup yet, let lazy handle it; just ensure commands exist
      -- Setup will be called lazily on first :TriMerge if needed
    end
  end,
  once = true,
})

-- Lazy command creation: if setup hasn't run, create placeholder commands that setup then delegate
local function ensure_setup()
  if vim.g.tri_merge_setup_done ~= 1 then
    local ok, m = pcall(require, "tri-merge")
    if ok and m.setup then m.setup({}) end
  end
end

vim.api.nvim_create_user_command("TriMerge", function(opts)
  ensure_setup()
  require("tri-merge").open()
end, { desc = "Open RubyMine-style 3-pane merge" })

vim.api.nvim_create_user_command("TriMergeClose", function()
  ensure_setup()
  require("tri-merge.ui").close()
end, { desc = "Close RubyMine merge view" })

for _, cmd in ipairs({ "TakeLeft", "TakeRight", "TakeBoth", "TakeNone" }) do
  local choice = cmd:gsub("Take", ""):lower() -- left/right/both/none
  pcall(vim.api.nvim_create_user_command, "TriMerge" .. cmd, function()
    ensure_setup()
    local m = require("tri-merge")
    if m._apply then m._apply(choice) end
  end, { desc = "TriMerge " .. choice })
end
