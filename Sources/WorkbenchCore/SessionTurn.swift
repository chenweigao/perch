import Foundation

/// What every surface knows about a session's latest turn: the sidebar section,
/// the Dock badge, batch archive, notifications, the Goal header and the status
/// line (`TurnStatus`) all read it, built by the same constructors, so they
/// cannot disagree about running, waiting, failed or finished. Catalog rows and
/// the selected session's live snapshot both have one.
public struct SessionTurn: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The agent waits for a confirmation or an answer.
        case waiting
        case running
        /// The latest turn failed.
        case failed
        /// A turn finished cleanly; `completion` identifies it.
        case finished
        case idle
    }

    public var running: Bool
    public var pending: Bool
    public var failed: Bool
    /// Identifies the latest cleanly finished turn and changes with each new one:
    /// Kimi's `updatedAt` after a completed turn, a native agent's completed-turn
    /// count. nil before any. The review cursor and the finished-turn notice key on it.
    public var completion: String?

    public init(running: Bool = false, pending: Bool = false, failed: Bool = false, completion: String? = nil) {
        self.running = running; self.pending = pending; self.failed = failed; self.completion = completion
    }

    /// The reader's decision outranks progress; progress outranks a failure the
    /// agent may still recover from; a finished result comes last.
    public var state: State {
        if pending { return .waiting }
        if running { return .running }
        if failed { return .failed }
        return completion == nil ? .idle : .finished
    }

    /// The sidebar section, given the completion the reader last saw.
    public func section(reviewed: String?) -> WorkQueueSection {
        switch state {
        case .waiting, .failed: return .attention
        case .running: return .running
        case .finished: return completion == reviewed ? .other : .review
        case .idle: return .other
        }
    }
}

extension SessionTurn {
    /// A Kimi catalog row. The server reports "none" when nothing is pending, so
    /// only a named interaction counts.
    public init(kimi session: KimiSession) {
        self.init(running: session.isTurnRunning, pending: Self.isPending(session.pendingInteraction),
                  failed: session.lastTurnReason == "failed",
                  completion: session.lastTurnReason == "completed" ? session.updatedAt : nil)
    }
    /// The selected Kimi conversation: its session row plus the approvals and
    /// questions the snapshot lists.
    public init(kimi snapshot: KimiSnapshot) {
        self.init(kimi: snapshot.session)
        pending = pending || !snapshot.pendingApprovals.isEmpty || !snapshot.pendingQuestions.isEmpty
    }
    /// A native catalog row.
    public init(native session: NativeAgentSession) {
        self.init(running: session.busy, pending: session.pending > 0, failed: session.error != nil,
                  completion: session.completed > 0 ? String(session.completed) : nil)
    }
    /// The selected native session's snapshot.
    public init(native snapshot: NativeAgentSnapshot) {
        self.init(running: snapshot.busy, pending: !snapshot.interactions.isEmpty, failed: snapshot.error != nil,
                  completion: snapshot.completed > 0 ? String(snapshot.completed) : nil)
    }

    static func isPending(_ interaction: String?) -> Bool {
        guard let interaction, !interaction.isEmpty else { return false }
        return interaction != "none"
    }
}
