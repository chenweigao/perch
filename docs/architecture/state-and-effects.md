# State and asynchronous work

## Decision

Use Apple's Observation and Swift Concurrency as Perch's default feature foundation
(macOS 14+). Preserve native SwiftUI/AppKit presentation and existing persistence.
This first migration introduces state ownership boundaries; it is not a completed
rewrite of the connection layer or a measured frame-rate improvement.

## Ownership

- `WorkbenchApp` owns `WorkbenchModel` through `@State`. The model coordinates
  navigation, persistence and provider connections. Views use `@Bindable` when
  they need bindings; a plain reference is sufficient for read-only Observation.
- `WorkbenchNavigationState` owns destinations, tab/history state and workbench
  filters. Existing coordinator properties forward to it so transition actions
  keep their persistence, focus and visibility behavior during migration.
- `SessionCatalogState` owns the projected session list. Equal catalog snapshots
  do not publish changes. The coordinator still assembles provider snapshots.
- `GroupSuggestionsState` is sheet-owned feature state. Its request captures the
  exact input, configuration revision and language at the user's click. Applying
  and undoing suggestions still go through the existing workspace operations.
- Kimi/native/Herdr connections retain their existing `ObservableObject` lifecycle
  and explicit Combine event bridges. They outlive pages. Navigating or dismissing
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

Migrate one provider's session detail state and selection/history loads together,
with rapid switch, reconnect, draft and approval recovery checks. Then apply that
contract to the other provider. Move catalog assembly/projections out of the
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
