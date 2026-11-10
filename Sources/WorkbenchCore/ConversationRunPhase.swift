import Foundation

/// The live footer reports a phase, never a tool target or a generated summary.
public enum ConversationRunPhase: Equatable, Sendable {
    case thinking, running, executing, waitingForConfirmation, waitingForAnswer, stopping

    public init?(turn: SessionTurn, online: Bool, stopping: Bool = false,
                 request: TurnRequest.Kind? = nil, hasRunningTools: Bool = false, thinking: Bool = false) {
        guard online else { return nil }
        if turn.pending {
            self = request == .question ? .waitingForAnswer : .waitingForConfirmation
        } else if stopping && turn.running {
            self = .stopping
        } else if turn.running {
            self = hasRunningTools ? .executing : thinking ? .thinking : .running
        } else { return nil }
    }

    public var animates: Bool { self == .thinking || self == .running || self == .executing }
    public var needsInput: Bool { self == .waitingForConfirmation || self == .waitingForAnswer }
    public var titleKey: String {
        switch self {
        case .thinking: return "Thinking…"
        case .running: return "Running…"
        case .executing: return "Executing…"
        case .waitingForConfirmation: return "Waiting for confirmation…"
        case .waitingForAnswer: return "Waiting for an answer…"
        case .stopping: return "Stopping…"
        }
    }
}
