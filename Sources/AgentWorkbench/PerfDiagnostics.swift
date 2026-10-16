import AppKit
import OSLog
import SwiftUI

/// Opt-in render-performance diagnostics for release builds, in the spirit of
/// Zed/ghostty's signpost workflow. Off by default: each probe costs one lock
/// read of a Bool, and the measured hot paths keep their zero-overhead shape.
/// When on, stage timings aggregate in memory and every probe also fires an
/// OSSignpost for Instruments' Points of Interest track. The export is a plain
/// JSON report. Probes run on whichever thread measured the work, so the store
/// is lock-guarded rather than actor-isolated.
final class PerfDiagnostics: @unchecked Sendable {
    static let shared = PerfDiagnostics()

    private struct State {
        var enabled = false
        var stages: [String: (count: Int, totalMS: Double)] = [:]
        var counters: [String: Int] = [:]
    }
    private let state: OSAllocatedUnfairLock<State>
    private let signposter = OSSignposter(subsystem: "dev.agentworkbench.mac",
                                          category: .pointsOfInterest)

    private init() {
        let stored = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        state = OSAllocatedUnfairLock(initialState: State(enabled: stored))
    }

    private static let defaultsKey = "perch.perfDiagnostics"

    var enabled: Bool {
        state.withLock { $0.enabled }
    }

    /// Settings toggles this; turning it off clears the recording.
    func setEnabled(_ value: Bool) {
        state.withLock {
            $0.enabled = value
            if !value { $0.stages = [:]; $0.counters = [:] }
        }
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
    }

    /// Probe shape: `let probe = PerfDiagnostics.begin(); defer { PerfDiagnostics.end("stage", probe) }`.
    /// A disabled probe returns 0 and `end` exits on it, so hot paths never
    /// allocate or call through when diagnostics are off.
    static func begin() -> TimeInterval {
        shared.enabled ? CACurrentMediaTime() : 0
    }

    static func end(_ stage: String, _ since: TimeInterval) {
        guard since > 0 else { return }
        let ms = (CACurrentMediaTime() - since) * 1_000
        shared.state.withLock {
            let old = $0.stages[stage] ?? (0, 0)
            $0.stages[stage] = (old.count + 1, old.totalMS + ms)
        }
        shared.signposter.emitEvent("probe", "\(stage): \(ms)ms")
    }

    static func count(_ key: String) {
        guard shared.enabled else { return }
        shared.state.withLock { $0.counters[key, default: 0] += 1 }
    }

    @MainActor
    func report() -> String {
        let snapshot = state.withLock { $0 }
        var document: [String: Any] = [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "generated": ISO8601DateFormatter().string(from: Date()),
            "counters": snapshot.counters,
        ]
        document["stages"] = snapshot.stages.mapValues {
            ["count": $0.count, "total_ms": $0.totalMS, "avg_ms": $0.totalMS / Double(max(1, $0.count))]
        }
        let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    var isEmpty: Bool { state.withLock { $0.stages.isEmpty && $0.counters.isEmpty } }

    @MainActor
    func exportReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "perch-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report().write(to: url, atomically: true, encoding: .utf8)
    }
}
