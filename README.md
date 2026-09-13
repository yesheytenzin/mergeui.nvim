# mergeui.nvim

RubyMine-style **3-pane merge resolver** for Neovim — `CURRENT | RESULT | INCOMING`.

```
┌─────────────────┬─────────────────┬─────────────────┐
│  CURRENT (Yours)│  RESULT (center)│ INCOMING (Theirs)│
│  read-only      │  editable final │  read-only      │
└─────────────────┴─────────────────┴─────────────────┘
```

`Left = :2: (Yours)` · `Middle = RESULT` · `Right = :3: (Theirs)`

## Install (lazy.nvim)

```lua
{ "yesheytenzin/mergeui.nvim", config = function() require("mergeui").setup() end, cmd = { "MergeUI", "MergeUIClose" } }
```

<details><summary>with keymaps</summary>

```lua
require("mergeui").setup({
  keymaps = {
    take_left = "<leader>mh", take_right = "<leader>ml",
    take_both = "<leader>mb", take_none = "<leader>mx",
    next_conflict = "]c", prev_conflict = "[c", quit = "<leader>mq",
  },
})
```

</details>

## Usage

`:MergeUI` — picker · `:MergeUI <file>` — 3-pane view

| Action | Key | Command |
| ------ | --- | ------- |
| Take left (CURRENT) | `<leader>mh` | `:MergeUITakeLeft` |
| Take right (INCOMING) | `<leader>ml` | `:MergeUITakeRight` |
| Take both | `<leader>mb` | `:MergeUITakeBoth` |
| Dismiss | `<leader>mx` | `:MergeUITakeNone` |
| Next / prev conflict | `]c` / `[c` | — |
| Close | `<leader>mq` | `:MergeUIClose` |
| Toggle single/triple | `<leader>mt` | `:MergeUIToggle` |

Buffer labels (`statusline`/`winbar`/action strip) always show your effective keys.

## License

MIT
