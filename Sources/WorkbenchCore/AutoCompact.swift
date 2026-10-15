import Foundation

/// Threshold-triggered auto-compaction, ported from ccgui's
/// auto-compact-context.ts. Pure decisions here; transports live in the
/// connections.
public struct AutoCompactSettings: Equatable, Codable, Sendable {
    public var enabled: Bool
    /// Usage percent that triggers a compaction (1...100).
    public var threshold: Int
    public init(enabled: Bool = false, threshold: Int = 80) {
        self.enabled = enabled
        self.threshold = min(100, max(1, threshold))
    }
}

public enum AutoCompact {
    /// Only context that grew past the last threshold-triggered attempt may
    /// fire again, so a failed compaction (or one that left usage above the
    /// threshold) never spins.
    public static func shouldCompact(settings: AutoCompactSettings, usagePercent: Int?,
                                     streaming: Bool, compacting: Bool,
                                     attemptedAtPercent: Int?) -> Bool {
        guard settings.enabled, !streaming, !compacting,
              let usagePercent, usagePercent >= settings.threshold else { return false }
        return attemptedAtPercent.map { usagePercent > $0 } ?? true
    }

    /// After a threshold compaction the task picks itself back up — the point
    /// of auto-compact is not typing 继续 by hand. A manual compaction stays
    /// the user's own move; an error, an interruption, queued messages and a
    /// parked dialog all mean someone else owns what happens next.
    public static func shouldResume(thresholdTriggered: Bool, failed: Bool,
                                    interrupted: Bool, queuedCount: Int, parked: Bool) -> Bool {
        thresholdTriggered && !failed && !interrupted && queuedCount == 0 && !parked
    }
}
