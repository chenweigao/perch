import Foundation
import Observation
import WorkbenchCore

/// Selected conversation state and cancellable reads. The connection separately
/// owns its polling loop, outbox and remote execution lifetime.
@MainActor @Observable
final class NativeConversationState {
    private(set) var selectedID: String?
    var snapshot: NativeAgentSnapshot?
    var actionError: String?
    private(set) var loadingOlder = false
    @ObservationIgnored private(set) var generation = UUID()
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    var isSelecting: Bool { selectionTask != nil }

    func select(_ id: String?) {
        cancelLoads()
        selectedID = id; snapshot = nil; actionError = nil
    }

    func cancelLoads() {
        generation = UUID()
        selectionTask?.cancel(); selectionTask = nil
        historyTask?.cancel(); historyTask = nil; loadingOlder = false
    }

    func loadSelection(_ operation: @escaping @MainActor () async throws -> Void) {
        let token = generation
        selectionTask = Task {
            defer { if generation == token { selectionTask = nil } }
            do { try Task.checkCancellation(); try await operation() }
            catch {
                if !Task.isCancelled, !(error is CancellationError), generation == token {
                    actionError = error.localizedDescription
                }
            }
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
