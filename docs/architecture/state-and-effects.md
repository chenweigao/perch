# State and asynchronous work

## Decision

Use Apple's Observation and Swift Concurrency as Perch's default feature foundation
(macOS 14+). Preserve native SwiftUI/AppKit presentation and existing persistence.
These migrations introduce state ownership and rendering boundaries; they are not
a completed rewrite of every provider or a measured frame-rate improvement.

## Ownership

- `WorkbenchApp` owns `WorkbenchModel` through `@State`. The model coordinates
  navigation, persistence and provider connections. Views use `@Bindable` when
  they need bindings; a plain reference is sufficient for read-only Observation.
- `WorkbenchNavigationState` owns destinations, tab/history state and workbench
  filters. Existing coordinator properties forward to it so transition actions
  keep their persistence, focus and visibility behavior during migration.
- `SessionCatalogState` owns the projected session list. Equal catalog snapshots
  do not publish changes. A revision identifies distinct catalogs for derived caches.
  Cache hits must still read their observable inputs; cache storage stays ignored
  by Observation. The coordinator still assembles provider snapshots.
- `GroupSuggestionsState` is sheet-owned feature state. Its request captures the
  exact input, configuration revision and language at the user's click. Applying
  and undoing suggestions still go through the existing workspace operations.
- `NativeAgentConnection` uses Observation. `NativeConversationState` owns the
  selected snapshot and cancellable selection/history reads. Connection polling,
  drafts and the outbox retain their connection lifetime; explicit online/snapshot
  events feed catalog updates and naming. Kimi/Herdr still use `ObservableObject`
  and Combine event bridges. All connections outlive pages. Navigating or dismissing
  a page must never disconnect a host or stop a remote agent.

## Rules for new features

1. Use a small `@MainActor @Observable` state owner. Store UI state there; keep
   task handles, subscriptions and operational caches outside observation.
2. Own page state with `@State`; pass state explicitly. Read only the properties
   needed by each view. Reading a whole array still creates a whole-array dependency.
3. Run page-bound work in `.task(id:)`. Capture request inputs at the action
   boundary; expose an async operation rather than spawning a second `Task` inside
   it. View disappearance and identity changes then propagate cancellation.
4. Check cancellation after suspension and validate the request identity before
   publishing success, failure or cleanup. A cancelled service may return late;
   an old `defer` must not clear a newer request's loading state.
5. Keep long-lived streams and user-started remote work in connection owners with
   explicit stop/reconnect semantics. Do not attach those lifetimes to `.task`.
6. Inject the async request boundary for tests. Verify unrelated state does not
   invalidate consumers, and test replacement, cancellation and late errors.

`GroupSuggestionsSheet` / `GroupSuggestionsState` are the first complete example.
The production-model architecture checks run inside `check-host-lifecycle.py`,
which is already part of the macOS functional CI suite.

## Next migration boundaries

Native session detail and selection/history reads now have this boundary. Apply
the same contract to Kimi only with its distinct live stream, prompt recovery,
subagent and paging checks. Keep rapid switching, reconnect, draft and approval
recovery checks. Move catalog assembly/projections out of the
coordinator only with profiling and semantic parity checks. Avoid migrating all
connection state by mechanical annotation replacement.

Evaluate TCA in a separate bounded feature once the ownership and async contracts
are stable; adoption needs evidence that composition/testing saves more code than
it adds. SwiftData is a separate storage decision requiring a migration and
recovery design. Neither is introduced by this change.

## Verification boundary

Observation tracking tests establish invalidation behavior; deterministic async
checks establish result publication behavior. Native fixture checks establish
isolated UI interactions. None alone proves live SSH recovery, real-model quality,
long-session smoothness or frame-rate gains.

Reference: [Apple Observation migration guide](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro).

## Native input isolation measurement

The native reader and composer are separate SwiftUI views. The reader does not
read drafts or palette state. Observing a connection property alone is not enough
if the same view body still reads unrelated input state.

With 200 conversation turns and a 500-session catalog, 40 sequential draft writes
produced 40 `NativeAgentView.body` evaluations before this migration and zero
afterward. Every write was verified against the mounted composer text. A streaming
snapshot was then delivered as a positive control and did invalidate the reader.
This counts body evaluation, not keyboard/IME latency, CPU savings or frame rate.

`run-native-acceptance.py --mode invalidation` requires zero unrelated reader
updates by default; macOS functional CI includes it and paged-history acceptance.
The baseline-only `PERCH_ACCEPTANCE_ALLOW_INVALIDATION=1` captures the old count;
the functional runner removes this override. Connection checks cover Observation
isolation and stale selection/history results, including old cleanup and errors.

See [performance and technology decisions](performance-and-technology.md) for
technology selection criteria and the next measurements.
