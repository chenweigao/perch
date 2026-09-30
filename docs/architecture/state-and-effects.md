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
  events feed catalog updates and naming. `KimiConnection` uses the same Observation
  boundary, with `KimiConversationState` owning selection/history reads and readiness.
  Kimi keeps its streaming, pending prompt reconciliation, tasks and subagent policy
  in the connection; explicit conversation events feed naming (including initial
  catch-up). Herdr still uses `ObservableObject` and Combine event bridges.
  All connections outlive pages. Navigating or dismissing
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

Native and Kimi session detail and selection/history reads now have this boundary.
Keep rapid switching, reconnect, draft, approval, prompt recovery, subagent and paging
checks when changing either connection. Move catalog assembly/projections out of the
coordinator only with profiling and semantic parity checks. Avoid migrating all
connection state by mechanical annotation replacement.

Evaluate TCA in a separate bounded feature once the ownership and async contracts
are stable; adoption needs evidence that composition/testing saves more code than
it adds. SwiftData is a separate storage decision requiring a migration and
recovery design. Neither is introduced by this change.

## Native detail renderer lifetime

`NativeConversationState.snapshot` remains the authoritative selected response.
Selection clears it immediately and existing cancellation/generation checks protect
its publication. `presentationSnapshot` holds just the last loaded value so the
detail tree can survive a pending selection. It is not a response cache and must
never be used for command routing, readiness or connection decisions. Removing the
selection clears both; a completed read replaces the presentation value.

`NativeAgentView` hides, disables and removes the retained detail from accessibility
until the authoritative snapshot matches the selected session. Loading and failure
UI appear above that same container. The transcript explicitly suspends its AppKit
document: save the reading position, hide the native subtree, reserve geometry and
skip content/appearance reconciliation, measurement and navigation. Resuming supplies
current content and appearance before restoring position. This avoids propagating a
temporary disabled appearance through all outgoing rows merely to show a spinner.

The scroll view and transcript document retain identity across selection, error and
retry within one connection. The detail root is keyed by connection identity, so
two hosts with identical raw session IDs cannot share input or renderer state.
Displayed-result callbacks capture their originating connection's host. The
composer, activity bar, pending-message editor and interaction state stay
keyed by session; composer text input and undo state therefore remain independent.
Send/stop callbacks also validate the selected snapshot at invocation. This does not
retain a UI tree for each tab or expand the shared presentation model cache.

The native `detail-lifecycle` functional scenario delays a read and verifies actual
native ancestor visibility, renderer identity, composer replacement, focus, marked
text/undo isolation, old send rejection, suspended navigation, reading-position
return, failure and retry. Connection checks separately cover late A-B-A replies and
selection removal. A preloaded second host with the same raw session ID also has a
mounted composition-isolation check. Kimi retains its existing detail lifecycle in
this change.

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

## Kimi input isolation measurement

`KimiComposerView` owns its palette and file picker state, keyed by session identity.
The root reader no longer reads drafts. In the same mounted 200-turn Kimi fixture,
40 draft writes caused 40 root body evaluations before migration and zero afterward.
Each draft was verified in the mounted editor, and a decoded `assistant.delta` went
through the production event handler as a positive control. A-B-A selection also
verifies that each composer restores its own draft.

`run-native-acceptance.py --mode kimi-invalidation` is included in macOS functional
checks. It uses fixed HTTP responses through the real Kimi API decoder and an injected
stream frame, without SSH, a live daemon or persistent user drafts. Connection checks
cover model/attachment/draft isolation, event bridges, old selection cleanup, old page
errors, disconnect and visible current errors. Existing Kimi checks still cover goals,
tasks, subagent transcript, history recovery and promoted steering. Naming lifecycle
checks exercise initial catch-up and later conversation events on the production model.

The measured gain remains removal of unrelated body evaluations, not certified input
latency, frame rate or real-transport recovery.

## Conversation presentation ownership

`ConversationPresentationModel` owns pure tool visibility, turn projection, narrative,
summary batch and per-row tool mapping. Its immutable snapshot is reused only when
all source values match: message contents, live tools, running IDs, busy/online state,
history epoch, locale and summary policy. Same-ID edits remain authoritative. Runtime
epoch changes clear remembered live tools; language changes rebuild localized turn
summaries without losing tool handoff evidence. External narrative-store updates are
overlaid at read time, so a cache hit cannot freeze a newly arrived summary.

`ConversationPresentationHandle` belongs to the transcript view. The workbench owns
an LRU of at most eight presentation models, injected directly into `WorkbenchDetail`
(the custom AppKit hosting boundary). Each admitted model has at most 1,000 source
messages and 1 MiB of estimated UTF-8 payload/record cost, including nested tool JSON
and remembered live tools. This admission estimate is not an RSS limit: snapshots,
Swift collections and AppKit have additional costs. Oversized active conversations
render normally and retain their view-local model, but are not kept in the shared
cache after leaving. Host/provider/session identity separates entries; deleting a
session, removing a host or shutting down clears the corresponding cache entries.

The model/cache are synchronous computation objects, called on the UI owner thread;
they are deliberately outside Observation and own no tasks, providers or AppKit row
hosts. Actual view construction/layout stays on the main thread. Summary effects
remain in the existing `.task(id:)` boundary. A background actor or row-host cache
requires separate profiling and cancellation/identity/appearance evidence.

Core checks cover parity, changed content, pagination, epoch/language invalidation,
external overlays, LRU eviction, host/provider separation, oversized admission and
release. Mounted switching acceptance additionally checks that eight conversations
actually restore their models across navigation.

## Transcript content and viewport invalidation

`ConversationDocumentView.configure` updates viewport attachment, content origin,
navigation and reading-position restoration. It delegates source changes to
`reconcileRows`, whose invalidation is independent of scrolling/layout callbacks:

- Equal content, session and appearance preserve indices, heights and measured rows.
- Same-ID edits replace their source rows and invalidate only affected controller
  measurements. An offscreen edit does not invalidate the mounted range merely
  because data changed. Actual height callbacks still rebuild geometry and preserve
  the reader's anchor, including callbacks from retained offscreen hosts.
- Session changes, row insertion/removal/reordering and process-row spacing changes
  rebuild structural geometry. Appearance changes invalidate measured sizes.
- Width changes, disclosure callbacks and asynchronously loaded content retain their
  existing independent measurement/anchor paths. Local view state must never rely
  on source-array equality to publish its new size.

The controller writes AppKit frames only when the frames differ. No additional row
host retention or cross-session measurement cache is introduced. Native acceptance
checks unchanged replay, visible/offscreen same-ID edits, appearance, prepend and
removal; navigation fixtures cover the interaction and reading contracts.

The hosting boundary carries the immutable presentation snapshot identity together
with the complete external-summary map, provider API identity and session/memory
scope. Equal viewport updates compare these inputs without walking every message.
External summaries are captured once per transcript render; they remain independent
of the source snapshot, so their arrival must invalidate hosted rows even when the
presentation snapshot itself is unchanged. Acceptance includes that positive control.

`ConversationDocumentLayout` is view-lifetime, non-observable geometry state. Origin
notifications update the mounted AppKit document directly instead of invalidating
`ConversationTranscript.body`. The representable coordinator holds only a weak
reference to that document and clears it on dismantling; content and appearance
still flow through SwiftUI's normal representable update path.

The native document is top-aligned inside its measured SwiftUI height frame.
Disclosure changes can resize native rows before the deferred outer height is
published; default centering would move the entire document by half that height
difference for a layout pass. Keep the origin stable across this handoff and test
every sampled disclosure state, not just the final restored anchor. The isolated
`disclosure --disclosure-context --assert-atomic-disclosure` navigation check
verifies row/content height agreement and a stationary header during expansion
and collapse. This geometry contract is separate from rendering latency or FPS.

## Sidebar invalidation diagnostic

`sidebar-invalidation` records body evaluations and mounted per-row inputs while
exercising selection, one catalog item, busy state, group membership, pinning and
order/content restoration. Counts diagnose invalidation; functional readiness checks
verify actual mounted row data. It uses no network or hardware input. Probes and
counters are active only in this acceptance mode and absent from production builds.

A two-boundary value/equality prototype reduced unrelated row body work but did not
improve end-to-end rendering; catalog refresh became slower. It was rejected, leaving
the production sidebar unchanged. The reproducible patch, fixed-binary measurements
and rationale are in [the experiment report](../performance/2026-09-29-sidebar-boundaries/REPORT.md).

## Sidebar layout stimulus contract

The `sidebar-layout-*` acceptance modes separate title edits, permutations of the
same rows, favorites-section/member changes, and status/subtitle/height changes.
A no-op replay is the timing floor; `height-fixed` repeats identical status changes
while reserving 48pt. Only acceptance builds can enable that height override.
Production rows continue to use 34pt or 48pt according to their subtitle.

Mounted row probes verify actual order and height as well as row values before
ending each response sample. ID-based membership and top-edge changes are counted
outside response samples; they are not native view creation counts. The functional
suite includes order, pin and dynamic-height contracts. Timing/profiling runs remain
separate and do not establish hardware-input latency or frame rate.

See [the layout diagnosis](../performance/2026-09-29-sidebar-layout/REPORT.md) before
changing section identity, row density or the underlying list control.

## Sidebar identity across sections

Pinned and recent sessions use one eager `ForEach` whose entries include section
headers and the existing task-group block. A session's identity is its session ID;
its current section is not part of that identity. Both positions use the same
`Entry.session` branch and `SessionSidebarRow`, so pinning does not replace the
row's structural parent. Headers retain their existing AppStorage expansion keys,
filter actions and native styling. Collapsing a section removes its rows; this is
not a cache of hidden sessions or a change to the recent-session limit.

Keep content changes, geometry changes, visible membership and identity changes
separate when investigating rendering. Acceptance-only variants compare the old
section parents, persistent empty headers and persistent subtitle nodes. Native
row markers validate identity alongside mounted values/order/height; marker-free
runs check that measuring row lifetime did not create the observed benefit.
The accepted scope is cross-section movement, not a claim that conversation
switching or all workbench rendering became faster. See the
[experiment report](../performance/2026-09-29-sidebar-sweep/REPORT.md).

## Long output reading boundary

`DisclosureReplyText` keeps short output inline. For output longer than 4,000
characters, preview and complete reading occupy the same 360pt region, so the
full-content toggle does not resize the outer transcript. The preview remains
bounded; the complete source is retained and available for selection and copying.

`LongOutputReader` owns local query/visibility state through Observation. Its
AppKit scroll view uses an explicitly opted-in TextKit 2 text view, with width
tracking and no whole-source height measurement in `sizeThatFits`. Search uses
UTF-16 ranges against the complete source, wraps in both directions and scrolls
only the inner reader. Avoid accessing the legacy `layoutManager`, which can
switch the text view back to TextKit 1.

Equal updates do not replace text storage. Same-style prefix extensions append
only new attributed text and preserve selection/reading position; replacement
content clears selection and starts at the top. This is a rendering boundary,
not a storage limit: the full text stays in memory, and a single huge paragraph
can still require expensive text layout. The existing outer transcript
virtualization and connection lifetimes are unchanged.

Acceptance compares inline and viewport renderers in one fixed binary and checks
full Unicode copying, end-of-content search, missing queries, backwards wrapping,
streaming append, resize, replacement, and stationary outer geometry. See the
[long output report](../performance/2026-09-29-long-output/REPORT.md) for measured
scope and the independent-scroll interaction tradeoff.

## Bounded native paragraph groups

Adjacent Markdown paragraphs share a native text view in groups of at most eight.
The first source block index identifies the group; equal completed groups retain
views while streaming changes only the tail group. Headings, code, tables, list
items, quotes and empty paragraphs preserve their structural boundaries. Lists and
quotes may group their own adjacent paragraphs with compact spacing.

TextKit paragraph spacing replaces SwiftUI padding within a group, preserving
hard breaks and inheriting the preceding run's font at the separator. Per-paragraph
rounding is no longer applied, so small cumulative glyph-position differences are
expected. Prefix-preserving updates retain selection; replacements use normal text
storage semantics. The full Markdown source and existing link/file routing remain
authoritative. A group is bounded by paragraph count, not characters: giant single
paragraphs and whole-document parsing are still separate performance limits.

The native `paragraphs` check covers wrapping, glyph positions, links, Unicode
copying, empty alt text, streaming identity/selection and replacement. Full reading,
search, resizing, session return and prepend checks cover transcript composition.
See the [experiment](../performance/2026-09-30-paragraph-rendering/REPORT.md) for
fixed-binary results; these are application layout timings, not measured FPS.
