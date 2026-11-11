import AppKit
import Observation
import SwiftUI
import WorkbenchCore

@MainActor @Observable private final class StreamingFixture {
    var messages: [KimiMessage] = []
    var running = true
    var reduceMotion = false
}

private struct StreamingFixtureView: View {
    let model: StreamingFixture
    var body: some View {
        ScrollView {
            ConversationTranscript(messages: model.messages, sessionId: "streaming-rendering-fixture", isRunning: model.running)
        }.frame(width: 720, height: 500)
            .environment(\.conversationReduceMotion, model.reduceMotion)
    }
}

@MainActor private func streamingDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(streamingDescendants)
}

@MainActor private func streamingSettle(_ host: NSView, milliseconds: Int = 20) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    CATransaction.flush()
}

@MainActor private func waitForStreaming(_ host: NSView, _ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        await streamingSettle(host)
    }
    return predicate()
}

@MainActor func checkProductionStreamingRendering() async throws {
    let model = StreamingFixture()
    func messages(_ text: String) throws -> [KimiMessage] {
        let json: [[String: Any]] = [
            ["id": "u", "role": "user", "created_at": "0", "content": [["type": "text", "text": "prompt"]]],
            ["id": "a", "role": "assistant", "created_at": "1", "content": [["type": "text", "text": text]]]
        ]
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: json))
    }
    func nativeRows(_ host: NSView) -> [NativeAssistantMessageView] {
        streamingDescendants(host).compactMap { $0 as? NativeAssistantMessageView }
    }
    func textViews(_ view: NSView) -> [ReplyTextView] {
        streamingDescendants(view).compactMap { $0 as? ReplyTextView }
    }
    func renderedText(_ host: NSView) -> String {
        textViews(host).map(\.string).joined(separator: "\n")
    }

    let prefix = (0..<9).map { "Paragraph \($0) 中文 👩🏽‍💻 é" }.joined(separator: "\n\n")
    model.messages = try messages(prefix)
    let projection = ConversationPresentationModel(key: "streaming-rendering-check").update(
        .init(messages: model.messages, isRunning: true, language: "en"))
    precondition(projection.displayedRows(activity: { _ in nil }).contains {
        $0.entry.presentation == .progress && $0.activity == nil
    })

    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.close() }
    let host = NSHostingView(rootView: StreamingFixtureView(model: model))
    window.contentView = host
    window.makeKeyAndOrderFront(nil)

    guard await waitForStreaming(host, { nativeRows(host).count == 1 && renderedText(host).contains("Paragraph 8") }) else {
        preconditionFailure("An admitted live reply must mount its native row")
    }
    let row = nativeRows(host)[0]
    guard let actions = row.subviews.first(where: { !($0 is NativeAssistantStackView) }) else {
        preconditionFailure("The native assistant row lost its actions view")
    }
    precondition(actions.isHidden && actions.frame == .zero, "Live message actions must not reserve layout space")
    let originalTexts = textViews(row)
    precondition(originalTexts.count == 2, "Nine paragraphs must form one stable block and one tail block")
    let selection = (originalTexts[0].string as NSString).range(of: "Paragraph 2")
    originalTexts[0].setSelectedRange(selection)

    let diagnostics = PerfDiagnostics.shared
    diagnostics.setEnabled(false)
    let monitor = FrameHitchMonitor(requiresActiveApp: false)
    monitor.install(); diagnostics.setEnabled(true)
    defer { monitor.uninstall(); diagnostics.setEnabled(false) }
    func capture(_ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"] else { return }
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }

    let complete = prefix + " — appended 中文流式文本 VISIBLE_END"
    let assistantStarted = CACurrentMediaTime()
    model.messages = try messages(complete)
    await streamingSettle(host, milliseconds: 40)
    let releasedPrefix = renderedText(host)
    precondition(releasedPrefix.contains("Paragraph 8") && !releasedPrefix.contains("VISIBLE_END"),
                 "A burst progressively releases new text while retaining the visible prefix")
    try capture("streaming-prose-partial")
    guard await waitForStreaming(host, { renderedText(host).contains("VISIBLE_END") }) else {
        preconditionFailure("The adaptive release must promptly catch up to the latest cumulative Unicode snapshot")
    }
    let assistantLag = (CACurrentMediaTime() - assistantStarted) * 1_000
    let updatedTexts = textViews(row)
    precondition(nativeRows(host).first === row && updatedTexts.count == 2,
                 "A live append must retain its native row and paragraph grouping")
    precondition(updatedTexts[0] === originalTexts[0] && updatedTexts[1] === originalTexts[1],
                 "Stable and changing blocks must retain their TextKit views")
    precondition(updatedTexts[0].selectedRange() == selection,
                 "Updating the tail must preserve selection in the stable prefix")

    let completedBeforeDrain = complete + String(repeating: "等待展示的追加正文", count: 20) + "COMPLETION_FLUSH"
    model.messages = try messages(completedBeforeDrain)
    await streamingSettle(host, milliseconds: 30)
    precondition(!renderedText(host).contains("COMPLETION_FLUSH"))
    model.running = false
    guard await waitForStreaming(host, { !actions.isHidden && actions.frame.height == 24 }) else {
        preconditionFailure("Settling must expose actions on the existing native row")
    }
    precondition(nativeRows(host).first === row && textViews(row)[0].selectedRange() == selection,
                 "Settling must not replace the row or lose selection")
    precondition(renderedText(host).contains("COMPLETION_FLUSH"), "Completion must flush the remaining text immediately")

    model.reduceMotion = true; model.running = true
    model.messages = try messages(completedBeforeDrain + "REDUCED_MOTION_FULL")
    guard await waitForStreaming(host, { renderedText(host).contains("REDUCED_MOTION_FULL") }) else {
        preconditionFailure("Reduce Motion must display complete stream updates")
    }
    model.reduceMotion = false

    let fallback = "| A | B |\n| --- | --- |\n| 中文 👩🏽‍💻 | é |\n\nFINAL_CHUNK"
    model.running = true
    model.messages = try messages(fallback)
    guard await waitForStreaming(host, { nativeRows(host).isEmpty && renderedText(host).contains("FINAL_CHUNK") }) else {
        preconditionFailure("Unsupported live Markdown must render its complete hosted snapshot")
    }
    model.running = false
    await streamingSettle(host, milliseconds: 100)
    precondition(nativeRows(host).isEmpty && renderedText(host).contains("FINAL_CHUNK"),
                 "Completion must not truncate or replace unsupported fallback content")

    func thoughts(_ text: String, answer: String? = nil) throws -> [KimiMessage] {
        var parts: [[String: Any]] = [["type": "thinking", "thinking": text]]
        if let answer { parts.append(["type": "text", "text": answer]) }
        let json: [[String: Any]] = [
            ["id": "u-thought", "role": "user", "created_at": "0", "content": [["type": "text", "text": "思考流式展示"]]],
            ["id": "a-thought", "role": "assistant", "created_at": "1", "content": parts]
        ]
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: json))
    }
    let thoughtPrefix = "先核对已有的会话状态。"
    model.running = true; model.messages = try thoughts(thoughtPrefix)
    guard await waitForStreaming(host, { renderedText(host).contains(thoughtPrefix) }) else {
        preconditionFailure("Live thoughts must start expanded with their existing text visible")
    }
    let thoughtComplete = thoughtPrefix + String(repeating: "逐步检查中文👩🏽‍💻与边界。", count: 16) + "THOUGHT_RELEASE_END"
    let thoughtStarted = CACurrentMediaTime()
    model.messages = try thoughts(thoughtComplete)
    await streamingSettle(host, milliseconds: 40)
    precondition(renderedText(host).contains(thoughtPrefix) && !renderedText(host).contains("THOUGHT_RELEASE_END"),
                 "Expanded thoughts must use the same progressive release as prose")
    try capture("streaming-thought-partial")
    guard await waitForStreaming(host, { renderedText(host).contains("THOUGHT_RELEASE_END") }) else {
        preconditionFailure("Thoughts must catch up without truncating the Unicode stream")
    }
    let thoughtLag = (CACurrentMediaTime() - thoughtStarted) * 1_000
    try capture("streaming-thought-complete")
    let thoughtFinal = thoughtComplete + String(repeating: "追加的思考尾部", count: 20) + "THOUGHT_FLUSH"
    model.messages = try thoughts(thoughtFinal)
    await streamingSettle(host, milliseconds: 25)
    model.messages = try thoughts(thoughtFinal, answer: "最终正文已开始")
    guard await waitForStreaming(host, { renderedText(host).contains("THOUGHT_FLUSH") }) else {
        preconditionFailure("Starting the answer must immediately flush settled thought text")
    }
    if let folder = ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"] {
        let report: [String: Any] = [
            "scope": "visible native prose/thought release; display-link main-thread scheduling, not GPU-presented FPS",
            "assistant_burst_complete_ms": assistantLag, "thought_burst_complete_ms": thoughtLag,
            "delivered_frames": monitor.deliveredFrames,
            "diagnostics": try JSONSerialization.jsonObject(with: Data(diagnostics.report().utf8))
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("streaming-frame-diagnostics.json"))
    }

    print("PASS: adaptive prose/thought Unicode release, persistent native row and selection, immediate completion/reduced motion, complete hosted fallback")
}
