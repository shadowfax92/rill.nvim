<div align="center">

<img src="assets/rill.svg" width="120" alt="rill">

# rill.nvim

**Native Git review for Neovim.**

[![Neovim 0.11+](https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/built%20with-Lua-2C2D72)](https://www.lua.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

</div>

Read every changed file as one continuous diff, switch to side-by-side with
`gs`, or focus one file with `gf`. `Enter` opens the real line in your working
file, even after later edits.

- **Any comparison**: working tree, staged, branch, one commit, a range, or several commits
- **Unified or split**, with expandable context and Tree-sitter syntax
- **Branch review by commit**: `gm` steps through each commit, merges included
- **History**: `:Rill log` lists recent commits in the sidebar; `Tab` walks them one diff at a time
- **Choose the base**: `gb` searches local and remote branches without leaving the review
- **Sidekick-aware**: selections send exact source paths and lines to your agent

Requires Neovim 0.11+ and Git. No Lua dependencies.

## Install

lazy.nvim:

```lua
{
  "shadowfax92/rill.nvim",
  main = "rill",
  cmd = { "Rill", "RillClose", "RillToggle", "RillFocus", "RillRefresh", "RillBase" },
  opts = {},
  keys = {
    { "<leader>gd", "<cmd>Rill<cr>", desc = "Review working changes" },
    { "<leader>gb", "<cmd>Rill branch<cr>", desc = "Review branch changes" },
  },
}
```

## Usage

| Command | Compares |
| --- | --- |
| `:Rill` | HEAD → working tree, untracked files included |
| `:Rill staged` | HEAD → index |
| `:Rill branch [base]` | branch point → working tree |
| `:RillBase [rev]` | choose or set the current branch review's base |
| `:Rill commit [rev]` | parent → commit |
| `:Rill A..B` / `:Rill A...B` | A → B / merge base → B |
| `:Rill commits A B C` | several commits, combined when contiguous |
| `:Rill log [rev] [-- paths]` | history: one commit at a time, newest first |

| Key | Action |
| --- | --- |
| `Tab` / `S-Tab` | next / previous file |
| `]c` / `[c` | next / previous hunk |
| `gs` | unified ↔ split |
| `gf` | focus the file |
| `gm` | combined ↔ per commit |
| `gb` | choose the branch comparison base |
| `Enter` | open the source line, or expand hidden context |
| `g?` | every key |
| `q` | close |

Branch reviews honor `branch.<name>.gh-merge-base` for stacked work, otherwise
use the remote default branch (usually `origin/main`). Trunk itself keeps its
upstream comparison. The title explains the choice: `(default)`, `(gh-merge-base)`,
`(upstream)`, `(explicit)` or `(picked)`; repositories without a declared/default
base retain a `(guessed)` fallback.

`gb` uses `vim.ui.select`, so your configured picker (such as fzf-lua) supplies
search. Enter updates the same review, Escape cancels, and `gr` follows the
selected ref after a fetch. Use `:RillBase <tag-or-revision>` for other bases.

In Files, `zA` toggles all tree folds; `zM` / `zR` close / open all, and
`zo` / `zc` (`zO` / `zC` recursively) open / close a node. `{` / `}` narrow /
widen the sidebar in five-column steps; manual width survives reopening.
Sidekick send/comment keys work on selected files, folders and commits, using
their full paths and the comparison label even when the sidebar is truncated.

`:Rill log` lists the newest 20 commits in the sidebar and shows the selected
one as a stream under its full message. `Tab` / `S-Tab` move to the older /
newer commit, `]f` / `[f` between its files, and `C-e` (or `Tab` past the last)
loads 20 more. `zA` folds every file to its header (kept as you walk), so
`za` opens only the files you care about; `za` on the message hides bodies;
`--follow` tracks one file
across renames. `require("rill").open_history({ paths = {...} })` does the same
from Lua.

Options, the Lua API and Sidekick details are in `:help rill`; internals in
[docs/architecture.md](docs/architecture.md).

## License

MIT. Inspired by Hunk and Pierre's diffs.
