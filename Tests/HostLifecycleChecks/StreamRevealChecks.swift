import AppKit
import Observation
import SwiftUI
import WorkbenchCore

@MainActor @Observable private final class StreamingFixture {
    var messages: [KimiMessage] = []
    var running = true
    var systemReduceMotion: Bool?
}
private struct StreamingFixtureView: View {
    let model: StreamingFixture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollView {
            ConversationTranscript(messages: model.messages, sessionId: "reveal-fixture", isRunning: model.running)
        }.frame(width: 720, height: 500)
            .environment(\.conversationReduceMotion, false)
            .onAppear { model.systemReduceMotion = reduceMotion }
    }
}
@MainActor private func revealSettle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
@MainActor private func textViews(_ view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
}
@MainActor func checkProductionStreamReveal() async throws {
    let driver = RevealFrameDriver.shared
    var calls = 0
    _ = driver.clock.frame { calls += 1 }
    await revealSettle(150)
    precondition(calls == 1 && driver.pendingFrameCount == 0 && !driver.isRunning,
                 "A frame request must be consumed once and stop the display link")
    let model = StreamingFixture()
    func messages(_ text: String) throws -> [KimiMessage] {
        let json: [[String: Any]] = [
            ["id": "u", "role": "user", "created_at": "0", "content": [["type": "text", "text": "prompt"]]],
            ["id": "a", "role": "assistant", "created_at": "1", "content": [["type": "text", "text": text]]]
        ]
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: json))
    }
    let prefix = "VISIBLE_START "
    model.messages = try messages(prefix)
    let projection = ConversationPresentationModel(key: "check").update(.init(messages: model.messages, isRunning: true, language: "en"))
    precondition(projection.displayedRows(activity: { _ in nil }).contains { $0.entry.presentation == .progress && $0.activity == nil })
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let host = NSHostingView(rootView: StreamingFixtureView(model: model))
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    // Wait for the first real row, not an assumed cold SwiftUI layout duration.
    for _ in 0..<100 {
        if textViews(host).contains(where: { $0.string.contains("VISIBLE_START") }) { break }
        await revealSettle(20)
    }
    precondition(textViews(host).contains { $0.string.contains("VISIBLE_START") })
    let requestedBefore = driver.requestedFrameCount
    let complete = prefix + String(repeating: "中文流式文本 ", count: 30) + "VISIBLE_END"
    model.messages = try messages(complete)
    await revealSettle(40)
    let during = textViews(host).map(\.string).joined(separator: "\n")
    precondition(during.contains("VISIBLE_START"), "Mounted reply must remain visible")
    let partialObserved = !during.contains("VISIBLE_END")
    await revealSettle(450)
    let after = textViews(host).map(\.string).joined(separator: "\n")
    let reduced = model.systemReduceMotion == true
    fputs("Stream fixture: systemReduceMotion=\(String(describing: model.systemReduceMotion)), new frame requests=\(driver.requestedFrameCount - requestedBefore)\n", stderr)
    if reduced {
        precondition(driver.requestedFrameCount == requestedBefore, "System Reduce Motion must bypass reveal")
    } else {
        precondition(driver.requestedFrameCount > requestedBefore, "Production transcript must arm the actual frame driver")
    }
    precondition(after.contains(complete), "The full received Unicode reply must eventually be visible")
    precondition(driver.pendingFrameCount == 0 && !driver.isRunning, "A completed reveal must leave no callbacks")
    model.messages = try messages(complete + "\n\n| A | B |\n| --- | --- |\n| one | two |\n\nFINAL_CHUNK")
    model.running = false
    await revealSettle(300)
    precondition(textViews(host).map(\.string).joined(separator: "\n").contains("FINAL_CHUNK"),
                 "Completion with a final chunk and fallback renderer must never be truncated")
    print("Observed partial live tail at sample: \(partialObserved); pacing deadlines are verified with the deterministic core clock")
    print("PASS: production one-shot frame lifecycle, visible live reply, partial tail, complete Unicode text and idle cleanup")
}
