import Foundation

/// What the process actually answering requests reports about itself. The package
/// installed on disk says nothing about it: upgrading a CLI leaves an already
/// running daemon executing the code it started with, so both versions are read
/// separately and compared.
public struct RunningRuntime: Equatable, Sendable {
    public let version: String?
    /// The service's own start timestamp, as reported. Kept as text because a
    /// runtime that omits or malforms it must not turn into a fabricated date.
    public let startedAt: String?
    public init(version: String? = nil, startedAt: String? = nil) {
        self.version = version; self.startedAt = startedAt
    }
    public static let unknown = RunningRuntime()
}

/// A verdict only when both sides were readable. An unreadable version stays
/// `unknown` rather than being reported as up to date.
public enum RuntimeFreshness: Equatable, Sendable {
    case unknown
    case current(String)
    case stale(installed: String, running: String)

    public var isStale: Bool { if case .stale = self { return true }; return false }
}

public enum RuntimeVersion {
    /// Parses `2.0.2`, `kimi 2.0.2`, `omp/17.1.4` or `codex-cli 0.155.0-alpha.16.3`.
    /// A prerelease suffix is kept, so two candidates do not compare equal.
    public static func parse(_ output: String) -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "[0-9]+\\.[0-9]+\\.[0-9]+(?:-[A-Za-z0-9.-]+)?"
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[match])
    }

    public static func compare(installed: String?, running: String?) -> RuntimeFreshness {
        guard let installed = installed.flatMap(parse), let running = running.flatMap(parse) else { return .unknown }
        return installed == running ? .current(running) : .stale(installed: installed, running: running)
    }

    /// The version line for a setup check row: what is installed, what is serving,
    /// and when that process started.
    public static func detail(installed: String?, running: RunningRuntime,
                              locale: Locale = AppLanguage.current.resolvedLocale) -> String {
        let started = startedLabel(running.startedAt, locale: locale)
        let head: String
        switch compare(installed: installed, running: running.version) {
        case .current(let version):
            head = L("\(version)（安装与运行进程一致）", locale: locale)
        case .stale(let onDisk, let serving):
            head = L("已安装 \(onDisk)，运行进程仍是 \(serving)", locale: locale)
        case .unknown:
            let known = parse(installed ?? "") ?? running.version.flatMap(parse)
            guard let known else { return started ?? "" }
            head = known
        }
        guard let started else { return head }
        return head + " · " + started
    }

    /// Non-blocking notice for a service older than the package on disk. Perch only
    /// reports it: stopping someone else's running agent is never implicit.
    public static func staleNotice(agent: String, installed: String, running: String,
                                   locale: Locale = AppLanguage.current.resolvedLocale) -> String {
        L("远端已安装 \(agent) \(installed)，但正在服务的进程仍是 \(running)。重启该服务后新版本才会生效；Perch 不会替你终止运行中的服务。", locale: locale)
    }

    /// `started_at` rendered in local time, or nil when it is absent or malformed.
    public static func startedLabel(_ timestamp: String?,
                                    locale: Locale = AppLanguage.current.resolvedLocale) -> String? {
        guard let date = startDate(timestamp) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return L("\(formatter.string(from: date)) 启动", locale: locale)
    }

    /// Runtimes differ in fractional seconds and in whether the UTC offset carries a
    /// colon, so each accepted spelling is tried instead of assuming one.
    public static func startDate(_ timestamp: String?) -> Date? {
        guard let timestamp, !timestamp.isEmpty else { return nil }
        let internet: ISO8601DateFormatter.Options = [.withInternetDateTime]
        let basicZone = internet.subtracting(.withColonSeparatorInTimeZone)
        for options in [internet, internet.union(.withFractionalSeconds),
                        basicZone, basicZone.union(.withFractionalSeconds)] {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = options
            if let date = formatter.date(from: timestamp) { return date }
        }
        return nil
    }
}
