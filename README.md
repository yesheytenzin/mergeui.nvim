# mergeui.nvim

RubyMine / IntelliJ style **3-pane merge conflict resolver** for Neovim.

```
┌─────────────────┬─────────────────┬─────────────────┐
│  CURRENT (Yours)│  RESULT (center)│ INCOMING (Theirs)│
│  read-only      │  >>  <<  X  B   │  read-only      │
│                 │  editable final │                 │
│   yours code    │  <<<<<<< HEAD   │   theirs code   │
│   blue          │  =======        │   green         │
│                 │  >>>>>>> branch │                 │
└─────────────────┴─────────────────┴─────────────────┘
      >> take left      X dismiss    << take right
```

Like RubyMine / IntelliJ: **Left = CURRENT/Yours (`:2:`) | Middle = RESULT (editable) | Right = INCOMING/Theirs (`:3:`)** with `>>` `<<` `X` indicators and keybinds. Works for any language, not just Ruby.

> **Formerly `rubymine-merge.nvim`** — renamed to `mergeui.nvim` for language-agnostic name. Old `require("rubymine-merge")` and `:RubymineMerge` still work as aliases.

## Why `tri-merge` ?

- **tri** = 3 panes, like 3-way merge
- Short, memorable, `lazy.nvim` searchable
- Alternatives considered: `jetmerge.nvim`, `mergeview.nvim`, `threeway.nvim`, `conflict3.nvim` — `tri-merge` won for clarity + SEO

## Features

- **3 vertical splits** like RubyMine — left/right read-only, middle is the file you'll commit
- **Indicators `>>` / `<<` / `X` / `B`** as virtual text on every conflict (like RubyMine gutters)
- **Keybinds** for every action + `]c` / `[c` to jump between conflicts
- Parses `<<<<<<<` / `=======` / `>>>>>>>` markers **and** tries `git show :2:` / `:3:` for accurate left/right buffers
- Synced scrolling (`scrollbind` + `cursorbind`) + highlights

## Install

### lazy.nvim

```lua
{
  "yesheytenzin/mergeui.nvim",
  config = function()
    require("mergeui").setup({
      keymaps = {
        take_left = "<leader>mh",  -- >> take CURRENT
        take_right = "<leader>ml", -- << take INCOMING
        take_both = "<leader>mb",  -- take both
        take_none = "<leader>mx",  -- X dismiss
        next_conflict = "]c",
        prev_conflict = "[c",
        quit = "<leader>mq",
      },
      show_indicators = true,
    })
  end,
  cmd = { "MergeUI", "MergeUIClose" },
}
```

### Manual (no manager)

```lua
vim.opt.rtp:prepend("/path/to/mergeui.nvim")
require("mergeui").setup()
```

## Usage

1. Open a file with merge conflicts (`git merge` / `git rebase` conflict)
2. `:MergeUI` (or `:RubymineMerge` alias) — opens 3 panes
3. Cursor in middle pane:

| Action | Default key | RubyMine indicator | Command |
| -------- | ------------- | ------------------- | --------- |
| Take **left** (CURRENT/Yours) | `<leader>mh` or `gh` | `>>` | `:MergeUITakeLeft` |
| Take **right** (INCOMING/Theirs) | `<leader>ml` or `gl` | `<<` | `:MergeUITakeRight` |
| Take **both** | `<leader>mb` or `gB` | `B` | `:MergeUITakeBoth` |
| **Dismiss** (X) | `<leader>mx` or `gX` | `X` | `:MergeUITakeNone` |
| Next / Prev conflict | `]c` / `[c` | — | — |
| Close merge view | `<leader>mq` | — | `:MergeUIClose` |

Old commands `:RubymineMerge*` are aliases and still work.

## How left/right are filled

1. Tries `git show :2:<file>` (ours) and `:3:<file>` (theirs) — exact like `git mergetool`
2. Falls back to parsing conflict blocks from current buffer if not in a git repo

## Customize highlights

```lua
vim.api.nvim_set_hl(0, "RubymineConflict", { bg = "#3a1a1a", fg = "#ffaaaa" })
vim.api.nvim_set_hl(0, "RubymineIndicator", { fg = "#89b4fa", bold = true })
vim.api.nvim_set_hl(0, "RubymineIndicatorRight", { fg = "#a6e3a1", bold = true })
vim.api.nvim_set_hl(0, "RubymineIndicatorX", { fg = "#f38ba8", bold = true })
```

## License

MIT
