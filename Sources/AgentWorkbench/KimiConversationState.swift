import Foundation
import Observation
import WorkbenchCore

/// Selected Kimi reads have a shorter lifetime than its stream and pending prompts.
@MainActor @Observable
final class KimiConversationState {
    var selectedID: String?
    var conversation: KimiConversation?
    var actionError: String?
    var loading = false
    var snapshotReady = false
    var loadingOlder = false
    @ObservationIgnored private(set) var generation = UUID()
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?

    func cancelLoads() {
        generation = UUID()
        selectionTask?.cancel(); selectionTask = nil; loading = false
        historyTask?.cancel(); historyTask = nil; loadingOlder = false
    }

    /// Kimi refreshes auxiliary task/goal data even when the snapshot read fails;
    /// the connection retains that policy and the state owner controls cleanup.
    func loadSelection(_ operation: @escaping @MainActor () async -> Void) {
        let token = generation
        loading = true
        selectionTask = Task {
            defer { if generation == token { loading = false; selectionTask = nil } }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func loadHistory(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !loadingOlder else { return }
        let token = generation
        loadingOlder = true
        historyTask = Task {
            defer { if generation == token { loadingOlder = false; historyTask = nil } }
            do { try Task.checkCancellation(); try await operation() }
            catch {
                if !Task.isCancelled, !(error is CancellationError), generation == token {
                    actionError = error.localizedDescription
                }
            }
        }
    }
}
