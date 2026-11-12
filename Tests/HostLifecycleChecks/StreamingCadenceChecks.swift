import AppKit
import Observation
import QuartzCore
import SwiftUI
import WorkbenchCore

@MainActor @Observable private final class CadenceFixture {
    var messages: [KimiMessage] = []
    var source = "正文连续吐字验收。"
    var running = true
}

private struct CadenceSurface: View {
    let model: CadenceFixture
    let native: Bool
    var body: some View {
        Group {
            if native {
                ScrollViewReader { proxy in
                    ConversationScrollView(onContentSizeChange: { proxy.scrollTo("cadence-tail", anchor: .bottom) }) {
                        ConversationTranscript(messages: model.messages, sessionId: "cadence-fixture", isRunning: model.running)
                        Color.clear.frame(height: 1).id("cadence-tail")
                    } bar: { Color.clear.frame(height: 26) }
                }
            } else {
                ScrollView { SmoothReplyMarkdown(source: model.source, streaming: model.running,
                    sessionID: "cadence-hosted", messageID: "a", preparation: nil) }
            }
        }.frame(width: 720, height: 500).preferredColorScheme(.light)
            .environment(\.streamingReduceMotionOverride, false)
            .environment(\.conversationReduceMotion, false)
    }
}

@MainActor private func cadenceTexts(_ view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(cadenceTexts)
}

@MainActor private final class CadenceFrames: NSObject {
    struct Sample: Codable { let time: Double; let count: Int }
    weak var host: NSView?
    var samples: [Sample] = []
    private var link: CADisplayLink?
    private let captures: URL?
    init(host: NSView, captures: URL?) { self.host = host; self.captures = captures }
    func start() {
        let link = host!.window!.screen!.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        self.link = link; link.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard let host else { return }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let count = cadenceTexts(host).first { $0.string.hasPrefix("正文连续吐字验收。") }?.string.utf16.count ?? 0
        samples.append(Sample(time: CACurrentMediaTime(), count: count))
        if let captures, let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try? image.representation(using: .jpeg, properties: [.compressionFactor: 0.65])?
                .write(to: captures.appendingPathComponent(String(format: "frame-%04d.jpg", samples.count)))
        }
    }
    func stop() { link?.invalidate(); link = nil }
}

/// Frequent incoming snapshots must not cancel the next visual update. Observe
/// the mounted text buffers on display callbacks, independently of input writes.
@MainActor func checkStreamingCadence() async throws {
    for native in [true, false] {
        let mode = native ? "native" : "hosted"
        var passed = false
        var lastFailure = ""
        for attempt in 1...2 {
            let model = CadenceFixture()
            func messages(_ text: String) throws -> [KimiMessage] {
                let json: [[String: Any]] = [
                    ["id": "u", "role": "user", "created_at": "0", "content": [["type": "text", "text": "连续输出"]]],
                    ["id": "a", "role": "assistant", "created_at": "1", "content": [["type": "text", "text": text]]]
                ]
                return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: json))
            }
            model.messages = try messages(model.source)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: CadenceSurface(model: model, native: native))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.close() }
            for _ in 0..<100 {
                if cadenceTexts(host).contains(where: { $0.string.hasPrefix(model.source) }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            precondition(cadenceTexts(host).contains { $0.string.hasPrefix(model.source) }, "The cadence fixture must mount its text before input")
            let captures = ProcessInfo.processInfo.environment["PERCH_CADENCE_CAPTURES"].map { URL(fileURLWithPath: $0).appendingPathComponent(mode) }
            let output = ProcessInfo.processInfo.environment["PERCH_CADENCE_OUTPUT"]
                ?? ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"].map { $0 + "/cadence" }
            let folder = output.map { URL(fileURLWithPath: $0).appendingPathComponent(mode) }
            for directory in [captures, folder].compactMap({ $0 }) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let recorder = CadenceFrames(host: host, captures: captures)
            recorder.start()
            defer { recorder.stop() }
            let started = CACurrentMediaTime()
            var inputs: [Double] = []
            for index in 0..<220 {
                try await Task.sleep(for: .milliseconds(10))
                model.source += "第\(index)段中文正在连续输出，检查平滑节奏。"
                if native { model.messages = try messages(model.source) }
                inputs.append(CACurrentMediaTime())
            }
            let ended = CACurrentMediaTime()
            // Completion has a separate immediate contract; observing only this
            // final state used to miss both frame starvation and periodic jumps.
            model.running = false
            for _ in 0..<100 {
                if cadenceTexts(host).contains(where: { $0.string == model.source }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            recorder.stop()
            precondition(cadenceTexts(host).contains { $0.string == model.source }, "Completion must expose the exact newest source")
            let during = recorder.samples.filter { $0.time > started + 0.25 && $0.time < ended }
            var lastCount = -1
            var changed: [CadenceFrames.Sample] = []
            for sample in during where sample.count > 0 {
                precondition(sample.count >= lastCount, "Visible text must not replay or shrink during continuous input")
                if sample.count != lastCount { changed.append(sample); lastCount = sample.count }
            }
            let sortedGaps = zip(changed, changed.dropFirst()).map { ($1.time - $0.time) * 1_000 }.sorted()
            let p95Gap = sortedGaps.isEmpty ? .infinity : sortedGaps[Int(Double(sortedGaps.count - 1) * 0.95)]
            let maxGap = sortedGaps.last ?? .infinity
            let intervals = zip(inputs, inputs.dropFirst()).map { ($1 - $0) * 1_000 }.sorted()
            let report: [String: Any] = ["mode": mode, "attempt": attempt, "input_events": inputs.count,
                "scope": "Mounted text buffers sampled on display callbacks; not GPU-presented FPS",
                "input_p95_gap_ms": intervals[Int(Double(intervals.count - 1) * 0.95)],
                "display_samples_during_input": during.count, "text_updates_during_input": changed.count,
                "p95_text_update_gap_ms": p95Gap, "max_text_update_gap_ms": maxGap,
                "final_utf16": model.source.utf16.count,
                "samples": recorder.samples.map { ["time": $0.time - started, "count": Double($0.count)] }]
            if let folder {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent("cadence.json"))
            }
            print("CADENCE: \(mode) attempt=\(attempt) inputs=\(inputs.count) visible updates=\(changed.count)/\(during.count) p95 gap=\(p95Gap) ms longest gap=\(maxGap) ms")
            if ProcessInfo.processInfo.environment["PERCH_CADENCE_ALLOW_BASELINE_FAILURE"] == "1"
                || (changed.count >= 30 && p95Gap < 100 && maxGap < 400) {
                passed = true
                break
            }
            lastFailure = "changed=\(changed.count) p95=\(p95Gap)ms max=\(maxGap)ms"
        }
        precondition(passed,
            "Continuous input must keep visibly advancing; waiting for input to stop or long pauses are not smooth streaming (\(lastFailure))")
    }
    if ProcessInfo.processInfo.environment["PERCH_CADENCE_ALLOW_BASELINE_FAILURE"] == "1" {
        print("BASELINE: visual cadence captured with continuity assertions disabled for the diagnostic control")
    } else {
        print("PASS: native and hosted text visibly advance during uninterrupted input and complete exactly")
    }
}
