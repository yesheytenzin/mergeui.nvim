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
- **Conflict-aware sync** — all three panes centre on the same conflict on `]c`/`[c`, on take actions, and when the cursor enters a conflict in RESULT (`auto_follow`). No plain `scrollbind` — the three revisions have different line counts, so equal toplines would show different code.
- **Live key labels** — the middle `statusline`, the side `winbar`s (`mh/gh >> RESULT` / `RESULT << ml/gl`), and the per-conflict action strip always show your **effective** keys. Custom `setup({ keymaps = ... })` overrides appear automatically; `gh`/`gl`/`gB`/`gX` are always-mapped aliases so the `/gh` part is always valid.

## Install

### lazy.nvim

```lua
{
  "yesheytenzin/mergeui.nvim",
  config = function()
    require("mergeui").setup({
      view = "triple", -- "triple" (3 panes) | "single" (RESULT only)
      keymaps = {
        take_left = "<leader>mh",  -- >> take CURRENT (also gh)
        take_right = "<leader>ml", -- << take INCOMING (also gl)
        take_both = "<leader>mb",  -- take both (also gB)
        take_none = "<leader>mx",  -- X dismiss (also gX)
        next_conflict = "]c",
        prev_conflict = "[c",
        quit = "<leader>mq",
      },
      show_indicators = true,
      sync_sides = true,   -- keep CURRENT/RESULT/INCOMING on the same conflict
      auto_follow = true,  -- moving into a conflict in RESULT recentres the sides
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
2. `:MergeUI` (or `:RubymineMerge` / `:TriMerge` alias) — with no arg opens the conflict picker; `:MergeUI <file>` jumps straight to that file's 3-pane view
3. Resolve in any pane — the same buffer-local keymaps are set on CURRENT, RESULT and INCOMING so global `gl` (diagnostics) etc. don't steal them:

| Action | Default keys (what the buffer actually shows) | RubyMine indicator | Command |
| -------- | ------------- | ------------------- | --------- |
| Take **left** (CURRENT/Yours) | `<leader>mh` / `gh` — shown as `mh/gh` | `>>` | `:MergeUITakeLeft` |
| Take **right** (INCOMING/Theirs) | `<leader>ml` / `gl` — shown as `ml/gl` | `<<` | `:MergeUITakeRight` |
| Take **both** | `<leader>mb` / `gB` — shown as `mb/gB` | `B` | `:MergeUITakeBoth` |
| **Dismiss** (X) | `<leader>mx` / `gX` — shown as `mx/gX` | `×` | `:MergeUITakeNone` |
| Next / Prev conflict | `]c` / `[c` | — | — |
| Close merge view | `<leader>mq` — shown as `mq Quit` (+ live `N conflicts` count) | — | `:MergeUIClose` |
| Toggle single/triple view | `<leader>mt` (`<leader>m1` single / `<leader>m3` triple) | — | `:MergeUIToggle` / `:MergeUISingle` / `:MergeUITriple` |

What you see is what works:

- **Middle `statusline`:** `mh/gh Current  ml/gl Incoming  mb/gB Both  mx/gX Discard  ]c/[c  mq Quit  2 conflicts` (keys + live count).
- **Side `winbar`s:** `mh/gh >> RESULT` on the left, `RESULT << ml/gl` on the right.
- **Per-conflict action strip:** `1/2  >> CURRENT mh/gh  × DISCARD mx/gX  << INCOMING ml/gl  BOTH mb/gB` above each `<<<<<<<`.

If you override any `setup({ keymaps = { take_left = "<C-h>" } })`, every label updates to `<C-h>/gh` etc. — the README table and the buffer never drift.

Old commands `:RubymineMerge*` / `:TriMerge*` are aliases and still work. Active-session `:wq` expands to `:MergeUIWriteQuit` (write RESULT and return to the picker); plain `:w` keeps the 3 panes open; plain `:q` closes the layout.

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
