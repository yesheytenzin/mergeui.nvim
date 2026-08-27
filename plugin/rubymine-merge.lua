if vim.g.loaded_rubymine_merge == 1 then return end
vim.g.loaded_rubymine_merge = 1

-- Auto-setup with defaults if user didn't call setup()
-- User can still override via require("rubymine-merge").setup({...})
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    local ok, mod = pcall(require, "rubymine-merge")
    if ok and not vim.g.rubymine_merge_setup_done then
      -- don't auto-setup yet, let lazy handle it; just ensure commands exist
      -- Setup will be called lazily on first :RubymineMerge if needed
    end
  end,
  once = true,
})

-- Lazy command creation: if setup hasn't run, create placeholder commands that setup then delegate
local function ensure_setup()
  if vim.g.rubymine_merge_setup_done ~= 1 then
    local ok, m = pcall(require, "rubymine-merge")
    if ok and m.setup then m.setup({}) end
  end
end

vim.api.nvim_create_user_command("RubymineMerge", function(opts)
  ensure_setup()
  require("rubymine-merge").open()
end, { desc = "Open RubyMine-style 3-pane merge" })

vim.api.nvim_create_user_command("RubymineMergeClose", function()
  ensure_setup()
  require("rubymine-merge.ui").close()
end, { desc = "Close RubyMine merge view" })

for _, cmd in ipairs({ "TakeLeft", "TakeRight", "TakeBoth", "TakeNone" }) do
  local choice = cmd:gsub("Take", ""):lower() -- left/right/both/none
  pcall(vim.api.nvim_create_user_command, "RubymineMerge" .. cmd, function()
    ensure_setup()
    local m = require("rubymine-merge")
    if m._apply then m._apply(choice) end
  end, { desc = "RubymineMerge " .. choice })
end
