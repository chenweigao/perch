import Foundation

/// The turn's live state. Its independent work line may attach a provider action summary.
public enum ConversationRunPhase: Equatable, Sendable {
    case thinking, running, executing, responding, waitingForConfirmation, waitingForAnswer, stopping

    public init?(turn: SessionTurn, online: Bool, stopping: Bool = false,
                 request: TurnRequest.Kind? = nil, hasRunningTools: Bool = false,
                 thinking: Bool = false, responding: Bool = false) {
        guard online else { return nil }
        if turn.pending {
            self = request == .question ? .waitingForAnswer : .waitingForConfirmation
        } else if stopping && turn.running {
            self = .stopping
        } else if turn.running {
            self = hasRunningTools ? .executing : thinking ? .thinking : responding ? .responding : .running
        } else { return nil }
    }

    public var animates: Bool {
        self == .thinking || self == .running || self == .executing || self == .responding
    }
    public var needsInput: Bool { self == .waitingForConfirmation || self == .waitingForAnswer }
    public var titleKey: String {
        switch self {
        case .thinking: return "正在思考"
        case .running: return "正在处理"
        case .executing: return "正在执行"
        case .responding: return "正在回复"
        case .waitingForConfirmation: return "等待你确认"
        case .waitingForAnswer: return "等待你回答"
        case .stopping: return "正在停止"
        }
    }
}
