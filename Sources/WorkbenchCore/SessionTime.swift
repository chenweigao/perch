import Foundation

/// Row timestamps for the workbench queue. Sources report a last-update time rather
/// than a duration, so the same value reads as a wait on an actionable row and as a
/// last update everywhere else. A source that reports no timestamp returns nil
/// instead of a fabricated "just now".
public enum SessionTime {
    /// Sidebar chrome has one compact time slot; full wording stays in previews. Like
    /// Mail, it names the moment rather than the age: the time today, then 昨天, the
    /// weekday within a week, and a locale-ordered date beyond, so 3/26 never reads as
    /// a day/month puzzle. The label changes only when the day does.
    public static func compactLabel(since timestamp: Double, now: Date = Date(),
                                    locale: Locale = AppLanguage.current.resolvedLocale,
                                    timeZone: TimeZone = .current) -> String? {
        guard timestamp > 0 else { return nil }
        // A remote clock can run ahead of this Mac; a future update reads as now.
        let date = Date(timeIntervalSince1970: min(timestamp, now.timeIntervalSince1970))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        // Relative date formatting compares against the real clock, not `now`.
        if days == 1 { return L("昨天", locale: locale) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch days {
        case 0: formatter.setLocalizedDateFormatFromTemplate("jm")
        case 2..<7: formatter.setLocalizedDateFormatFromTemplate("EEE")
        default:
            let thisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            formatter.setLocalizedDateFormatFromTemplate(thisYear ? "Md" : "yM")
        }
        return formatter.string(from: date)
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
