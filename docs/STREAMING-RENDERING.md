# Streaming reply rendering

The provider publishes cumulative Markdown snapshots. Perch coalesces incoming
snapshots onto a persistent display clock and releases the visible prefix at at
most 60 Hz. The release follows PI's fixed `max(60, backlog / 0.5)` horizon;
completion and non-append replacements flush immediately. Authoritative message
content is never replaced by the display-only prefix.

## Mechanism

- `ConversationEntryController` parses each new source through
  `ReplyStreamParser`. Completed top-level blocks are retained and only the tail
  is reparsed. Link-reference definitions and TeX delimiters that can affect the
  whole document take a full parse. One `ReplyStreamSnapshot` is built per new
  source, not per display frame.
- Admitted paragraphs, headings, code, rules, quotes and lists use one persistent
  `NativeAssistantMessageView` for both `.progress` and `.message`. Settling only
  exposes the message actions; it does not replace the row.
- `NativeAssistantContent` groups at most eight adjacent paragraphs. The parser's
  certified stable block count and a completed-group reuse point let streaming
  preparation rebuild only the changed tail. The last visible block is always
  treated as mutable because a display prefix can cut inside it.
- `NativeAssistantStackView` keeps block heights and offsets until the first
  changed block. Stable TextKit storage, selection and measurement caches survive
  later snapshots; width changes, replacements and clearing invalidate geometry.
- Recreated TextKit 1 views share width measurements for the identical immutable
  attributed string. The bounded FIFO holds at most 4,096 entries and 2,000,000
  attributed UTF-16 units; TextKit 2 long-output readers use their live layout.
- Tables, math, alerts, Mermaid and unsupported nesting retain the SwiftUI
  renderer. They reuse the parse from native admission and display the latest
  cumulative snapshot immediately. Expanded thoughts retain their separate
  TextKit 2 release path.

## Verification

Navigation contracts cover native row identity, stable-prefix identity and
selection, hidden streaming actions, settle, renderer shape changes, parse reuse
and pooling. The `streaming-rendering` mode additionally checks 120 appends
against full preparation on every update, bounded tail geometry work, replacement
and clearing, and cross-view measurement reuse. The host lifecycle fixture checks
cumulative Unicode snapshots, the final completion chunk and unsupported fallback
content.

```sh
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py streaming-rendering --output .local/streaming-on
NAVIGATION_NATIVE_BODY_INCREMENTAL=0 \
  python3 scripts/run-navigation-check.py streaming-rendering --output .local/streaming-off

python3 scripts/run-navigation-check.py fast-scroll --output .local/scroll-on
NAVIGATION_NATIVE_BODY_INCREMENTAL=0 \
  python3 scripts/run-navigation-check.py fast-scroll --output .local/scroll-off
python3 scripts/run-navigation-check.py assistant-rows --output .local/assistant-rows
python3 scripts/run-navigation-check.py interactions --output .local/interactions
python3 scripts/run-navigation-check.py anchor --output .local/anchor
```

`NAVIGATION_NATIVE_BODY_INCREMENTAL=0` exists only in `TRANSCRIPT_CHECKS` builds
and disables native tail preparation, incremental geometry and shared measurement
for a fixed-binary ablation. Production builds always enable them. Alternate at
least three on/off runs on one machine without rebuilding between measurements.

The streaming report records mean, p95 and maximum application time for cumulative
parse, native update and layout. Fast-scroll separately reports cold traversal,
full-history revisit and local reversal. These are application layout/display/CA
flush timings, not hardware input latency, compositor FPS or presented-frame hitch
counts. A 10x claim requires the same-binary end-to-end timing ratio, not merely a
reduction in reuse counters. The 200-turn `JointInteraction` fixture remains the
profiling workload for main-thread TextKit and SwiftUI attribution.

## Boundaries

Incremental parsing preserves CommonMark semantics by falling back to full parses
for document-wide syntax. Giant paragraphs, unsupported rich content and actual
TextKit drawing can still dominate a frame. Measurement reuse does not retain
extra hosting graphs or make offscreen text free to draw. No scrolling or streaming
speedup is established until the corresponding on/off measurements pass on macOS.
