# Streaming reply rendering

The provider publishes cumulative Markdown snapshots. Perch renders each received
snapshot completely instead of adding a second per-frame character reveal. This
keeps display cadence tied to the provider and avoids multiplying one network
update into many main-thread layout passes.

## Mechanism

- `ConversationEntryController` parses each assistant snapshot once through the
  bounded preparation cache. Full parsing preserves CommonMark semantics across
  code fences, lists, quotes and link definitions.
- Admitted paragraphs, headings, code, rules, quotes and lists use one persistent
  `NativeAssistantMessageView` for both `.progress` and `.message`. Settling only
  exposes the message actions; it does not replace the row.
- `NativeAssistantContent` groups at most eight adjacent paragraphs. The native
  stack compares old and new blocks, leaves equal prefix views untouched and
  updates only changed blocks, normally the final group. Stable TextKit storage,
  selection and measurement caches therefore survive later snapshots.
- Tables, math, alerts, Mermaid and unsupported nesting retain the SwiftUI
  renderer. They reuse the parse from native admission and display the latest
  cumulative snapshot immediately.
- The thinking preview keeps its separate append-based viewport.

## Verification

Navigation contracts cover native row identity, stable-prefix identity and
selection, hidden streaming actions, settle, renderer shape changes, parse reuse
and pooling. `NAVIGATION_AUTORUN=streaming-rendering` also records the mean, p95
and maximum cost of cumulative parse, native update and layout passes. The host
lifecycle fixture mounts the production transcript and checks cumulative Unicode
snapshots, the final completion chunk and unsupported fallback content.

The 200-turn `JointInteraction` fixture remains the profiling workload. Run it at
10 Hz and sample the process to compare main-thread TextKit measurement and
SwiftUI graph work with the recorded baseline.

## Boundaries

This design intentionally reparses the cumulative source at provider cadence. It
does not implement a delimiter-based incremental Markdown parser: block semantics
can cross apparent paragraph boundaries, and parsing was not the measured
bottleneck. Revisit parser incrementalization or snapshot coalescing only if a
new profile shows parsing dominating after the layout fix.
