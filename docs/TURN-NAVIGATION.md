# Conversation turn navigation

The left edge of each native/Kimi transcript shows a compact index of loaded
user turns. Hover to read the question and latest response excerpt; click to
jump to the question. Up/Down and accessibility increment/decrement move one
turn at a time. Escape dismisses keyboard focus. The dark tick tracks the turn
at the top of the reading viewport.

The rail is hidden for zero or one turn. Dense histories share painted ticks.
After a 120 ms dwell, a fixed neighborhood opens to roughly 18 pt hit targets;
painting and pointer selection use the same mapping. Moving between neighbors
updates excerpts immediately without moving or resizing the card. A 90 ms exit
grace avoids collapsing it when the pointer briefly crosses the edge. Moving
outside the expanded neighborhood and dwelling opens a new neighborhood.
Kimi's existing **Load earlier messages** button expands the indexed history;
the rail does not fetch remote history on hover.

## Rendering contract

- Excerpts are bounded plain text cached by `ConversationProjection` alongside
  each turn. Thinking, tool output, and runtime context are excluded.
- Hover state lives only in the rail. It does not mount or measure transcript
  rows, parse Markdown, or call a provider.
- The native document maps stable entry IDs to its existing virtual geometry.
  Selecting a turn pauses follow mode and directly reveals its row. Existing
  Return-to-latest behavior resumes following.
- Selection feedback is published before deferred row mounting. Pending choices
  coalesce to the latest destination and are cancelled on session replacement.
  A brief border marks the destination question, respecting Reduce Motion.
- Current-turn updates use the coalesced viewport pass and a binary lookup of
  turn starts. Immutable rail inputs keep outgoing views safe when a session
  is replaced or cleared.

## Checks

Build the application with `scripts/build.sh`, then run `WorkbenchChecks` and
`ConnectionChecks`. On the Mac with mixed Command Line Tools interfaces, first
use the existing `scripts/prepare-local-swiftpm.sh` and its printed environment
variable.

```sh
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py turns --output .local/turn-check --switches 2
python3 scripts/run-navigation-check.py search --output .local/turn-search --switches 2
python3 scripts/run-navigation-check.py anchor --output .local/turn-prepend --switches 2
```

The `turns` fixture uses 200 mixed-content turns and checks cold jumps in both
directions, exact question alignment, bounded retained hosts, streaming while
reading history, history prepend, session replacement, and clearing the
conversation. Its layout timings exclude hardware input and compositor
presentation; they are not a frame-rate or Codex performance comparison.

### Local verification, 2026-09-22

On macOS 26.6.2, the release app build/signature, WorkbenchChecks,
ConnectionChecks, localization and publication checks passed. The three native
fixture modes above passed on the rebased implementation (`25a46e6`, based on
`21f03a3`). The six cold jumps took 31–84 ms for synchronous application
layout/display work and retained only 1–7 row hosts. There is no claim of
continuous 60 fps for first-time complex Markdown layout.

Reports are in `.local/turn-navigation-verified`, `.local/search-verified`, and
`.local/prepend-verified`. Live SSH validation was skipped because
`WORKBENCH_LIVE_HOST` was unset. Native fixture results do not certify a real
remote-provider session.

### Interaction polish, 2026-09-22

Rebased on `d72cbcc`. Release build/signature, core and connection checks passed;
the native 200-turn checks also passed for dwell, exit grace, fixed card
position, unchanged mounted/retained hosts on hover, rapid selection
coalescing, session cancellation, jumps, streaming, prepend, and empty state.
Search and history-anchor regression checks passed.

Two short native runs measured 36 neighboring preview switches each. Their
layout/display p95 was 14–16 ms; the second run had one 18 ms sample. Selection
handlers took 0.03–0.11 ms. Destination layout readiness ranged 36–100 ms
across the two runs. This improves immediate input handling and avoids
intermediate jumps; it does **not** establish faster cold Markdown rendering
or end-to-end 60 fps. The timings exclude hardware input and compositor
presentation. Reports live in `.local/turn-polish/after` and
`.local/turn-polish/final`; the baseline is `.local/turn-polish/before`.

Native joint-fixture UI checks also kept turn 94 in view while the stream
advanced from 151 to 277 of 300 updates at 10 Hz. Switching to session B and
back restored turn 94 and its draft; Return-to-latest restored turn 201.
This used local synthetic conversations, not a live remote model.
The expanded rail/card were inspected in the native window; clicking the
expanded tick for turn 105 landed on the question shown in its preview.

For visual inspection, set `NAVIGATION_INSPECT_HOVER=1` when running the `turns`
fixture; it holds the expanded rail and preview in the real window for 30
seconds, outside the measured interaction interval.

### Rendering and visual refinement, 2026-09-22

Cold rows now join their actual window at the committed column width before
SwiftUI measures them. Previously, measuring detached and then attaching rebuilt
the text graph. In the six-jump fixture, Markdown parse counts fell from
`[2, 6, 6, 6, 4, 6]` to `[1, 3, 3, 3, 2, 3]`; attributed-text construction also
halved. This changes mounting order rather than introducing a history cache or
preloading offscreen content.

The `turns` report includes `render_stages` for host creation, host measurement,
Markdown parsing, attributed text, and text measurement. These nested timings
must **not** be added together. Instrumentation is compiled only into fixtures
with `TRANSCRIPT_CHECKS`, not the production application.

The rail now uses rounded ticks: a long dark mark identifies the reading
position, a soft wash identifies hover, and a stronger mark plus keyboard focus
outline confirms selection. Dense neighborhoods receive a subtle width gradient.
Their opacity transitions over 140 ms without per-frame path rebuilding or
moving vertical hit targets. The preview has a solid native background, lighter
border/shadow, and a monospaced turn counter. It fades over 120 ms; neighboring
excerpts update directly at the same position. Reduce Motion disables fades.

Before integration with the newer activity-summary work, baseline/refined runs
on `dd511fd` with 200 mixed-content turns measured:

| Target turn | Baseline ready (ms) | Refined ready (ms) |
| --- | ---: | ---: |
| 200 | 31.1 | 23.1 |
| 1 | 32.8 | 32.0 |
| 101 | 34.3 | 32.5 |
| 7 | 42.5 | 36.6 |
| 199 | 65.7 | 40.2 |
| 51 | 54.4 | 20.0 |

Median readiness was 38.4 → 32.3 ms (16% lower in this small local sample).
Reports and binary hashes are in `.local/navigation-motion/baseline-final` and
`.local/navigation-motion/final-fixed`. An earlier run of the mounting/visual
change had a 21.1 ms median, so timing varies and does not establish a universal
percentage improvement. The halved parse/construction counts were stable.
Preview-switch p95 across final-style runs was 7.8–11.4 ms; the last run had one
17.1 ms sample. These timings exclude hardware input and compositor
presentation; real remote-provider acceptance remains separate.

The wider interaction fixture exposed a pre-existing 3 pt reading-anchor drift
when narrowing the window, reproduced on the baseline. The reader's row and offset are now restored after AppKit finishes its width
adjustment, rather than during measurement where that adjustment overwrites it.
Search text selection, narrow-window position, session return, history prepend,
200-turn navigation with streaming, and workbench/session round trips passed on
the final fixture.

The final release app build/signature, WorkbenchChecks, ConnectionChecks,
localization, and publication checks passed. Live SSH checks were skipped because
`WORKBENCH_LIVE_HOST` was unset. The expanded rail and lighter card were visually
inspected in the native fixture window; this does not certify remote-model use
or mouse-to-photon performance.

Integration base: `091dda6`. Main independently added the same reading-anchor
preservation in its shared height-update path; this branch uses that path and
finishes pending restoration after asynchronous height corrections. Width changes
also capture the reader's position before measurement and restore it on the next
main-queue turn, after the native resize transaction. Session, width, and follow
state checks discard a superseded restoration. The mounting optimization and rail
styling remain unchanged.

Final integration was rebuilt with Xcode 27 / Swift 6.4 after this Mac's toolchain
update. Release build/signature, core and connection checks, and native `turns`,
`interactions`, `anchor`, and `roundtrip` modes passed; reports are under
`.local/navigation-motion/deferred-*` and `xcode-*.log`. Earlier A/B measurements
used Swift 6.3.3 and must not be compared across the toolchain change. Navigation
preview now explicitly builds its core with SwiftPM's native object-file layout,
which its direct linker requires, instead of Xcode 27's new default Products
layout. A throwing setup expression in the newly integrated activity-summary test
was moved before its nonthrowing assertion so the check compiles.
