import AppKit
import Observation
import SwiftUI
import WorkbenchCore

@MainActor @Observable private final class StreamingFixture {
    var messages: [KimiMessage] = []
    var running = true
}

private struct StreamingFixtureView: View {
    let model: StreamingFixture
    var body: some View {
        ScrollView {
            ConversationTranscript(messages: model.messages, sessionId: "streaming-rendering-fixture", isRunning: model.running)
        }.frame(width: 720, height: 500)
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

    let complete = prefix + " — appended 中文流式文本 VISIBLE_END"
    model.messages = try messages(complete)
    guard await waitForStreaming(host, { renderedText(host).contains("VISIBLE_END") }) else {
        preconditionFailure("The latest cumulative Unicode snapshot must be visible without a reveal drain")
    }
    let updatedTexts = textViews(row)
    precondition(nativeRows(host).first === row && updatedTexts.count == 2,
                 "A live append must retain its native row and paragraph grouping")
    precondition(updatedTexts[0] === originalTexts[0] && updatedTexts[1] === originalTexts[1],
                 "Stable and changing blocks must retain their TextKit views")
    precondition(updatedTexts[0].selectedRange() == selection,
                 "Updating the tail must preserve selection in the stable prefix")

    model.running = false
    guard await waitForStreaming(host, { !actions.isHidden && actions.frame.height == 24 }) else {
        preconditionFailure("Settling must expose actions on the existing native row")
    }
    precondition(nativeRows(host).first === row && textViews(row)[0].selectedRange() == selection,
                 "Settling must not replace the row or lose selection")

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

    print("PASS: cumulative snapshots use a persistent native row, stable block views and complete hosted fallback")
}
