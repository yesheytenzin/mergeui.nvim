if vim.g.loaded_mergeui == 1 then return end
vim.g.loaded_mergeui = 1

-- Auto-setup with defaults if user didn't call setup()
-- User can still override via require("mergeui").setup({...})
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    local ok, mod = pcall(require, "mergeui")
    if ok and not vim.g.mergeui_setup_done then
      -- don't auto-setup yet, let lazy handle it; just ensure commands exist
      -- Setup will be called lazily on first :MergeUI if needed
    end
  end,
  once = true,
})

-- Lazy command creation: if setup hasn't run, create placeholder commands that setup then delegate
local function ensure_setup()
  if vim.g.mergeui_setup_done ~= 1 then
    local ok, m = pcall(require, "mergeui")
    if ok and m.setup then m.setup({}) end
  end
end

vim.api.nvim_create_user_command("MergeUI", function(opts)
  ensure_setup()
  require("mergeui").open()
end, { desc = "Open RubyMine-style 3-pane merge" })

vim.api.nvim_create_user_command("MergeUIClose", function()
  ensure_setup()
  require("mergeui.ui").close()
end, { desc = "Close RubyMine merge view" })

for _, cmd in ipairs({ "TakeLeft", "TakeRight", "TakeBoth", "TakeNone" }) do
  local choice = cmd:gsub("Take", ""):lower() -- left/right/both/none
  pcall(vim.api.nvim_create_user_command, "MergeUI" .. cmd, function()
    ensure_setup()
    local m = require("mergeui")
    if m._apply then m._apply(choice) end
  end, { desc = "MergeUI " .. choice })
end
