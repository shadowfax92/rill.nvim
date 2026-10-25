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
- **Sidekick-aware**: selections send exact source paths and lines to your agent

Requires Neovim 0.11+ and Git. No Lua dependencies.

## Install

lazy.nvim:

```lua
{
  "shadowfax92/rill.nvim",
  main = "rill",
  cmd = { "Rill", "RillClose", "RillToggle", "RillFocus", "RillRefresh" },
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
| `:Rill commit [rev]` | parent → commit |
| `:Rill A..B` / `:Rill A...B` | A → B / merge base → B |
| `:Rill commits A B C` | several commits, combined when contiguous |

| Key | Action |
| --- | --- |
| `Tab` / `S-Tab` | next / previous file |
| `]c` / `[c` | next / previous hunk |
| `gs` | unified ↔ split |
| `gf` | focus the file |
| `gm` | combined ↔ per commit |
| `Enter` | open the source line, or expand hidden context |
| `g?` | every key |
| `q` | close |

Options, the Lua API and Sidekick details are in `:help rill`; internals in
[docs/architecture.md](docs/architecture.md).

## License

MIT. Inspired by Hunk and Pierre's diffs.
