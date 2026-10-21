import AppKit
import OSLog
import SwiftUI
import WorkbenchCore

/// Opt-in render-performance diagnostics for release builds, in the spirit of
/// Zed/ghostty's signpost workflow. Off by default: each probe costs one lock
/// read of a Bool, and the measured hot paths keep their zero-overhead shape.
/// When on, stage timings aggregate in memory and every probe also fires an
/// OSSignpost for Instruments' Points of Interest track. Main-thread probes
/// also enter the frame-hitch journal, and FrameHitchMonitor feeds display
/// frames, so each slow frame is reported with the work that overlapped it.
/// The export is a plain JSON report. Probes run on whichever thread measured
/// the work, so the store is lock-guarded rather than actor-isolated.
final class PerfDiagnostics: @unchecked Sendable {
    static let shared = PerfDiagnostics()
    /// Posted after `setEnabled`; FrameHitchMonitor starts or stops on it.
    static let enabledDidChange = Notification.Name("PerchPerfDiagnosticsEnabledDidChange")

    private struct State {
        var enabled = false
        var stages: [String: (count: Int, totalMS: Double)] = [:]
        var counters: [String: Int] = [:]
        var frames = FrameHitchRecorder()
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

    /// Settings toggles this; turning it off clears the recording. Turning it
    /// on starts a new frame recording at this moment.
    func setEnabled(_ value: Bool) {
        let now = CACurrentMediaTime()
        state.withLock {
            let changed = $0.enabled != value
            $0.enabled = value
            if !value {
                $0.stages = [:]
                $0.counters = [:]
                $0.frames = FrameHitchRecorder()
            } else if changed {
                $0.frames = FrameHitchRecorder(origin: now)
            }
        }
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.enabledDidChange, object: nil)
    }

    /// Probe shape: `let probe = PerfDiagnostics.begin(); defer { PerfDiagnostics.end("stage", probe) }`.
    /// A disabled probe returns 0 and `end` exits on it, so hot paths never
    /// allocate or call through when diagnostics are off.
    static func begin() -> TimeInterval {
        shared.enabled ? CACurrentMediaTime() : 0
    }

    /// `detail` is evaluated only while recording: kinds and counts, never
    /// message text. Main-thread intervals also enter the frame journal; pass
    /// `journal: false` for an interval that spans suspension points, which is
    /// not contiguous main-thread work and would be blamed for other work's frames.
    static func end(_ stage: String, _ since: TimeInterval, detail: @autoclosure () -> String? = nil,
                    journal: Bool = true) {
        guard since > 0 else { return }
        let now = CACurrentMediaTime()
        let ms = (now - since) * 1_000
        let note = detail()
        let journaled = journal && Thread.isMainThread
        shared.state.withLock {
            // A probe that began before diagnostics were turned off records nothing.
            guard $0.enabled else { return }
            let old = $0.stages[stage] ?? (0, 0)
            $0.stages[stage] = (old.count + 1, old.totalMS + ms)
            if journaled { $0.frames.work(stage: stage, start: since, end: now, detail: note) }
        }
        shared.signposter.emitEvent("probe", "\(stage): \(ms)ms")
    }

    static func count(_ key: String) {
        guard shared.enabled else { return }
        shared.state.withLock { $0.counters[key, default: 0] += 1 }
    }

    /// One display-link callback, from FrameHitchMonitor on the main thread.
    func recordFrame(timestamp: CFTimeInterval, duration: CFTimeInterval, scrolling: Bool, phase: String?) {
        let hitch: FrameHitchRecorder.Hitch? = state.withLock {
            guard $0.enabled else { return nil }
            return $0.frames.frame(timestamp: timestamp, duration: duration, scrolling: scrolling, phase: phase)
        }
        if let hitch { signposter.emitEvent("hitch", "\(hitch.gapMS)ms") }
    }

    /// The frame source restarted; the pause before its next frame is not a hitch.
    func breakFrameChain() {
        state.withLock { $0.frames.breakChain() }
    }

    func frameReport() -> FrameHitchRecorder.Report {
        state.withLock { $0.frames.report() }
    }

    /// Settings' calibration: blocks the main thread inside a probe for a known
    /// time, so an exported report proves the recorder catches such a stall.
    @MainActor static func injectCalibrationStall(milliseconds: Double = 120) {
        guard shared.enabled else { return }
        let probe = begin()
        defer { end("calibration_stall", probe, detail: "\(Int(milliseconds))ms") }
        let deadline = CACurrentMediaTime() + milliseconds / 1_000
        while CACurrentMediaTime() < deadline {
            Thread.sleep(forTimeInterval: max(0.001, deadline - CACurrentMediaTime()))
        }
    }

    @MainActor
    func report() -> String {
        let snapshot = state.withLock { $0 }
        let info = Bundle.main.infoDictionary
        var document: [String: Any] = [
            "version": info?["CFBundleShortVersionString"] as? String ?? "",
            "bundle_version": info?["CFBundleVersion"] as? String ?? "",
            "source_revision": info?["PerchSourceRevision"] as? String ?? "",
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "generated": ISO8601DateFormatter().string(from: Date()),
            "counters": snapshot.counters,
        ]
        document["stages"] = snapshot.stages.mapValues {
            ["count": $0.count, "total_ms": $0.totalMS, "avg_ms": $0.totalMS / Double(max(1, $0.count))]
        }
        if let frames = try? JSONEncoder().encode(snapshot.frames.report()),
           let object = try? JSONSerialization.jsonObject(with: frames) {
            document["frames"] = object
        }
        let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    var isEmpty: Bool { state.withLock { $0.stages.isEmpty && $0.counters.isEmpty && $0.frames.isEmpty } }

    @MainActor
    func exportReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "perch-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report().write(to: url, atomically: true, encoding: .utf8)
    }
}
