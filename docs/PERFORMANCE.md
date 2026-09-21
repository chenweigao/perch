# Local rendering performance — 2026-09-20

The initial measured implementation exceeded the 3× target on both controlled local
streaming workloads. It subsequently hung during history scrolling; those timings
did not validate scroll liveness. The correction and fresh measurements are below. This is Mac event decode → conversation update → production split and
transcript → AppKit layout/display submission. It does not measure network latency,
remote inference, full workspace startup, terminal rendering, or completed GPU scanout.

| Workload | Baseline events/s | Current events/s | Throughput | Median update | p95 update |
| --- | ---: | ---: | ---: | --- | --- |
| Markdown reply | 30.88 | 144.25 | 4.67× | 30.55 → 6.47 ms | 41.93 → 10.27 ms |
| Thinking | 31.27 | 190.42 | 6.09× | 31.87 → 4.97 ms | 42.03 → 6.65 ms |

Each variant/scenario has two visible-window runs, three trials per run, and 120
events per trial: 720 measured events per variant/scenario. Both variants use the
same 24-turn synthetic Chinese/Markdown history and 760-point reading column.
The content viewport height is 600 points; native sidebar margins change the outer
viewport width from 909 to 902 points without changing text wrapping width.
All trials are included; neither best-trial selection nor dropped/batched events
is used. Baseline and current runs were repeated after switching between variants.

The baseline is commit `5596b6c4184c17f80f7992b11e6f1b8d647e46d8`.
Both versions independently compile their matching Core/UI against identical
Markdown dependencies and compiler. Full reports, individual event timings, source,
fixture and workload hashes are in [the recorded results](performance/2026-09-20-results.json).
Build and rerun with [the fixture instructions](../Tests/PerformancePreview/README.md).

## Changes supported by the measurements

- The root split fills the proposed window size. Its hosting controllers do not
  derive intrinsic window dimensions from the entire conversation. A live sample
  before the change showed recursive AppKit/SwiftUI intrinsic text measurement.
- Transcript rows use stable identities and native lazy layout, so offscreen
  history stays available without being laid out on every token. Per-turn
  projection and per-row/Markdown-block equality preserve unchanged content.
- Collapsed tool and thinking details are constructed only when opened.
- The fixed-height thinking viewport uses native TextKit append and wrapping.
  The three-dot pulse uses Core Animation instead of 10 Hz SwiftUI invalidation.

The supplemental projection-only benchmark (`scripts/benchmark-transcript.sh`)
measured 166.17 → 27.77 ms for 120 tail updates across 1,230 messages (5.98×).
That result is separate from the rendering table above.

## Correctness and visual acceptance

- The final reply's item 120 was visibly rendered, and the thought text retained
  item 120. This check supplements the fixture marker, which by itself cannot prove
  a lazy row was visible. Screenshots also confirmed matching final reply layout.
- The reading fixture loads history 41–60, prepends 21–40 and then 1–20. All 60
  turns remain accessible; scrolling to the earliest messages and returning to
  turn 60 completes without the previous intrinsic-layout hang.
- Narrow Chinese/English thinking wraps inside its fixed viewport. Thinking and
  tool disclosures remain independent from the visible overview.
- A candidate using native text views for every Markdown paragraph was rejected:
  it first exposed a sizing-probe layout defect and, after correction, regressed
  throughput to 0.59× baseline. That candidate was rejected; the later native-text
  refactor below separates measurement from drawing and has fresh measurements.

## Native window design

The toolbar uses `NSToolbar` with `unifiedCompact` and a tracking sidebar separator.
The sidebar uses `NSSplitViewItem(sidebarWithViewController:)`, which supplies system
Liquid Glass on macOS 26. Interactive floating controls use `glassEffect`; older
systems use regular material and Reduce Transparency uses a solid background.
Conversation text and informational titles/status stay on clear, readable surfaces.
This follows [Apple's AppKit design guidance](https://developer.apple.com/videos/play/wwdc2025/310/).


## Earlier scroll correction and measurement (superseded for selection stability)

A production process stayed at 98–100% CPU after history scrolling. All 2,028 main
thread samples stayed in SwiftUI observer/transaction processing, including lazy row
phase changes and `SelectionOverlay → FallbackAlignmentProvider → setFont →
invalidateIntrinsicContentSize`. Remote/JSON/Markdown parsing was not the hot path.

Two issues were separated:

- A lazy transcript nested inside an eager scroll-content stack produced persistent
  blank viewports with a very tall first message. Moving lazy ownership to the direct
  scroll content, and making `ConversationTranscript` supply rows, fixes this while
  retaining virtualization. Both Kimi and OMP/Qoder share that structure.
- Flattening alone still hung after expanding a 37-tool group, opening a tool result,
  scrolling and collapsing it. `ReplyText` supplied fonts only inside attributed runs;
  explicitly supplying its base font appeared to stabilize the selection overlay's
  fallback alignment in that bounded test. A subsequent real hang disproved this
  as a complete fix; see the native text refactor below. The same production path then passed eight result open/close cycles,
  whole-group collapse and repeated up/down scrolling. In a subsequent 2,209-sample
  main-thread capture, 2,020 samples were waiting for events rather than spinning.
  An offline replay of the captured snapshot also passed expand/scroll/collapse.

Rejected controls: eager transcript layout removed the blank viewport but fell to
30.42 events/s on the assistant workload; changing only the default anchor or removing
only paragraph selection did not fix blank rendering. Neither is shipped. Selection,
collapsed tool bodies, per-turn projection and row/block equality are retained.

Fresh benchmark: one visible-window run per variant/scenario, three trials ×120 events
(360 events each), same24-turn workload and760-point reading column. The fixture now
compiles each version's actual scroll-parent structure, not just the transcript child.
All timings are in [the regression reports](performance/2026-09-20-scroll-regression-results.json).

| Workload | Baseline events/s | Corrected events/s | Ratio | Corrected median | Corrected p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Markdown reply | 34.80 | 154.64 | 4.44× | 5.77 ms | 9.79 ms |
| Thinking | 32.70 | 194.08 | 5.94× | 4.32 ms | 8.63 ms |

These remain local decode/apply/layout/display-submission timings, not remote model
speed or a guarantee against every possible UI hang. Scroll acceptance is separate:
60 rich-text turns including a very tall first message, history prepending, repeated
scrolling, returning to the actual final reply, and real tool expansion/collapse.

## Native text and navigation refactor

A later production hang again spent 2,327 of 2,340 main-thread samples in SwiftUI
transaction flushing, including SelectionOverlay/font/intrinsic-size invalidation.
The user requested moving directly to a stability-focused refactor, so further
hang reproduction stopped. Navigation handlers themselves perform no remote fetch.

- Markdown paragraphs, table cells, code, tool bodies and full reasoning text now
  use selectable AppKit NSTextView. SwiftUI SelectionOverlay is absent from the
  transcript. Measurement uses attributed-string bounding rectangles, independent
  of the live TextKit drawing container; Grid probes cannot change displayed wrapping.
- Hosting roots have stable model identity; sidebar/header/actions/detail observe
  their own state instead of replacing all four hosting roots on each publication.
- Dashboard and archive use a direct LazyVStack, with one scoped catalog evaluation
  per body. Archive navigation no longer passes through a transient home state.
- The native detail viewport is constrained/clipped below the toolbar safe area;
  the native sidebar and its glass retain their original window integration.

Fresh current measurements (3 × 120 events for each scenario), compared with the
same recorded baseline/workload, at a 760pt reading width and 600pt viewport height:

| Workload | Baseline events/s | Refactor events/s | Ratio | Refactor median | p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Markdown reply | 34.80 | 108.77 | 3.13× | 8.41 ms | 13.29 ms |
| Thinking | 32.70 | 176.30 | 5.39× | 5.26 ms | 9.44 ms |

[Raw runs and comparisons](performance/2026-09-20-native-text-refactor-results.json).
The outer detail viewport differs by 7pt (909 vs 902); the constrained reading column
and viewport height are identical. The native renderer is slower than the previous
154.64 events/s reply run, but removes the repeatedly observed selection-overlay
path while retaining the original 3× local-throughput target. These are local
streaming measurements, not navigation latency, remote speed, or a hang-free guarantee.


## Recurrence after native text refactor

The production hang after `15082ec` no longer sampled SelectionOverlay or native
text measurement. In a 2,064-sample main-thread capture, 2,033 samples remained in
SwiftUI transaction flushing; 444 directly sampled
`LazyLayoutCacheItem.AllItemsPhaseMutation.apply()`. This invalidates any inference
that the earlier native-text benchmark established scroll stability.

A system `List` candidate removed that lazy placement path, but is **rejected**:
its 60-turn reading fixture made accessibility hierarchy queries occupy the main
thread (`AXCopyHierarchy` / `NSTableViewCellMockElement` / hosting accessibility
children). This is a separate failure from the original layout loop. The final
implementation must not use either transcript LazyVStack or system List.

Profiling the intermediate List stream found 657 of 1,400 main-thread samples
under native attributed-text measurement, despite no sampled content replacement.
A single last-width cache was defeated by alternating sizing proposals. Native
text now retains a bounded set of eight measurements per attributed content,
clearing them only when text or styling changes. Measurements remain independent
of the live drawing container.


## Stable transcript viewport refactor — 2026-09-21

The transcript now uses an eager SwiftUI placement stack with a stable native
hosting controller per entry. Pure-text entry heights are cached; stream changes invalidate only their entry.
Interactive/attachment rows are measured again because their internal state can
change independently of message values. Committed column-width changes refresh
reserved heights asynchronously, including detached history rows.
No transcript `LazyVStack` or `List` remains.

Only entry views intersecting the actual conversation viewport are mounted in the
AppKit hierarchy. Controllers, SwiftUI state and reserved row heights survive
unmounting. `NSView.visibleRect` alone did not represent SwiftUI scroll clipping;
a fixed native viewport marker and window-coordinate intersection are used instead.
Scroll changes refresh mounting without publishing a whole-workspace state update.

Attributed-text measurements retain up to eight proposed widths per content.
Reply paragraphs use selectable TextKit 1 views, avoiding a separate TextKit 2
viewport controller for every paragraph. Read-only reply and thought views disable
system text checking. Following new replies hides the vertical scroller; user
history scrolling restores the system's automatic indicator. Bottom following is
triggered by actual content-size changes on macOS 15+, not every thought token.

Rejected intermediate candidates: plain eager placement was stable in the bounded
history test but only 12.60–13.02 events/s; row hosting without effective viewport
culling remained 15.94–16.84 events/s. Culling reached 56.78 events/s, followed by
83.84 with TextKit 1. These are diagnostic candidates, not the final result.

The current benchmark preserves the stable outer split/detail hosting structure
used by production; the baseline retains its original root replacement. Both use
the same synthetic JSON/workload and final-text check. The legacy current-report
field `reading_document_height` now measures the 1pt layout marker, not the full
transcript; it must not be used for document-height or performance comparisons.


Final accepted source snapshot: `da25d29514ffd941e7f4311bb67c8669a315935ca01cd377526babd9288eebb4`.
The final disclosure fix caches only message-determined heights; collapsing thought
or tool rows immediately shrinks the row while retaining the separate overview.

| Scenario | Baseline events/s | Current events/s | Speedup | Current median | Current p95 |
|---|---:|---:|---:|---:|---:|
| assistant | 34.27 | 90.11 | 2.63× | 10.73 ms | 13.42 ms |
| thinking | 31.21 | 131.00 | 4.20× | 7.53 ms | 9.30 ms |

[Final raw runs and comparisons](performance/2026-09-21-viewport-refactor-results.json).
One run per variant/scenario, three trials of 120 events, identical fixture hash.
The requested 3× target is **not met for replies**. These results supersede earlier
short-run numbers for the final source; they do not establish remote speed, GPU
presentation time, navigation latency, or freedom from all future hangs.

Bounded UI acceptance covers 60-turn rich history, two history prepends, narrow
column resize, bottom recovery, and thought/tool expansion and collapse. Production
workspace/archive/task-group transitions and manual history/return-to-latest
completed. History prepends do not claim pixel-perfect anchor preservation.
