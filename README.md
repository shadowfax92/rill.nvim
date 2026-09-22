# Rill

A native Git review surface for Neovim. Read changed files in one continuous
unified diff, switch to side-by-side with **gs**, or focus one file with **gf**.
Layout and file focus are independent.

Rill is a read-only review document. **Enter** opens the corresponding source:
worktree lines open the editable file, while historical and index lines open a
read-only snapshot. Source paths, revisions, and line numbers stay attached to
the code across layout changes, context expansion, and Sidekick selections.

Requires **Neovim 0.11+** and **Git**. There are no required Lua dependencies.
Installed Tree-sitter parsers provide optional syntax highlighting; Sidekick is
an optional integration.

## Install

With lazy.nvim:

```lua
return {
  {
    "shadowfax92/rill.nvim",
    main = "rill",
    cmd = { "Rill", "RillClose", "RillToggle", "RillFocus", "RillRefresh" },
    opts = {},
    keys = {
      { "<leader>gd", "<cmd>Rill<cr>", desc = "Review working changes" },
      { "<leader>gD", "<cmd>Rill branch<cr>", desc = "Review branch changes" },
    },
  },
}
```

For local development, add `dir` to the plugin spec. This prefers a checkout
when present and otherwise installs from GitHub:

```lua
dir = vim.fn.isdirectory(vim.fn.expand("~/code/side-projects/rill.nvim")) == 1
  and vim.fn.expand("~/code/side-projects/rill.nvim") or nil,
```

Open `:Rill`: **Tab / Shift-Tab** move between files, **gs** switches layout,
and **gf** focuses a file. The top bar keeps these actions and context/source
shortcuts visible; **g?** opens the full key list.

The companion personal Neovim configuration also supplies an asynchronous
Telescope commit picker: `<leader>go` for the last 50 commits, `<leader>gO` for all
ancestors of HEAD, and Tab to mark an inclusive commit range. It retains Diffview
for history and exposes its working diff at `<leader>gV`. These global mappings
belong to that configuration; Rill itself installs only review-buffer mappings.

## Comparisons

| Command | Comparison |
| --- | --- |
| `:Rill` or `:Rill working` | HEAD → files on disk, including untracked files |
| `:Rill staged` | HEAD → index |
| `:Rill unstaged` | Index → files on disk, including untracked files |
| `:Rill branch [base]` | Merge base of base and HEAD → HEAD |
| `:Rill commit [rev]` | First parent → commit; defaults to HEAD |
| `:Rill range <base> <head>` | Base snapshot → head snapshot |
| `:Rill A..B` | Same direct snapshot comparison |
| `:Rill A...B` | Merge base of A and B → B |
| `:Rill <rev>` | Shorthand for `:Rill commit <rev>` |

Append `--split` or `--unified` to choose the initial layout. Append
`-- path/to/file another/path` to restrict the comparison to literal repository-relative paths (files or directories).

Branch mode chooses `origin/HEAD`, then local `main`, then local `master` when no
base is supplied. Specify a base for stacked branches or another upstream.
Branch and revision comparisons exclude uncommitted work. Working comparisons
read disk, so save buffer edits first. Root commits and unborn repositories use
an empty-tree baseline where applicable.

## Reviewing

| Key | Action |
| --- | --- |
| `Tab` / `Shift-Tab` | Next / previous file, including in file focus |
| `gs` | Toggle unified / split, preserving source position |
| `gf` | Focus current file / return to the stream |
| `Enter` | Open source; expand a gap; select a tree file or directory |
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous hunk |
| `zo` / `zB` | Reveal context from the top / bottom of a gap |
| `zO` | Reveal the whole gap |
| `zR` | Reveal the entire current file |
| `zM` | Collapse that file's unchanged context |
| `za` | Collapse / expand the current file's body |
| `gT` | Hide / show the file tree |
| `gw` | Toggle wrapping in unified mode |
| `gr` | Refresh from Git |
| `g?` | Show key help |
| `q` | Close the review |

Diffs use a subtle full-line tint with stronger `+` / `−` gutters. Code keeps its
syntax colors without character-level patches or extra bolding. Dim comments use
Rill-only highlight copies targeting 4.5:1 contrast against unchanged, added, and
deleted lines; your theme's source-buffer highlights remain unchanged. Both
layouts share this styling, which updates when you change colorschemes.

Each file owns its context expansion. Expanding a file in the stream moves later
files down; focusing it preserves that expansion. Split mode remains unwrapped
so paired rows stay aligned.

Code is ordinary scratch-buffer text: motions, visual selection, `/` and `?`,
and copying work normally. Gutter numbers and change signs are decorations.
**Search covers materialized text only**; expand hidden context before searching
it. The gutter shows source line numbers, which differ from review-buffer rows.

## Sidekick

With `sidekick = true` (the default), Rill adds these buffer-local mappings:

| Key | Action |
| --- | --- |
| `<leader>ai` / `<leader>aI` | Comment with relative / absolute source paths |
| `<leader>al` / `<leader>aL` | Send source lines with relative / absolute paths |
| `<leader>af` / `<leader>aF` | Send file paths only |
| `<leader>at` | Send the current line or selection |
| `<leader>av` / `<leader>ax` | Send to Claude / Codex without taking focus |

Sidekick is loaded only when a send mapping is invoked. Comment popups require
a Sidekick version exposing `send_with_comment`, as the local
`shadowfax-sidekick.nvim` fork does. Set `sidekick = false` to omit these mappings.

Selections resolve to **source paths and source line ranges**, not display rows.
Deleted code identifies its old revision and old path; new code identifies its
new revision or worktree/index side. Mixed selections become separate spans for
each file, side, and contiguous range. Headers, gaps, and split padding do not
invent source locations. Code and locations are captured before the comment
popup opens, keeping its preview, draft, and eventual message consistent even if
the review refreshes. Historical source buffers opened with Enter retain these
mappings and addresses after the review closes. No Sidekick core changes are required.

## Configuration and API

```lua
require("rill").setup({
  layout = "unified",
  tree_width = 30,
  context_step = 20,
  wrap = false, -- unified only
  syntax = true,
  syntax_max_lines = 100000,
  syntax_max_bytes = 1024 * 1024,
  sidekick = true,
  max_file_bytes = 1024 * 1024,
  max_changed_lines = 20000,
  max_patch_bytes = 16 * 1024 * 1024,
  source_cache_bytes = 32 * 1024 * 1024,
})

local rill = require("rill")
rill.open_working({ cwd = "/path/to/repository" })
rill.open_staged()
rill.open_unstaged()
rill.open_branch({ base = "origin/main" })
rill.open_commit("HEAD~2")
rill.open_range("main", "HEAD", { layout = "split", paths = { "src" } })
```

Open functions return a session immediately while Git loads asynchronously.
`toggle()`, `focus()`, `refresh()`, `close()`, and `current()` operate on the
current review tab. Their command equivalents are `:RillToggle`, `:RillFocus`,
`:RillRefresh`, and `:RillClose`.

For another integration, use `require("rill").context(ctx)` to translate a
captured buffer position or selection into `{ root, file, spans }`. Each span
contains the exact path, revision, side, source line range, byte columns, and
selected text. See `:help rill-context` for the coordinate contract and
[docs/architecture.md](docs/architecture.md) for internal module boundaries.

## Performance and current scope

Git processes and source reads are asynchronous and cancellable. Syntax is
parsed from the full old/new sources, then cached captures are projected only
onto visible review rows. Capture indexing yields between batches. The source
cache has a 32 MiB target; visible and explicitly expanded files can pin data
above that target. Layout changes reuse the review document.

Per-file source and patch reads default to 1 MiB, changed lines to 20,000 per
file, and retained patches to 16 MiB per review. Full-source reads also have a
100,000-line ceiling. Syntax defaults match these readable-source limits, so a
large readable file can finish highlighting instead of stopping at a separate
small-file cutoff. Captures repaint as soon as indexing completes. Lower
`syntax_max_lines` / `syntax_max_bytes` if you prefer stricter parser latency.
Syntax caps captures at 100,000 per side.

Binary files, submodules, file-type changes, unresolved conflicts, and oversized
changes remain visible as explanatory entries. Large generated files receive
the same size limits as other files. There is no binary renderer, merge-conflict
editor, staging action, persistent review-thread store, or editing inside the
review document. Refresh is explicit with `gr`.

## Development

```sh
make test
# Optional: point integration tests at a Sidekick checkout.
RILL_SIDEKICK_PATH=/path/to/sidekick.nvim make test
```

With tmux available, the suite also starts an isolated real terminal UI to check
painted diff backgrounds and delayed syntax without scrolling.

Tests cover real temporary Git repositories, source mapping, layouts and
expansion, cancellation, syntax, and Sidekick capture without real delivery.
MIT licensed. Inspired by Hunk and Pierre's diffs.
