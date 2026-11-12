import Foundation
import Observation
import WorkbenchCore

/// Selected conversation state and cancellable reads. The connection separately
/// owns its polling loop, outbox and remote execution lifetime.
@MainActor @Observable
final class NativeConversationState {
    private(set) var selectedID: String?
    var snapshot: NativeAgentSnapshot? {
        didSet { if let snapshot { presentationSnapshot = snapshot } }
    }
    /// The selected session's cached value, or the last loaded value while an
    /// uncached selection is pending. It is presentation-only: transport,
    /// commands and readiness must continue to use `snapshot`.
    private(set) var presentationSnapshot: NativeAgentSnapshot?
    var actionError: String?
    private(set) var loadingOlder = false
    @ObservationIgnored private(set) var generation = UUID()
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotCache: NativeSnapshotCache
    var isSelecting: Bool { selectionTask != nil }

    init(cacheCapacity: Int = 8, maximumCachedMessages: Int = 1_000,
         maximumCachedPayloadCost: Int = 1_048_576) {
        snapshotCache = NativeSnapshotCache(capacity: cacheCapacity,
                                            maximumMessages: maximumCachedMessages,
                                            maximumPayloadCost: maximumCachedPayloadCost)
    }

    func select(_ id: String?) {
        cancelLoads()
        let removed = id == nil ? selectedID : nil
        // Admission walks the transcript, so do it once when navigating away,
        // never on every streamed snapshot publication.
        if id != nil, let snapshot { snapshotCache.store(snapshot) }
        selectedID = id; snapshot = nil; actionError = nil
        if let id, let cached = snapshotCache.take(id) { presentationSnapshot = cached }
        if id == nil {
            if let removed { snapshotCache.remove(removed) }
            presentationSnapshot = nil
        }
    }

    func removeCached(_ id: String) { snapshotCache.remove(id) }

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

/// A bounded presentation cache for fast A→B→A navigation. Cached snapshots are
/// never authoritative connection state; they only let the target transcript
/// appear while its fresh read is in flight.
private struct NativeSnapshotCache {
    private var values: [String: NativeAgentSnapshot] = [:]
    private var recency: [String] = []
    private let capacity: Int
    private let maximumMessages: Int
    private let maximumPayloadCost: Int

    init(capacity: Int, maximumMessages: Int, maximumPayloadCost: Int) {
        precondition(capacity >= 0 && maximumMessages >= 0 && maximumPayloadCost >= 0)
        self.capacity = capacity
        self.maximumMessages = maximumMessages
        self.maximumPayloadCost = maximumPayloadCost
    }

    mutating func take(_ id: String) -> NativeAgentSnapshot? {
        guard let value = values[id] else { return nil }
        recency.removeAll { $0 == id }
        recency.append(id)
        return value
    }

    mutating func store(_ snapshot: NativeAgentSnapshot) {
        remove(snapshot.id)
        guard capacity > 0, snapshot.messages.count <= maximumMessages,
              Self.cost(snapshot) <= maximumPayloadCost else { return }
        values[snapshot.id] = snapshot
        recency.append(snapshot.id)
        while recency.count > capacity { remove(recency[0]) }
    }

    mutating func remove(_ id: String) {
        values.removeValue(forKey: id)
        recency.removeAll { $0 == id }
    }

    /// Admission estimate only. Swift collections and renderer state have
    /// additional overhead; the cap prevents retaining obviously large payloads.
    private static func cost(_ snapshot: NativeAgentSnapshot) -> Int {
        snapshot.id.utf8.count + snapshot.title.utf8.count + snapshot.cwd.utf8.count
            + snapshot.model.utf8.count + snapshot.messages.reduce(0, { $0 + cost($1) })
            + snapshot.interactions.reduce(0, { $0 + cost($1) }) + 256
    }

    private static func cost(_ message: KimiMessage) -> Int {
        message.id.utf8.count + message.role.utf8.count + message.createdAt.utf8.count
            + cost(message.metadata) + message.content.reduce(128) { total, part in
                total + [part.type, part.text, part.thinking, part.toolCallId, part.toolName, part.fileId, part.name]
                    .compactMap { $0 }.reduce(128) { $0 + $1.utf8.count }
                    + cost(part.input) + cost(part.output) + cost(part.source)
            }
    }

    private static func cost(_ value: JSONValue?) -> Int {
        guard let value else { return 0 }
        switch value {
        case .object(let values):
            return values.reduce(32) { $0 + $1.key.utf8.count + cost($1.value) + 32 }
        case .array(let values): return values.reduce(32) { $0 + cost($1) }
        case .string(let value): return value.utf8.count + 32
        case .number, .bool, .null: return 16
        }
    }
}
