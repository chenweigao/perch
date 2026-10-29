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
    func luminance(_ color: NSColor, in appearance: NSAppearance) -> Double {
        var rgb = NSColor.black
        appearance.performAsCurrentDrawingAppearance { rgb = color.usingColorSpace(.sRGB)! }
        func linear(_ value: CGFloat) -> Double {
            let c = Double(value)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = NSAppearance(named: name)!
        let ink = luminance(WorkbenchTheme.quietNS, in: appearance)
        let paper = luminance(WorkbenchTheme.contentBackgroundNS, in: appearance)
        let contrast = (max(ink, paper) + 0.05) / (min(ink, paper) + 0.05)
        precondition(contrast >= 4.5, "Readable metadata on the opaque reading sheet: \(contrast)")
        precondition(ReplyStyle.quietInk === WorkbenchTheme.quietNS, "Cached and live secondary prose share the same dynamic ink")
    }
    ReadingBodySize.shared.set(ReadingBodySize.standard)
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
        precondition(headingFont.pointSize == 18, "Native heading uses the shared hierarchy")
        let body = views.first { $0.string.contains("正文清楚呈现") }!
        let bodyFont = body.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let paragraph = body.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        let subheading = views.first { $0.string == "本次调整" }!
        let minorHeading = views.first { $0.string == "继续阅读" }!
        precondition(bodyFont.pointSize == 14 && paragraph.minimumLineHeight == 22,
                     "Body reads at 14 pt on a 22 pt line in both renderers")
        precondition((subheading.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 16,
                     "H2 steps up two points from the body")
        precondition((minorHeading.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == bodyFont.pointSize,
                     "H3 and below keep the body size; hierarchy comes from weight and spacing")
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No snapshot bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(label + ".png"))
    }
    // Locate the production row anchors instead of assuming a prompt height:
    // body font, wrapping, and reading width may move both disclosure headers.
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func mounted(_ identifier: String) -> NSView {
        guard let view = descendants(host).first(where: { $0.identifier?.rawValue == identifier }) else {
            fatalError("Missing production disclosure row: \(identifier)")
        }
        return view
    }
    func clickHeader(_ view: NSView, height: CGFloat) {
        let y = view.isFlipped ? view.bounds.minY + height / 2 : view.bounds.maxY - height / 2
        let point = view.convert(NSPoint(x: view.bounds.midX, y: y), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
    }
    let thoughtEntry = ConversationTimelineEntry.make(messages).first { $0.messages.contains { $0.id == "thought" } }!
    let foldID = ConversationTimelineEntry.processFold(firstEntry: thoughtEntry).id
    let fold = mounted(foldID)
    let foldHeaderHeight = fold.bounds.height
    clickHeader(fold, height: foldHeaderHeight)
    try await Task.sleep(for: .milliseconds(400))
    let thought = mounted("process-entry:" + thoughtEntry.id)
    clickHeader(thought, height: thought.bounds.height)
    try await Task.sleep(for: .milliseconds(400))
    guard let expanded = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No snapshot") }
    host.cacheDisplay(in: host.bounds, to: expanded)
    try expanded.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("expanded.png"))
    precondition(readingTextViews(host).contains { $0.string.contains("PRIVATE_PROCESS_MARKER") }, "Process contents remain reachable")
    let thoughtText = readingTextViews(host).first { $0.string.contains("PRIVATE_PROCESS_MARKER") }!
    let thoughtFont = thoughtText.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    precondition(thoughtFont.pointSize == 14, "Expanded thoughts remain as readable as the reply")
    clickHeader(mounted(foldID), height: foldHeaderHeight)
    try await Task.sleep(for: .milliseconds(400))
    precondition(!readingTextViews(host).contains { $0.string.contains("PRIVATE_PROCESS_MARKER") })
    // The reader's body size re-renders mounted native rows: every size of the
    // ramp follows, and returning to the default restores the original metrics.
    func bodyMetrics() -> (body: CGFloat, line: CGFloat, heading: CGFloat)? {
        let views = readingTextViews(host)
        guard let body = views.first(where: { $0.string.contains("正文清楚呈现") }),
              let heading = views.first(where: { $0.string == "让回复成为阅读的主角" }),
              let font = body.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
              let paragraph = body.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
              let headingFont = heading.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return nil }
        return (font.pointSize, paragraph.minimumLineHeight, headingFont.pointSize)
    }
    for (size, line, heading) in [(18.0, 28.0, 22.0), (16.0, 25.0, 20.0), (14.0, 22.0, 18.0)] as [(CGFloat, CGFloat, CGFloat)] {
        ReadingBodySize.shared.set(size)
        var metrics = bodyMetrics()
        for _ in 0..<40 where metrics.map({ $0.body != size }) ?? true {
            try await Task.sleep(for: .milliseconds(50))
            window.contentView?.layoutSubtreeIfNeeded()
            metrics = bodyMetrics()
        }
        precondition(metrics.map { $0.body == size && $0.line == line && $0.heading == heading } ?? false,
                     "Changing the reading size to \(size) must re-render mounted rows at \(size)/\(line), H1 \(heading): \(String(describing: metrics))")
    }
    precondition(UserDefaults.standard.double(forKey: ReadingBodySize.defaultsKey) == 14, "The reading size persists")
    // Fallback Markdown uses the same hierarchy and complete link/text contents.
    let fallback = NSHostingView(rootView: KimiMarkdown(text: text).frame(width: 460))
    window.contentView = fallback
    try await Task.sleep(for: .milliseconds(400))
    let fallbackHeading = readingTextViews(fallback).first { $0.string == "让回复成为阅读的主角" }!
    precondition((fallbackHeading.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 18)
    print("PASS: reading design wide/narrow/dark, collapsed process, complete code, selectable text and native/fallback heading parity; snapshots /private/tmp/perch-reading-design")
}
