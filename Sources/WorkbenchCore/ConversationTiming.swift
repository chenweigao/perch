import Foundation

/// Client wall time for one turn, including transport, tools and user waits.
/// A turn discovered after it started keeps an explicitly observed-only clock.
public struct ConversationTiming: Equatable, Sendable {
    public var turnID: String?
    public var startedAt: Date
    public var observedOnly: Bool
    public var endedAt: Date?
    public var waitingSince: Date?
    public var waitingSeconds: TimeInterval = 0

    public func elapsed(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    public func waiting(at now: Date) -> TimeInterval {
        min(elapsed(at: now), waitingSeconds + (waitingSince.map { max(0, (endedAt ?? now).timeIntervalSince($0)) } ?? 0))
    }

    public static func duration(_ interval: TimeInterval, chinese: Bool) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600, minutes = seconds / 60 % 60, remainder = seconds % 60
        let paddedSeconds = String(format: "%02d", remainder)
        if chinese {
            if hours > 0 { return "\(hours)小时\(minutes)分\(paddedSeconds)秒" }
            return minutes > 0 ? "\(minutes)分\(paddedSeconds)秒" : "\(remainder)秒"
        }
        if hours > 0 { return "\(hours)h \(minutes)m \(remainder)s" }
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }
}

/// Owned by a connection, not a view. Session selection never discards clocks.
public struct ConversationTimings: Equatable {
    public private(set) var turns: [String: ConversationTiming] = [:]
    private var submissions: [String: Date] = [:]
    public init() {}

    public mutating func submitted(_ requestID: String, at now: Date = Date()) {
        if submissions[requestID] == nil { submissions[requestID] = now }
    }

    public mutating func finished(sessionID: String, requestID: String, at now: Date = Date()) {
        if let current = turns[sessionID], let turn = current.turnID {
            guard turn == requestID, current.endedAt == nil else { return }
        }
        observe(sessionID: sessionID, turnID: requestID, requestID: requestID, running: true, waiting: false, at: now)
        observe(sessionID: sessionID, running: false, waiting: false, at: now)
    }

    public mutating func observe(sessionID: String, turnID: String? = nil, requestID: String? = nil,
                                 running: Bool, waiting: Bool, at now: Date = Date()) {
        let submittedAt = requestID.flatMap { submissions[$0] }
        var timing = turns[sessionID]
        let changedTurn = turnID != nil && timing?.turnID != nil && timing?.turnID != turnID
        if !running && changedTurn {
            guard let submittedAt else { turns.removeValue(forKey: sessionID); return }
            timing = ConversationTiming(turnID: turnID, startedAt: submittedAt, observedOnly: false)
        }
        if running && (timing == nil || timing?.endedAt != nil || changedTurn) {
            timing = ConversationTiming(turnID: turnID, startedAt: submittedAt ?? now,
                                        observedOnly: submittedAt == nil)
        }
        guard var current = timing else { return }
        // A catalog can arrive before the selected turn's identity. Bind it later
        // without resetting the observation clock or losing the request start.
        if running {
            if let turnID { current.turnID = turnID }
            if let submittedAt, current.observedOnly {
                current.startedAt = submittedAt
                current.observedOnly = false
            }
        }
        if !running && current.endedAt == nil { current.endedAt = now }
        let until = current.endedAt ?? now
        if waiting && running {
            if current.waitingSince == nil { current.waitingSince = now }
        } else if let since = current.waitingSince {
            current.waitingSeconds += max(0, until.timeIntervalSince(since))
            current.waitingSince = nil
        }
        turns[sessionID] = current
    }
}
