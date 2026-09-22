# Initial validation

Validated on macOS arm64 with Neovim 0.11.2 on 2026-09-14.

`make test` passes 75 cases: actual temporary Git repositories, source mapping,
context expansion, window lifecycle, cancellation, cache pressure, Unicode/tab
selection, syntax scheduling, and Sidekick comment capture. The optional Sidekick
integration used the local fork's actual preview/draft/render pipeline with its
transport stubbed; no messages were sent.

The companion Neovim configuration passes 31 assertions, including Lazy's actual
key merge logic and inclusive commit-picker ranges. A separate smoke check uses
real Lazy setup, local plugin loading, a real Git commit, split layout and close.

Terminal validation uses a real BrowserOS commit in a 190-column Neovim UI with
Gruvbox Baby and installed parsers. It covers unified and split painting, file
focus, full-file context expansion, returning to the stream, and opening source
at its true revision/line.

## Performance samples

Three runs per fixture with syntax enabled and disabled, using real temporary
Git repositories and native Neovim buffers/windows. These numbers measure
headless materialization and event-loop responsiveness, not terminal pixel paint.

| Fixture | Initial load | Layout toggle | Full-file expansion |
| --- | --- | --- | --- |
| 100 files, 400 source lines each, 7,700 compact rows | ~59 ms | 4–6 ms median | 4–10 ms for one file |
| One 10,000-line file, 100 replacements | ~36 ms | ~11 ms median with the full file expanded | 12–27 ms |

The largest observed event-loop heartbeat gap was 21.4 ms. Full syntax is skipped
for the 10,000-line source under the initial 3,000-line/256 KiB limit; at that
time both line and intraline colors remained available. Intraline computation
and painting were subsequently removed for readability. Capture workers cross
real timer turns.

These fixtures establish an initial baseline, not a latency guarantee for every
repository, grammar, filesystem or terminal. Projection still materializes the
retained compact patch synchronously; unusually large reviews use the configured
patch/source budgets and metadata placeholders.

The rendering follow-up raises default syntax coverage to readable-source limits.
The earlier syntax-enabled timings above therefore describe the initial cutoff,
not full parsing of the 10,000-line fixture. The attached-terminal regression now
checks actual RGB backgrounds, full-width header bands, and delayed syntax paint;
it fails on the original ephemeral line highlighting and ordinary-redraw paths.

## Readability regression

The attached-terminal regression uses dim comments from a Gruvbox Baby-like
palette and inspects actual rendered cells. Before the fix it failed on
character-level background patches; after removing those overlays it failed on
comment contrast. It now checks uniform changed-line backgrounds, comments at
least 4.5:1 against those backgrounds, preserved comment styles, unchanged global
capture groups, and visible delayed syntax. It repeats across unified/split
layouts and a live dark-to-light ColorScheme change, reusing cached captures.
