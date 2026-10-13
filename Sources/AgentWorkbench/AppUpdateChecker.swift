import Foundation
import Observation
import WorkbenchCore

/// Checks the public repository's tags for a newer release. Network failure is
/// silent until the user opens Settings; nothing auto-installs — Perch ships
/// source, so the update path is pull + rebuild (see docs/RELEASING.md).
@MainActor @Observable final class AppUpdateChecker {
    static let shared = AppUpdateChecker()
    enum State: Equatable {
        case idle, checking, upToDate, available(String), failed(String)
    }
    private(set) var state: State = .idle
    /// Shown in Settings as the running build's identity.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private static let lastCheckKey = "updates.lastCheck"
    private static let throttle: TimeInterval = 24 * 3600

    func checkThrottled() async {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > Self.throttle else { return }
        await checkNow()
    }

    func checkNow() async {
        if case .checking = state { return }
        state = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        defer { if case .checking = state { state = .failed(L("检查失败")) } }
        var components = URLComponents(string: "https://api.github.com/repos/chenweigao/perch/tags")!
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                state = .failed(L("查询返回 \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
                return
            }
            struct Tag: Decodable { let name: String }
            let names = try JSONDecoder().decode([Tag].self, from: data).map(\.name)
            guard let latest = AppVersionCheck.latestTag(names) else {
                state = .failed(L("发布页暂无可解析版本"))
                return
            }
            let current = currentVersion
            state = AppVersionCheck.compare(current, latest) == .orderedAscending ? .available(latest) : .upToDate
        } catch {
            state = .failed(L("网络不可用"))
        }
    }
}
