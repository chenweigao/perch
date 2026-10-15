import Foundation

/// Row timestamps for the workbench queue. Sources report a last-update time rather
/// than a duration, so the same value reads as a wait on an actionable row and as a
/// last update everywhere else. A source that reports no timestamp returns nil
/// instead of a fabricated "just now".
public enum SessionTime {
    /// Sidebar chrome has one compact time slot; full wording stays in previews.
    public static func compactLabel(since timestamp: Double, now: Date = Date(),
                                    locale: Locale = AppLanguage.current.resolvedLocale) -> String? {
        guard timestamp > 0 else { return nil }
        let minutes = Int(max(0, now.timeIntervalSince1970 - timestamp) / 60)
        if minutes == 0 { return L("刚刚", locale: locale) }
        if minutes < 60 { return L("\(minutes)分", locale: locale) }
        if minutes < 1440 { return L("\(minutes / 60)时", locale: locale) }
        if minutes < 1440 * 100 { return L("\(minutes / 1440)天", locale: locale) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "yy/MM"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    public static func label(since timestamp: Double, waiting: Bool, now: Date = Date(),
                             locale: Locale = AppLanguage.current.resolvedLocale) -> String? {
        guard timestamp > 0 else { return nil }
        // A remote clock can run ahead of this Mac, so a negative age is reported as
        // fresh rather than as a negative duration.
        let seconds = max(0, now.timeIntervalSince1970 - timestamp)
        guard seconds >= 60 else { return waiting ? L("刚开始等待", locale: locale) : L("刚刚更新", locale: locale) }
        let elapsed = duration(seconds, locale: locale)
        return waiting ? L("已等待 \(elapsed)", locale: locale) : L("\(elapsed)前", locale: locale)
    }

    private static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return L("\(minutes) 分钟", locale: locale) }
        let hours = minutes / 60
        return hours < 24 ? L("\(hours) 小时", locale: locale) : L("\(hours / 24) 天", locale: locale)
    }
}
