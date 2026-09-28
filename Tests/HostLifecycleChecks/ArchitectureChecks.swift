import Foundation
import Observation
import SwiftUI
import WorkbenchCore

private final class Invalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
    var occurred: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Deliberately ignores cancellation: a service can still return after cancellation.
@MainActor private final class SuspendedSuggestion {
    private var response: CheckedContinuation<[GroupSuggestion], Error>?
    private let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    init() { (started, signal) = AsyncStream.makeStream() }
    func run() async throws -> [GroupSuggestion] {
        try await withCheckedThrowingContinuation { response in
            self.response = response
            signal.yield(()); signal.finish()
        }
    }
    func waitUntilStarted() async { for await _ in started { return } }
    func complete(_ result: Result<[GroupSuggestion], Error>) {
        response!.resume(with: result); response = nil
    }
}

@MainActor func checkStateArchitecture() async throws {
    let model = WorkbenchModel()
    let catalogChange = Invalidation()
    let routeChange = Invalidation()
    withObservationTracking { _ = model.allSessions } onChange: { catalogChange.mark() }
    withObservationTracking { _ = model.showDashboard } onChange: { routeChange.mark() }
    model.search = "fixture"
    model.showGroupEditor = true
    precondition(!catalogChange.occurred && !routeChange.occurred,
                 "filters and sheets must not invalidate unrelated catalog or destination reads")
    @Bindable var bindable = model
    $bindable.showDashboard.wrappedValue = false
    precondition(routeChange.occurred && !catalogChange.occurred && !model.navigationState.showDashboard,
                 "SwiftUI bindings must reach the nested navigation state")
    model.catalog.replace([])
    precondition(!catalogChange.occurred, "equal catalog snapshots must not invalidate consumers")
    let item = WorkspaceSession(reference: SessionReference(hostID: UUID(), terminalID: "fixture", kind: .kimi),
        title: "Fixture", directory: "/fixture", hostName: "Fixture", detail: "Ready", online: false,
        section: .other, canMarkReviewed: false)
    model.catalog.replace([item])
    precondition(catalogChange.occurred && model.allSessions == [item],
                 "catalog changes must traverse the coordinator's computed properties")
    let sameCatalog = Invalidation()
    withObservationTracking { _ = model.allSessions } onChange: { sameCatalog.mark() }
    model.catalog.replace([item])
    precondition(!sameCatalog.occurred)
    let group = WorkItemGroup(name: "Original", goal: "", nextStep: "", sessions: [item.reference])
    model.workspace.groups = [group]
    model.selectedGroupID = group.id
    // Warm each cache before observing it: the hit path must retain dependencies.
    _ = model.sidebarProjection(filter: .all)
    _ = model.groupIndex; _ = model.groupShortcuts
    let sidebar = Invalidation()
    withObservationTracking { _ = model.sidebarProjection(filter: .all) } onChange: { sidebar.mark() }
    model.catalog.replace([item])
    precondition(!sidebar.occurred, "equal catalogs must leave warm sidebar projections valid")
    model.catalog.replace([])
    precondition(sidebar.occurred && model.sidebarProjection(filter: .all).recent.isEmpty,
                 "warm sidebar cache must observe and rebuild for a changed catalog")
    let groups = Invalidation()
    _ = model.groupShortcuts
    withObservationTracking { _ = model.groupIndex; _ = model.groupShortcuts } onChange: { groups.mark() }
    model.workspace.groups[0].name = "Renamed"
    precondition(groups.occurred && model.groupIndex[item.id] == ["Renamed"]
                 && model.groupShortcuts.first?.group.name == "Renamed",
                 "warm group caches must retain membership/name dependencies")
    model.catalog.replace([item])
    _ = model.sidebarProjection(filter: .all)
    let favorites = Invalidation()
    withObservationTracking { _ = model.sidebarProjection(filter: .all) } onChange: { favorites.mark() }
    model.workspace.starred = [item.reference]
    precondition(favorites.occurred && model.sidebarProjection(filter: .all).favorites.map(\.id) == [item.id],
                 "warm sidebar cache must observe favorite changes")
    print("PASS: warm projection caches preserve catalog, group and favorite observation")
    model.shutdown()
    print("PASS: Observation dependency isolation, nested navigation bindings and equal catalog snapshots")

    let state = GroupSuggestionsState()
    let input = GroupingInput(groups: [], sessions: [])
    let suggestion = GroupSuggestion(sessionID: "fixture", groupID: UUID(), reason: "Fixture")
    func begin() -> GroupSuggestionsState.Request {
        state.begin(input: input, configuration: ActivitySummaryConfiguration(), revision: 1, language: "en")
        return state.request!
    }

    let first = begin()
    await state.load(first) { _ in [suggestion] }
    precondition(state.generated && !state.loading && state.suggestions == [suggestion]
                 && state.selected == [suggestion.id])
    var repeated = false
    await state.load(first) { _ in repeated = true; return [] }
    precondition(!repeated, "reappearing must not resend a completed request")

    let old = begin()
    let oldGate = SuspendedSuggestion()
    let oldTask = Task { await state.load(old) { _ in try await oldGate.run() } }
    await oldGate.waitUntilStarted()
    let replacement = begin()
    let newGate = SuspendedSuggestion()
    let newTask = Task { await state.load(replacement) { _ in try await newGate.run() } }
    await newGate.waitUntilStarted()
    oldGate.complete(.success([suggestion]))
    await oldTask.value
    precondition(state.loading && state.suggestions.isEmpty && !state.generated,
                 "old completion must neither publish results nor clear the new spinner")
    newGate.complete(.success([suggestion]))
    await newTask.value
    precondition(!state.loading && state.generated && state.suggestions == [suggestion])

    for fail in [false, true] {
        let cancelled = begin()
        let gate = SuspendedSuggestion()
        let task = Task { await state.load(cancelled) { _ in try await gate.run() } }
        await gate.waitUntilStarted()
        task.cancel()
        gate.complete(fail ? .failure(URLError(.cancelled)) : .success([suggestion]))
        await task.value
        precondition(!state.loading && !state.generated && state.error == nil && state.suggestions.isEmpty,
                     "cancelled transport successes and errors must remain invisible")
    }
    let invalidated = begin()
    let resetGate = SuspendedSuggestion()
    let resetTask = Task { await state.load(invalidated) { _ in try await resetGate.run() } }
    await resetGate.waitUntilStarted()
    state.reset()
    resetGate.complete(.failure(URLError(.badServerResponse)))
    await resetTask.value
    precondition(state.request == nil && !state.loading && state.error == nil)
    let failed = begin()
    await state.load(failed) { _ in throw URLError(.badServerResponse) }
    precondition(state.error != nil && !state.loading && !state.generated,
                 "active request failures must remain visible")
    print("PASS: suggestion success, replacement, cancellation, reset, failure and reappearance lifecycle")
}
