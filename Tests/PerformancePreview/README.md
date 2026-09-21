# Local transcript pipeline benchmark

This fixture measures JSON event decode → `KimiConversation.apply` → the production
`ConversationTranscript` inside the corresponding production `WorkspaceSplitView` → SwiftUI/AppKit layout and display submission. It is **not**
a measure of remote inference, network latency, connection batching, or GPU presentation
completion. Every event forces a rendered update in both builds; no deltas are skipped.

Build the normal Release target once for Markdown dependency artifacts, then:

```sh
SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.local/swiftpm-libs" scripts/build-performance-preview.sh baseline
SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.local/swiftpm-libs" scripts/build-performance-preview.sh current
```

The baseline is pinned to `5596b6c4184c17f80f7992b11e6f1b8d647e46d8`.
The script independently compiles the matching Core and relevant UI sources for each
variant with the same optimizer, compiler, fixture, and Markdown dependencies.
No working checkout is reset and no real conversation is opened. The actual baseline/current
AppKit split and hosting implementations are included with an identical synthetic sidebar;
this covers intrinsic-size measurement changes, though it does not construct the entire real
workspace model or terminal tabs. The measured hosting surface is fixed at 1180 × 600 points.

Open each generated app using the UI tools and press **运行基准**. Keep its window
visible, unobscured, and at the same dimensions. Close the other performance fixture;
run in alternating order to reduce thermal/order bias. Do not compare a background or
resized run with a foreground run.

The deterministic workload has 24 history turns with Chinese Markdown, code, tables,
and collapsed tool records, followed by 120 JSON streaming events, repeated 3 times.
The initial history layout is outside the timed stream; each trial starts from the
same snapshot. Every event includes JSON decoding, apply, a SwiftUI update, AppKit
layout/display and transaction flush. A real NSViewRepresentable marker verifies that
the corresponding content update has reached the hosting view; final text is checked
byte-for-byte before a successful result is emitted.

Reports are saved in `.local/performance-results/` with workload/source/fixture hashes,
compiler/macOS versions, window bounds, backing scale, event latencies, throughput,
and final UTF-16 length. Compare only equal workload/fixture hashes and window geometry.
Use aggregate events/second ratios for throughput; report median and p95 event latency
separately. A 3× target is met only when the measured current/baseline throughput ratio
is at least 3 for the stated workload. A faster isolated projection benchmark does not
by itself establish this rendering result.

Compare a matching pair without selecting the fastest trial:

```sh
scripts/compare-performance.py .local/performance-results/baseline-<time>.json .local/performance-results/current-<time>.json
```

The comparison refuses mismatched workloads, fixtures, dependencies, compiler/macOS,
and window geometry. `target_3x_met` reports the measured aggregate ratio, not an
assumed acceptance result.

## Independent assistant and thinking scenarios (v2)

Use the **正文流 / 思考流** segmented control before each run. The scenarios use the
same long history and payload text, but route deltas to `assistant.delta` or
`thinking.delta` respectively. They have distinct workload hashes and result filenames;
the comparison script rejects cross-scenario comparisons. Thinking results exercise
the production thought viewport separately and are not blended into Markdown throughput.

The v2 reports include the actual `content_viewport_width/height`, `reading_width`,
`reading_document_height`, fixed host bounds, and full window frame dimensions.
Native split/toolbar versions may have slightly different sidebar widths (for example,
270 vs 278 points), so their outer transcript viewport widths can differ. Both still
use the same measured fixed 760-point reading column, which fixes text line wrapping.
The comparison requires equal reading width and viewport height; it emits both outer
viewport widths so any margin difference remains visible in the evidence. Earlier v1
reports do not contain these measurements and must not be compared to v2 reports.

## Public source snapshots

Historical reports retain the original measurement values and source hashes; local
result-directory paths have been replaced with `<repo>`. A clean public repository
does not contain the private development commits referenced by those reports.
To measure your own changes, preserve a compatible local pre-change commit and
set `WORKBENCH_BASELINE_REF` when building the baseline. Do not substitute a new
commit and present its results as the original historical baseline.

```sh
WORKBENCH_BASELINE_REF=<your-local-pre-change-commit> scripts/build-performance-preview.sh baseline
```

Both fixture sources must support that revision's transcript interface. The current
fixture uses separate compile paths for the original and current hosting structures;
when comparing newer revisions, update the baseline fixture to match that revision
and keep the same workload and completion checks in both builds. Record that change.
