import Foundation
import WorkbenchCore

/// Per-session auto-compact settings, persisted per host+session key.
@MainActor final class AutoCompactStore: ObservableObject {
    static let shared = AutoCompactStore()
    @Published private var entries: [String: AutoCompactSettings] = [:]
    private static let defaultsKey = "autoCompact.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: AutoCompactSettings].self, from: data) {
            entries = decoded
        }
    }

    func settings(host: UUID, session: String) -> AutoCompactSettings {
        entries["\(host.uuidString):\(session)"] ?? AutoCompactSettings()
    }
    func set(host: UUID, session: String, _ settings: AutoCompactSettings) {
        entries["\(host.uuidString):\(session)"] = settings
        persist()
    }
    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.defaultsKey)
    }
}
