import Foundation

/// Row timestamps for the workbench queue. Sources report a last-update time rather
/// than a duration, so the same value reads as a wait on an actionable row and as a
/// last update everywhere else. A source that reports no timestamp returns nil
/// instead of a fabricated "just now".
public enum SessionTime {
    public static func label(since timestamp: Double, waiting: Bool, now: Date = Date()) -> String? {
        guard timestamp > 0 else { return nil }
        // A remote clock can run ahead of this Mac, so a negative age is reported as
        // fresh rather than as a negative duration.
        let seconds = max(0, now.timeIntervalSince1970 - timestamp)
        guard seconds >= 60 else { return waiting ? "刚开始等待" : "刚刚更新" }
        return waiting ? "已等待 \(duration(seconds))" : "\(duration(seconds))前"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours) 小时" : "\(hours / 24) 天"
    }
}
