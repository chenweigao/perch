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
        case .thinking: return "正在思考"
        case .running: return "正在处理"
        case .executing: return "正在执行"
        case .waitingForConfirmation: return "等待你确认"
        case .waitingForAnswer: return "等待你回答"
        case .stopping: return "正在停止"
        }
    }
}
