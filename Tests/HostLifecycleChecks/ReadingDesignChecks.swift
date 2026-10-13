import AppKit
import SwiftUI
import WorkbenchCore

private struct ReadingDesignFixture: View {
    let messages: [KimiMessage]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bubble.left.and.text.bubble.right")
                Text("会话 · 阅读优先").font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "magnifyingglass")
            }.padding(20)
            Divider()
            ConversationScrollView {
                ConversationTranscript(messages: messages, sessionId: "reading-design", foldsProcess: true)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
@MainActor private func readingTextViews(_ view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(readingTextViews)
}
@MainActor func checkReadingDesign() async throws {
    let text = """
    # 让回复成为阅读的主角

    正文清楚呈现，思考和工具过程按需展开。中文与 English 使用同一套节奏，阅读时不必穿过成排的状态卡片。

    ## 本次调整

    - 保留完整回复、链接与代码复制。
    - 过程集中收纳；失败和待确认的操作保持可见。

    ```swift
    let answer = "清晰的内容，安静的过程"
    print(answer)
    ```

    ### 继续阅读

    可以通过左侧轮次导航返回提问，或收藏这一轮。[查看文档](https://example.com/guide)。
    """
    let records: [[String: Any]] = [
        ["id":"prompt", "role":"user", "created_at":"1", "content":[["type":"text", "text":"帮我整理这次设计调整，先说结果。"]]],
        ["id":"thought", "role":"assistant", "created_at":"2", "content":[["type":"thinking", "thinking":"PRIVATE_PROCESS_MARKER 检查已有阅读结构，保留必要操作。"]]],
        ["id":"answer", "role":"assistant", "created_at":"3", "content":[["type":"text", "text":text]]]
    ]
    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: records))
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 880), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let host = NSHostingView(rootView: ReadingDesignFixture(messages: messages))
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    let output = URL(fileURLWithPath: "/private/tmp/perch-reading-design")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (label, width, appearance) in [("wide", 1000.0, NSAppearance.Name.aqua), ("narrow", 540.0, .aqua), ("dark", 1000.0, .darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(NSSize(width: width, height: 880))
        try await Task.sleep(for: .milliseconds(500))
        window.contentView?.layoutSubtreeIfNeeded()
        let views = readingTextViews(host)
        let content = views.map(\.string).joined(separator: "\n")
        precondition(content.contains("让回复成为阅读的主角") && content.contains("清晰的内容，安静的过程"))
        precondition(!content.contains("PRIVATE_PROCESS_MARKER"), "Completed process must start collapsed")
        precondition(views.filter { $0.string.contains("正文清楚呈现") || $0.string.contains("let answer") }.allSatisfy { $0.isSelectable }, "Reply and code text must remain selectable")
        let heading = views.first { $0.string == "让回复成为阅读的主角" }!
        let headingFont = heading.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        precondition(headingFont.pointSize == 22, "Native heading uses the shared hierarchy")
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No snapshot bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(label + ".png"))
    }
    // Click the same native fixture controls shown in the exported 1000x880 preview.
    func click(x: CGFloat, yFromTop: CGFloat) {
        let point = host.convert(NSPoint(x: x, y: host.isFlipped ? yFromTop : host.bounds.height - yFromTop), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
    }
    click(x: 220, yFromTop: 150)
    try await Task.sleep(for: .milliseconds(400))
    click(x: 220, yFromTop: 190)
    try await Task.sleep(for: .milliseconds(400))
    guard let expanded = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No snapshot") }
    host.cacheDisplay(in: host.bounds, to: expanded)
    try expanded.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("expanded.png"))
    precondition(readingTextViews(host).contains { $0.string.contains("PRIVATE_PROCESS_MARKER") }, "Process contents remain reachable")
    click(x: 220, yFromTop: 150)
    try await Task.sleep(for: .milliseconds(400))
    precondition(!readingTextViews(host).contains { $0.string.contains("PRIVATE_PROCESS_MARKER") })
    // Fallback Markdown uses the same hierarchy and complete link/text contents.
    let fallback = NSHostingView(rootView: KimiMarkdown(text: text).frame(width: 460))
    window.contentView = fallback
    try await Task.sleep(for: .milliseconds(400))
    let fallbackHeading = readingTextViews(fallback).first { $0.string == "让回复成为阅读的主角" }!
    precondition((fallbackHeading.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 22)
    print("PASS: reading design wide/narrow/dark, collapsed process, complete code, selectable text and native/fallback heading parity; snapshots /private/tmp/perch-reading-design")
}
