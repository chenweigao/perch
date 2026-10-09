import Foundation

/// What became of a session that was mid-turn when the workbench lost sight of
/// it — app quit, sleep, or a dropped connection. Resolved once per source per
/// reconnect, so the outcome is read in one place instead of being rediscovered
/// session by session.
public enum RestoreOutcome: String, Equatable, Sendable {
    case resumed, completedAway, attentionRequired, failed, interrupted, missing

    public var label: String {
        switch self {
        case .resumed: return "仍在运行"
        case .completedAway: return "已完成"
        case .attentionRequired: return "等待你处理"
        case .failed: return "出错"
        case .interrupted: return "已中断"
        case .missing: return "会话已不在"
        }
    }

    public var symbol: String {
        switch self {
        case .resumed: return "arrow.triangle.2.circlepath"
        case .completedAway: return "checkmark.circle"
        case .attentionRequired: return "hand.raised"
        case .failed: return "xmark.octagon"
        case .interrupted: return "stop.circle"
        case .missing: return "questionmark.square.dashed"
        }
    }

    /// Outcomes the user should look at, not just acknowledge.
    public var needsAttention: Bool {
        switch self {
        case .attentionRequired, .failed, .interrupted, .missing: return true
        case .resumed, .completedAway: return false
        }
    }
}

/// The live facts an outcome is resolved from. `completed` is each source's own
/// completion signal for the watched work: Kimi's latest turn finishing, or a
/// native session's completion count having advanced past the baseline.
public struct SessionRestoreProbe: Equatable, Sendable {
    public let exists: Bool
    public let archived: Bool
    public let busy: Bool
    public let pendingInteraction: Bool
    public let failed: Bool
    public let completed: Bool

    public init(exists: Bool, archived: Bool = false, busy: Bool = false,
                pendingInteraction: Bool = false, failed: Bool = false, completed: Bool = false) {
        self.exists = exists; self.archived = archived; self.busy = busy
        self.pendingInteraction = pendingInteraction; self.failed = failed; self.completed = completed
    }
}

public enum RestoreResolution {
    /// Waiting for input outranks still-running, and a turn that started after
    /// the watched one makes an old failure irrelevant. An archived session is
    /// filed work rather than a lost one, so it stays out of the report.
    public static func outcome(_ probe: SessionRestoreProbe) -> RestoreOutcome? {
        guard probe.exists else { return .missing }
        if probe.archived { return nil }
        if probe.pendingInteraction { return .attentionRequired }
        if probe.busy { return .resumed }
        if probe.failed { return .failed }
        if probe.completed { return .completedAway }
        return .interrupted
    }
}

public struct RestoredSession: Equatable, Sendable, Identifiable {
    public let reference: SessionReference
    public let title: String
    public let hostName: String
    public let outcome: RestoreOutcome
    public var id: String { reference.id }

    public init(reference: SessionReference, title: String, hostName: String, outcome: RestoreOutcome) {
        self.reference = reference; self.title = title; self.hostName = hostName; self.outcome = outcome
    }
}

extension SessionReference {
    /// Inverse of `id` for baseline keys persisted by earlier launches. Agent
    /// sessions carry host, kind and session id; terminal rows resolve to nil
    /// because their reattachment is owned by the pending-restoration list.
    public init?(restoreID: String) {
        let parts = restoreID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let host = UUID(uuidString: String(parts[0])),
              let kind = SessionKind(rawValue: String(parts[1])), kind != .terminal else { return nil }
        self.init(hostID: host, terminalID: parts[2...].joined(separator: ":"), kind: kind)
    }
}
