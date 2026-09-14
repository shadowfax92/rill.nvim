# Rill

A native Git review surface for Neovim. Read changed files in one continuous
unified diff, switch to side-by-side with **Tab**, or focus one file with **gf**.
Layout and file focus are independent.

Rill is a read-only review document. **Enter** opens the corresponding source:
worktree lines open the editable file, while historical and index lines open a
read-only snapshot. Source paths, revisions, and line numbers stay attached to
the code across layout changes, context expansion, and Sidekick selections.

Requires **Neovim 0.11+** and **Git**. There are no required Lua dependencies.
Installed Tree-sitter parsers provide optional syntax highlighting; Sidekick is
an optional integration.

## Try the local checkout

This checkout can be used immediately; a published GitHub repository is not
required. With lazy.nvim:

```lua
return {
  {
    name = "rill.nvim",
    dir = vim.fn.expand("~/code/side-projects/rill.nvim"),
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

Open `:Rill`, then try **Tab**, **gf**, **zR**, and **g?**.

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
| `Tab` | Toggle unified / split, preserving source position |
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
  syntax_max_lines = 3000,
  syntax_max_bytes = 256 * 1024,
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
100,000-line ceiling. Syntax indexing independently skips sources above 3,000
lines or 256 KiB by default and caps capture spans at 100,000 per side. Intraline highlighting
skips paired lines longer than 1,000 bytes. The syntax limits keep Neovim’s native
parser from delaying input on large files; increasing them trades responsiveness
for full syntax coverage.

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

Tests cover real temporary Git repositories, source mapping, layouts and
expansion, cancellation, syntax, and Sidekick capture without real delivery.
MIT licensed. Inspired by Hunk and Pierre's diffs.
