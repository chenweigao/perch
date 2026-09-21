import Foundation

/// How confident we are that an adapter can inject into a running turn. A command
/// that merely exists in the runtime is not the same as one observed to change the
/// turn, and the UI must not present the two identically.
public enum SteerSupport: String, Sendable, Equatable {
    case unsupported, commandPresentEffectUnverified, verified

    public var allowsSteering: Bool { self != .unsupported }
    public var label: String {
        switch self {
        case .unsupported: return "下一轮发送"
        case .commandPresentEffectUnverified: return "引导当前任务（未实机验证）"
        case .verified: return "引导当前任务"
        }
    }
}

public struct AgentCapabilities: Equatable, Sendable {
    public let nativeConversation: Bool
    public let terminal: Bool
    public let stop: Bool
    public let steer: SteerSupport
    public let queueWhileBusy: Bool
    public let resume: Bool

    public init(nativeConversation: Bool = false, terminal: Bool = false, stop: Bool = false,
                steer: SteerSupport = .unsupported, queueWhileBusy: Bool = false, resume: Bool = false) {
        self.nativeConversation = nativeConversation; self.terminal = terminal; self.stop = stop
        self.steer = steer; self.queueWhileBusy = queueWhileBusy; self.resume = resume
    }

    /// An unknown runtime version gets nothing. Capabilities are granted by probing,
    /// never inherited from a newer version's documentation.
    public static let unknown = AgentCapabilities()

    /// What the composer may offer right now. While a turn runs, an adapter without
    /// steering can only queue, so a plain POST is never labelled as steering.
    public func modes(isStreaming: Bool) -> [DeliveryMode] {
        guard isStreaming else { return [.now] }
        var modes: [DeliveryMode] = []
        if steer.allowsSteering { modes.append(.steer) }
        if queueWhileBusy { modes.append(.nextTurn) }
        return modes
    }
}

public enum DeliveryMode: String, Codable, Sendable, Equatable {
    case now, steer, nextTurn
}

public enum StopEvidence: Equatable, Sendable {
    case runtimeAborted, turnInterrupted, completedBeforeStop, processGone
}

public enum StopPhase: Equatable, Sendable {
    case idle, requested, stopping, stopped
    case completedBeforeStop
    case failed(String)
    case unknown(String)

    public var isSettled: Bool {
        switch self {
        case .idle, .stopped, .completedBeforeStop, .failed, .unknown: return true
        case .requested, .stopping: return false
        }
    }
    public var label: String {
        switch self {
        case .idle: return "停止"
        case .requested, .stopping: return "正在停止…"
        case .stopped: return "已停止"
        case .completedBeforeStop: return "停止前已结束"
        case .failed(let message): return "停止失败：\(message)"
        case .unknown(let message): return "停止结果未知：\(message)"
        }
    }
    /// Only an unknown or failed stop offers a retry; a settled stop must not invite
    /// another abort that could hit a freshly started turn.
    public var canRetry: Bool {
        switch self {
        case .failed, .unknown: return true
        default: return false
        }
    }
}

/// One stop attempt, bound to the session and turn that were on screen when the
/// user clicked. Late protocol events for a different turn cannot resolve it.
public struct StopAttempt: Equatable, Sendable {
    public let session: SessionReference
    public let turn: String?
    public let requestID: String
    public var phase: StopPhase
}

public struct StopController: Equatable, Sendable {
    private var attempts: [String: StopAttempt] = [:]
    public init() {}

    public func phase(for session: SessionReference) -> StopPhase { attempts[session.id]?.phase ?? .idle }
    public func attempt(for session: SessionReference) -> StopAttempt? { attempts[session.id] }
    public func isStopping(_ session: SessionReference) -> Bool { !phase(for: session).isSettled }

    /// Returns the attempt to send, or nil when one is already in flight. Repeated
    /// clicks therefore cannot produce a second abort for the same turn.
    public mutating func request(_ session: SessionReference, turn: String? = nil,
                                 requestID: String = UUID().uuidString) -> StopAttempt? {
        if let existing = attempts[session.id], !existing.phase.isSettled { return nil }
        let attempt = StopAttempt(session: session, turn: turn, requestID: requestID, phase: .requested)
        attempts[session.id] = attempt
        return attempt
    }

    /// The runtime accepted the abort. Acceptance is not termination, so this stays
    /// short of `.stopped`.
    public mutating func acknowledge(_ requestID: String) {
        guard let key = key(for: requestID), attempts[key]?.phase == .requested else { return }
        attempts[key]?.phase = .stopping
    }

    public mutating func resolve(_ session: SessionReference, turn: String? = nil, evidence: StopEvidence) {
        guard var attempt = attempts[session.id] else { return }
        if attempt.phase == .stopped || attempt.phase == .completedBeforeStop { return }
        // A terminal event from a different turn says nothing about the one we stopped.
        if let expected = attempt.turn, expected != turn { return }
        switch evidence {
        case .runtimeAborted, .turnInterrupted: attempt.phase = .stopped
        case .completedBeforeStop: attempt.phase = .completedBeforeStop
        case .processGone: attempt.phase = .unknown("远端进程已退出，副作用可能已发生")
        }
        attempts[session.id] = attempt
    }

    public mutating func fail(_ requestID: String, _ message: String) {
        guard let key = key(for: requestID), !(attempts[key]?.phase.isSettled ?? true) else { return }
        attempts[key]?.phase = .failed(message)
    }

    /// No terminal evidence arrived. The session must not fall back to looking idle.
    public mutating func timedOut(_ requestID: String, _ message: String = "未收到协议终止状态，请重新同步") {
        guard let key = key(for: requestID), !(attempts[key]?.phase.isSettled ?? true) else { return }
        attempts[key]?.phase = .unknown(message)
    }

    public mutating func clear(_ session: SessionReference) { attempts.removeValue(forKey: session.id) }

    private func key(for requestID: String) -> String? {
        attempts.first { $0.value.requestID == requestID }?.key
    }
}

public enum OutboundState: Codable, Equatable, Sendable {
    case draftQueued, submitting, accepted, running, delivered, stoppedBeforeDelivery
    case failed(String)
    case unknown(String)

    public var isEditable: Bool { self == .draftQueued || self == .stoppedBeforeDelivery }
    public var needsExitWarning: Bool {
        switch self {
        case .accepted, .running, .delivered: return false
        default: return true
        }
    }
    public var label: String {
        switch self {
        case .draftQueued: return "Queued"
        case .submitting: return "Sending"
        case .accepted: return "Accepted"
        case .running: return "Running"
        case .delivered: return "Completed"
        case .stoppedBeforeDelivery: return "Paused"
        case .failed(let message): return "Send failed: \(message)"
        case .unknown(let message): return "Send unconfirmed: \(message)"
        }
    }
}

public struct OutboundMessage: Codable, Identifiable, Equatable, Sendable {
    /// Doubles as the runtime idempotency key: a retry reuses it so a reconnect
    /// cannot run the same instruction twice.
    public let id: String
    public let session: SessionReference
    public var text: String
    public var mode: DeliveryMode
    public var state: OutboundState
}

/// Pending messages scoped to host + session. Every accessor takes a
/// SessionReference, so switching sessions cannot surface another session's queue.
public struct OutboundQueue: Codable, Equatable, Sendable {
    private var messages: [OutboundMessage] = []
    private var paused: Set<String> = []
    public init() {}

    public func items(for session: SessionReference) -> [OutboundMessage] {
        messages.filter { $0.session == session }
    }
    public func isPaused(_ session: SessionReference) -> Bool { paused.contains(session.id) }
    public func message(_ id: String) -> OutboundMessage? { messages.first { $0.id == id } }

    @discardableResult
    public mutating func enqueue(_ text: String, for session: SessionReference, mode: DeliveryMode,
                                id: String = UUID().uuidString) -> OutboundMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let message = OutboundMessage(id: id, session: session, text: text, mode: mode, state: .draftQueued)
        messages.append(message)
        return message
    }

    public mutating func edit(_ id: String, text: String) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].state.isEditable else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        messages[index].text = text
        return true
    }
    public mutating func remove(_ id: String) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].state.isEditable else { return false }
        messages.remove(at: index)
        return true
    }

    /// The next message to hand to the runtime, or nil while the queue is paused or
    /// the current turn is still streaming. A paused queue never auto-resumes, so a
    /// stop is not immediately followed by a new turn.
    public func nextPendingID(for session: SessionReference, isStreaming: Bool) -> String? {
        guard !isPaused(session) else { return nil }
        // Do not bypass an unconfirmed instruction with a later queued message.
        guard !items(for: session).contains(where: {
            switch $0.state {
            case .submitting, .accepted, .running, .failed, .unknown: return true
            default: return false
            }
        }) else { return nil }
        return messages.first(where: {
            $0.session == session && $0.state == .draftQueued && (isStreaming ? $0.mode == .steer : true)
        })?.id
    }
    public mutating func nextDelivery(for session: SessionReference, isStreaming: Bool) -> OutboundMessage? {
        guard let id = nextPendingID(for: session, isStreaming: isStreaming),
              let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        messages[index].state = .submitting
        return messages[index]
    }

    public mutating func markAccepted(_ id: String) { setState(id, .accepted) }
    public mutating func markSubmitting(_ id: String) { setState(id, .submitting) }
    public mutating func markRunning(_ id: String) { setState(id, .running) }
    public mutating func markFailed(_ id: String, _ message: String) { setState(id, .failed(message)) }
    /// A dropped connection after acceptance leaves the outcome genuinely unknown.
    /// The message stays visible for an explicit retry instead of being replayed.
    public mutating func markUnknown(_ id: String, _ message: String) { setState(id, .unknown(message)) }

    public mutating func markDelivered(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages.remove(at: index)
    }

    /// Retry keeps the original id so the runtime can reject a duplicate.
    public mutating func retry(_ id: String) -> OutboundMessage? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        switch messages[index].state {
        case .failed, .unknown: messages[index].state = .draftQueued; return messages[index]
        default: return nil
        }
    }

    /// Stopping a turn pauses the queue and parks anything not yet accepted. Text is
    /// preserved: the user resumes it, nothing is silently dropped or re-sent.
    public mutating func pauseForStop(_ session: SessionReference) {
        paused.insert(session.id)
        for index in messages.indices where messages[index].session == session && messages[index].state == .draftQueued {
            messages[index].state = .stoppedBeforeDelivery
        }
    }
    public mutating func resume(_ session: SessionReference) {
        paused.remove(session.id)
        for index in messages.indices where messages[index].session == session && messages[index].state == .stoppedBeforeDelivery {
            messages[index].state = .draftQueued
        }
    }

    /// Never automatically replay instructions whose receipt may have been lost.
    public mutating func recoverAfterRestart() {
        for index in messages.indices {
            let session = messages[index].session
            paused.insert(session.id)
            switch messages[index].state {
            case .draftQueued: messages[index].state = .stoppedBeforeDelivery
            case .submitting, .accepted, .running:
                messages[index].state = .unknown("Restored after restart. Sync the receipt before retrying.")
            default: break
            }
        }
    }
    public func unsentWarning(for session: SessionReference) -> String? {
        let count = items(for: session).filter { $0.state.needsExitWarning }.count
        return count == 0 ? nil : "\(count) pending messages are saved locally."
    }
    public var allPendingCount: Int { messages.count }
    public var exitWarningCount: Int { messages.filter { $0.state.needsExitWarning }.count }
    public var allItems: [OutboundMessage] { messages }

    /// Explicitly discards a rejected instruction, allowing the user to revise it
    /// as a new draft. Unknown outcomes cannot be silently discarded/replayed.
    public mutating func removeFailed(_ id: String) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              case .failed = messages[index].state else { return false }
        messages.remove(at: index); return true
    }

    private mutating func setState(_ id: String, _ state: OutboundState) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].state = state
    }
}
