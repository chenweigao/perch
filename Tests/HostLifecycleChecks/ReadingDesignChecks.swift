import AppKit
import ApplicationServices
import SwiftUI
import WorkbenchCore

struct ReadingDesignFixture: View {
    let messages: [KimiMessage]
    var running = false
    var session = "reading-design"
    var folds = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bubble.left.and.text.bubble.right")
                Text("会话 · 阅读优先").font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "magnifyingglass")
            }.padding(20)
            Divider()
            ConversationScrollView(onScroll: { ConversationReadingMemory.shared.following[session] = $0 }) {
                ConversationTranscript(messages: messages, sessionId: session, isRunning: running, foldsProcess: folds)
                    .environment(\.conversationActionContext, ConversationActionContext(
                        hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .claude, sessionID: "reading-design"))
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
@MainActor private func readingTextViews(_ view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(readingTextViews)
}
@MainActor func checkReadingDesign() async throws {
    NSApp.activate(ignoringOtherApps: true)
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
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
    let editInput: [String: Any] = ["path": "FileReaderWindowChecks.swift",
        "old_string": (1...14).map { "old line \($0)" }.joined(separator: "\n"),
        "new_string": (1...14).map { "new line \($0)" }.joined(separator: "\n")]
    let records: [[String: Any]] = [
        ["id":"prompt", "role":"user", "created_at":"1", "content":[["type":"text", "text":"帮我整理这次设计调整，先说结果。"]]],
        ["id":"thought", "role":"assistant", "created_at":"2", "content":[["type":"thinking", "thinking":"PRIVATE_PROCESS_MARKER 检查 `!busy` 守卫，保留必要操作。\n\n继续验证。"]]],
        ["id":"edit-step", "role":"assistant", "created_at":"2", "content":[["type":"tool_use", "tool_call_id":"edit-1", "tool_name":"edit", "input":editInput]]],
        ["id":"edit-result", "role":"tool", "created_at":"2", "content":[["type":"tool_result", "tool_call_id":"edit-1", "output":"ok", "is_error":false]]],
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
        precondition(headingFont.pointSize == 21, "Native H1 steps seven points up on the DSH ramp")
        let body = views.first { $0.string.contains("正文清楚呈现") }!
        let bodyFont = body.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let paragraph = body.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        let subheading = views.first { $0.string == "本次调整" }!
        let minorHeading = views.first { $0.string == "继续阅读" }!
        precondition(bodyFont.pointSize == 14 && paragraph.minimumLineHeight == 24,
                     "Body reads at 14 pt on a 24 pt line in both renderers")
        precondition((subheading.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 19,
                     "H2 steps five points up from the body")
        precondition((minorHeading.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 18,
                     "H3 steps four points up; H4 and below keep the body size at semibold")
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
    var chosen: (String, String)?
    let observer = NotificationCenter.default.addObserver(forName: .conversationAction, object: nil, queue: .main) { notification in
        if let payload = notification.object as? ConversationActionPayload,
           case .showEdit(let tool, let messageID) = payload.action { chosen = (tool.id, messageID) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    guard let editButton = taskPanelControl(window, "edit-step:edit-1") else {
        preconditionFailure("The historical edit button must be accessible")
    }
    for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        window.sendEvent(NSEvent.mouseEvent(with: kind, location: NSPoint(x: editButton.midX, y: editButton.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0)!)
    }
    try await Task.sleep(for: .milliseconds(150))
    precondition(chosen?.0 == "edit-1" && chosen?.1 == "edit-step", "Clicking the visible counts routes the exact historical call: \(String(describing: chosen)), frame \(editButton)")
    let thoughtEntry = ConversationTimelineEntry.make(messages).first { $0.messages.contains { $0.id == "thought" } }!
    let foldID = thoughtEntry.id
    let fold = mounted(foldID)
    let foldHeaderHeight = fold.bounds.height
    clickHeader(fold, height: foldHeaderHeight)
    try await Task.sleep(for: .milliseconds(400))
    guard let expanded = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No snapshot") }
    host.cacheDisplay(in: host.bounds, to: expanded)
    try expanded.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("expanded.png"))
    precondition(readingTextViews(host).contains { $0.string.contains("PRIVATE_PROCESS_MARKER") }, "Process contents remain reachable")
    let thoughtText = readingTextViews(host).first { $0.string.contains("PRIVATE_PROCESS_MARKER") }!
    precondition(!thoughtText.string.contains("`") && !thoughtText.string.contains("\n\n"),
                 "Thoughts format inline code and collapse empty paragraph lines")
    let thoughtFont = thoughtText.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    precondition(thoughtFont.pointSize == 13, "Expanded thoughts read one tier below the reply")
    // The same disclosure stays open while the live/settled presentation changes.
    host.rootView = ReadingDesignFixture(messages: Array(messages.prefix(2)), running: true)
    try await Task.sleep(for: .milliseconds(200))
    precondition(readingTextViews(host).contains { $0.string.contains("PRIVATE_PROCESS_MARKER") })
    host.rootView = ReadingDesignFixture(messages: messages, running: false)
    try await Task.sleep(for: .milliseconds(200))
    precondition(readingTextViews(host).contains { $0.string.contains("PRIVATE_PROCESS_MARKER") })
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
    for (size, line, heading) in [(18.0, 28.0, 25.0), (16.0, 26.0, 23.0), (14.0, 24.0, 21.0)] as [(CGFloat, CGFloat, CGFloat)] {
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
    precondition((fallbackHeading.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 21)
    try await checkPhaseReadingWindow()
    try await checkReadingLifecycleWindow()
    try await checkReadingStagePages()
    try await checkReadingContinuityReview()
    print("PASS: reading design wide/narrow/dark, collapsed thoughts, retained edit steps, expansion continuity, complete code, selectable text and native/fallback heading parity; snapshots /private/tmp/perch-reading-design")
}

@MainActor private func checkPhaseReadingWindow() async throws {
    func record(_ id: String, _ content: [[String: Any]], role: String = "assistant") -> [String: Any] {
        ["id": id, "role": role, "created_at": "1", "content": content]
    }
    func decode(_ source: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: source))
    }
    var source = [record("phase-prompt", [["type": "text", "text": "检查各个 provider 在上下文满时的行为，并修复文件窗口的边界条件。"]], role: "user"),
        record("phase-intro", [["type": "text", "text": "我先检查各个 runtime 的处理方式，再修改窗口的边界条件。"]]),
        record("phase-thought", [["type": "thinking", "thinking": "先核对运行时能力，再对照窗口状态的判断。"]])]
    let initial = try decode(source)
    let commands = ["grep context Sources/Runtime.swift", "ls Sources", "find Sources -name '*.swift'", "rg compact Sources", "cat AGENTS.md", "grep overflow Sources/Runtime.swift", "rg tab Sources", "[ -f Package.swift ]"]
    for (index, command) in commands.enumerated() {
        let id = "phase-shell-\(index)"
        source.append(record(id, [["type": "tool_use", "tool_call_id": id, "tool_name": "Bash", "input": ["command": command]]]))
        source.append(record(id + "-result", [["type": "tool_result", "tool_call_id": id, "output": "ok", "is_error": false]], role: "tool"))
        if index % 2 == 0 { source.append(record("phase-thought-\(index)", [["type": "thinking", "thinking": "继续检查相关实现，保留原有的窗口行为。"]])) }
    }
    let liveSource = source + [record("phase-thinking-tail", [["type": "thinking", "thinking": "还需要确认首次打开文件时的状态。"]])]
    source.append(record("phase-progress", [["type": "text", "text": "已确认：首次读取尚未完成时，当前路径可能还不在标签列表里。我会补齐这个边界，并保留每次编辑的记录。"]]))
    for index in 1...2 {
        let id = "phase-edit-\(index)"
        let count = index == 1 ? 14 : 3
        source.append(record(id, [["type": "tool_use", "tool_call_id": id, "tool_name": "edit", "input": ["path": "FileReaderWindowChecks.swift", "old_string": (1...count).map { "old line \($0)" }.joined(separator: "\n"), "new_string": (1...count).map { "new line \($0)" }.joined(separator: "\n")]]]))
        source.append(record(id + "-result", [["type": "tool_result", "tool_call_id": id, "output": "ok", "is_error": false]], role: "tool"))
    }
    source.append(record("phase-validation", [["type": "text", "text": "改动已完成，接下来运行检查和构建。"]]))
    for (index, command) in ["swift test", "swift build"].enumerated() {
        let id = "phase-check-\(index)"
        source.append(record(id, [["type": "tool_use", "tool_call_id": id, "tool_name": "Bash", "input": ["command": command]]]))
        source.append(record(id + "-result", [["type": "tool_result", "tool_call_id": id, "output": "passed", "is_error": false]], role: "tool"))
    }
    source.append(record("phase-final", [["type": "text", "text": "已修复首次打开文件时的边界判断。检查和构建通过，每一步代码增删都可以单独查看。"]]))
    let messages = try decode(source)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    window.appearance = NSAppearance(named: .aqua)
    let host = NSHostingView(rootView: ReadingDesignFixture(messages: messages))
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    let output = URL(fileURLWithPath: "/private/tmp/perch-reading-design")
    func snapshot(_ name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    func click(_ frame: NSRect) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
    let phaseID = "thinking:phase-thought:0"
    for (name, width, appearance) in [("phases-wide", 1000.0, NSAppearance.Name.aqua), ("phases-narrow", 540.0, .aqua), ("phases-dark", 1000.0, .darkAqua)] {
        window.setContentSize(NSSize(width: width, height: 800)); window.appearance = NSAppearance(named: appearance)
        try await Task.sleep(for: .milliseconds(350))
        precondition(taskPanelControl(window, "activity-phase:" + phaseID) != nil)
        precondition(taskPanelControl(window, "edit-step:phase-edit-1") != nil && taskPanelControl(window, "edit-step:phase-edit-2") != nil,
                     "Each same-file edit remains independently accessible beside the collapsed phase")
        precondition(!readingTextViews(host).contains { $0.string.contains("先核对运行时能力") })
        try snapshot(name)
    }
    window.appearance = NSAppearance(named: .aqua)
    host.rootView = ReadingDesignFixture(messages: initial, running: true)
    try await Task.sleep(for: .milliseconds(250))
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    let thought = descendants(host).first { $0.identifier?.rawValue == phaseID }!
    let bounds = thought.convert(thought.bounds, to: nil)
    click(bounds)
    try await Task.sleep(for: .milliseconds(200))
    precondition(readingTextViews(host).contains { $0.string.contains("先核对运行时能力") })
    host.rootView = ReadingDesignFixture(messages: try decode(liveSource), running: true)
    try await Task.sleep(for: .milliseconds(350))
    precondition(readingTextViews(host).contains { $0.string.contains("先核对运行时能力") }, "An opened thought stays readable when Bash grows it into a stage")
    try snapshot("phases-expanded")
    guard let expandedControl = taskPanelControl(window, "activity-phase:" + phaseID) else { fatalError("Missing phase disclosure") }
    let closingStarted = ContinuousClock.now
    click(expandedControl)
    try await Task.sleep(for: .milliseconds(40))
    // Sleep is a minimum delay: a busy CI main actor can resume after the
    // entire 250 ms transition. Only inspect an actual intermediate frame;
    // reduced motion intentionally unmounts the content immediately.
    let sampledAfter = closingStarted.duration(to: .now)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, sampledAfter < .milliseconds(200) {
        precondition(readingTextViews(host).contains { $0.string.contains("先核对运行时能力") }, "Closing a phase retains content during its height transition")
    } else {
        print("INFO: intermediate collapse frame unavailable (elapsed \(sampledAfter)); checking settled state")
    }
    try await Task.sleep(for: .milliseconds(400))
    precondition(!readingTextViews(host).contains { $0.string.contains("先核对运行时能力") })
    try snapshot("phases-live")
    host.rootView = ReadingDesignFixture(messages: messages)
    try await Task.sleep(for: .milliseconds(300))
    precondition(!readingTextViews(host).contains { $0.string.contains("先核对运行时能力") }, "Completion preserves the reader's collapsed choice")
    var failedSource = source
    let resultIndex = failedSource.firstIndex { $0["id"] as? String == "phase-shell-0-result" }!
    failedSource[resultIndex] = record("phase-shell-0-result", [["type": "tool_result", "tool_call_id": "phase-shell-0", "output": "Permission denied", "is_error": true]], role: "tool")
    host.rootView = ReadingDesignFixture(messages: try decode(failedSource))
    try await Task.sleep(for: .milliseconds(300))
    precondition(taskPanelControl(window, "tool-call:phase-shell-0") == nil,
                 "Historical failures do not consume individual rows")
    precondition(taskPanelLabel(window, "activity-phase:thinking:phase-thought:0")?.contains("Permission denied") == true,
                 "The collapsed stage header names the failure's first line")
    precondition(taskPanelControl(window, "tool-call:phase-shell-1") == nil,
                 "Successful calls stay inside the collapsed stage")
    try snapshot("phases-failure")
    // Preserve identical failure/edit content for before/after comparison.
    var failedEdit = source
    let editResult = failedEdit.firstIndex { $0["id"] as? String == "phase-edit-2-result" }!
    failedEdit[editResult] = record("phase-edit-2-result", [["type": "tool_result", "tool_call_id": "phase-edit-2", "output": "Permission denied", "is_error": true]], role: "tool")
    let failedEditMessages = try decode(failedEdit)
    for (name, width, appearance) in [("review-failed-edit", 1000.0, NSAppearance.Name.aqua), ("review-failed-edit-narrow", 540.0, .aqua), ("review-failed-edit-dark", 1000.0, .darkAqua)] {
        window.setContentSize(NSSize(width: width, height: 800)); window.appearance = NSAppearance(named: appearance)
        host.rootView = ReadingDesignFixture(messages: failedEditMessages)
        try await Task.sleep(for: .milliseconds(400))
        precondition(taskPanelControl(window, "edit-step:phase-edit-2") != nil)
        precondition(taskPanelControl(window, "tool-call:phase-edit-2") == nil, "A failed edit has one visible receipt, with details behind its arrow")
        try snapshot(name)
    }
    let failureOnly = try decode([source[0], source[2], source[3],
        record("failure-only-result", [["type": "tool_result", "tool_call_id": "phase-shell-0", "output": "Permission denied", "is_error": true]], role: "tool")])
    window.appearance = NSAppearance(named: .aqua)
    window.setContentSize(NSSize(width: 1000, height: 800))
    host.rootView = ReadingDesignFixture(messages: failureOnly, running: true)
    try await Task.sleep(for: .milliseconds(400))
    precondition(taskPanelControl(window, "activity-live-status:thinking:phase-thought:0") == nil,
                 "A completed stage must not acquire a generic waiting footnote")
    precondition(taskPanelControl(window, "tool-call:phase-shell-0") != nil,
                 "The latest failed call remains directly accessible while the agent waits for new output")
    try snapshot("review-live-failure")
    if Bundle.main.object(forInfoDictionaryKey: "PerchReadingPreview") as? Bool == true {
        window.styleMask.insert(.resizable)
        window.title = "Perch 正文设计评审 · 本地合成内容"
        let review = NSHostingView(rootView: ReadingReviewControls(records: failedEdit, liveRecords: liveSource))
        window.contentView = review
        while true { try await Task.sleep(for: .seconds(1)) }
    }
    print("PASS: native phase window, eight Bash calls with thoughts, two visible edit receipts, real disclosure clicks, live/completed continuity, wide/narrow/dark snapshots")
}

/// Manual review uses the production transcript and only deterministic records.
private struct ReadingReviewControls: View {
    let records: [[String: Any]]
    let liveRecords: [[String: Any]]
    @State private var session = "review-A"
    @State private var running = false
    @State private var dark = false
    @State private var long = false
    @State private var appended = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(session == "review-A" ? "切到会话 B" : "返回会话 A") { session = session == "review-A" ? "review-B" : "review-A" }
                Toggle("流式", isOn: $running)
                Button("追加") { appended += 1 }
                Toggle("长会话", isOn: $long)
                Toggle("深色", isOn: $dark)
            }.padding(12)
            ReadingDesignFixture(messages: content, running: running, session: session, folds: true)
        }.preferredColorScheme(dark ? .dark : .light)
    }
    private var content: [KimiMessage] {
        func decode(_ rows: [[String: Any]]) -> [KimiMessage] {
            try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
        }
        let history: [KimiMessage] = long ? decode((0..<40).flatMap { turn in
            records.map { original in
                var row = original
                let prefix = "history-\(turn):"
                row["id"] = prefix + (row["id"] as! String)
                row["content"] = (row["content"] as! [[String: Any]]).map { original in
                    var part = original
                    if let id = part["tool_call_id"] as? String { part["tool_call_id"] = prefix + id }
                    return part
                }
                return row
            }
        }) : []
        let tail = decode(running ? liveRecords : records)
        let addition: [KimiMessage] = appended == 0 ? [] : decode([
            ["id": "review-append", "role": "assistant", "created_at": "", "content": [
                ["type": "text", "text": String(repeating: "追加内容：保持正在阅读的位置。\n", count: appended)]]]])
        return history + tail + addition
    }
}

@MainActor private func checkReadingLifecycleWindow() async throws {
    func record(_ id: String, _ parts: [[String: Any]], role: String = "assistant") -> [String: Any] {
        ["id": id, "role": role, "created_at": "1", "content": parts]
    }
    func decode(_ rows: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    let start = [record("lifecycle-user", [["type": "text", "text": "修复首次打开文件时的状态判断，并检查结果。"]], role: "user"),
        record("lifecycle-progress", [["type": "text", "text": "我先检查窗口状态，再修改边界判断。"]]),
        record("lifecycle-summary", [["type": "thinking", "thinking": "PRIVATE_LIFECYCLE_REASONING", "source": ["kind": "activity_summary", "summaryParts": ["正在核对当前路径与标签列表的更新顺序，确认首次读取尚未完成时的处理方式。"], "state": "streaming"]]])]
    let read = record("lifecycle-read", [["type": "tool_use", "tool_call_id": "lifecycle-read", "tool_name": "read", "input": ["path": "DocumentReader.swift"]]])
    let readResult = record("lifecycle-read-result", [["type": "tool_result", "tool_call_id": "lifecycle-read", "output": "ok", "is_error": false]], role: "tool")
    let live = try decode(start + [read, readResult])
    let edit = record("lifecycle-edit", [["type": "tool_use", "tool_call_id": "lifecycle-edit", "tool_name": "edit", "input": ["path": "DocumentReader.swift", "old_string": "old line\nold guard", "new_string": "new line\nnew guard\nnew check"]]])
    let editResult = record("lifecycle-edit-result", [["type": "tool_result", "tool_call_id": "lifecycle-edit", "output": "ok", "is_error": false]], role: "tool")
    let check = record("lifecycle-check", [["type": "tool_use", "tool_call_id": "lifecycle-check", "tool_name": "bash", "input": ["command": "swift test"]]])
    let checkResult = record("lifecycle-check-result", [["type": "tool_result", "tool_call_id": "lifecycle-check", "output": "Permission denied", "is_error": true]], role: "tool")
    let answer = record("lifecycle-answer", [["type": "text", "text": "已修复首次打开文件时的边界判断。测试遇到权限问题，尚未验证通过；该问题保留在上方，便于继续处理。"]])
    let done = try decode(start + [read, readResult, edit, editResult, check, checkResult, answer])
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    window.appearance = NSAppearance(named: .aqua)
    let host = NSHostingView(rootView: ReadingDesignFixture(messages: try decode(start), running: true, session: "lifecycle-A", folds: true))
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    let output = URL(fileURLWithPath: "/private/tmp/perch-reading-design")
    func settle() async throws { try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded() }
    func snapshot(_ name: String) throws {
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    func click(_ identifier: String) {
        guard let frame = taskPanelControl(window, identifier) else { preconditionFailure("Missing visible control: \(identifier)") }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
    try await settle()
    precondition(taskPanelControl(window, "live-thinking-summary") != nil, "A public summary is visible before any tool starts")
    precondition(!readingTextViews(host).contains { $0.string.contains("PRIVATE_LIFECYCLE_REASONING") })
    click("thought-disclosure:lifecycle-A:thinking:lifecycle-summary:0")
    try await settle()
    precondition(readingTextViews(host).contains { $0.string.contains("PRIVATE_LIFECYCLE_REASONING") })
    host.rootView = ReadingDesignFixture(messages: live, running: true, session: "lifecycle-A", folds: true)
    try await settle()
    precondition(readingTextViews(host).contains { $0.string.contains("PRIVATE_LIFECYCLE_REASONING") },
                 "A manually opened source remains visible when the preview moves into the tool stage")
    click("thought-disclosure:lifecycle-A:thinking:lifecycle-summary:0")
    try await settle()
    // The public summary rides the live process disclosure's header (DSH's
    // streaming reasoning row), inside or outside the fold alike.
    guard let foldLabel = taskPanelLabel(window, "completed-process:text:lifecycle-progress:0") else { fatalError("Missing the live process disclosure") }
    precondition(foldLabel.contains("Inspecting the tab state"), "The live fold header carries the public summary: \(foldLabel)")
    precondition(summaryFrame.height <= 46, "The live summary is bounded to two lines")
    try snapshot("lifecycle-running")
    host.rootView = ReadingDesignFixture(messages: live, running: false, session: "lifecycle-A", folds: true)
    try await settle()
    // The unfinished turn folds like any other; open the fold, then the step.
    click("completed-process:text:lifecycle-progress:0")
    try await settle()
    click("activity-phase:activity:tool:lifecycle-read")
    try await settle()
    precondition(taskPanelControl(window, "tool-call:lifecycle-read") != nil,
                 "read tool card after phase click; ids: " + taskPanelIdentifiers(window).joined(separator: ", "))
    precondition(ConversationReadingMemory.shared.retainedEntries(session: "lifecycle-A").contains("activity:tool:lifecycle-read"))
    host.rootView = ReadingDesignFixture(messages: live, running: true, session: "lifecycle-A", folds: true)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:lifecycle-read") != nil, "Resuming an interrupted turn preserves its open process")
    host.rootView = ReadingDesignFixture(messages: done, session: "lifecycle-A", folds: true)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:lifecycle-read") != nil, "Completion cannot close a process the reader opened")
    precondition(taskPanelControl(window, "live-thinking-summary") == nil)
    // Uniform fold: the edit receipt and the failed call sit inside the fold,
    // whose header carries the call count and the thinking's first line.
    precondition(taskPanelControl(window, "edit-step:lifecycle-edit") == nil)
    precondition(taskPanelControl(window, "activity-phase:activity:tool:lifecycle-check") == nil)
    precondition(taskPanelLabel(window, "completed-process:activity:tool:lifecycle-edit")?.contains(L("2 个工具")) == true,
                 "The second fold (edit + check) carries the tool count")
    try snapshot("lifecycle-retained")
    // A fresh reader sees the prompt, the fold and the answer. Session A's
    // explicit choice cannot leak to B.
    host.rootView = ReadingDesignFixture(messages: done, session: "lifecycle-B", folds: true)
    for (name, width, appearance) in [("lifecycle-completed", 1000.0, NSAppearance.Name.aqua), ("lifecycle-narrow", 540.0, .aqua), ("lifecycle-dark", 1000.0, .darkAqua)] {
        window.setContentSize(NSSize(width: width, height: 760)); window.appearance = NSAppearance(named: appearance)
        try await settle()
        precondition(taskPanelControl(window, "tool-call:lifecycle-read") == nil)
        precondition(taskPanelControl(window, "edit-step:lifecycle-edit") == nil && taskPanelControl(window, "activity-phase:activity:tool:lifecycle-check") == nil)
        precondition(!readingTextViews(host).contains { $0.string.contains("我先检查窗口状态") })
        precondition(readingTextViews(host).contains { $0.string.contains("已修复首次打开文件") })
        try snapshot(name)
    }
    window.appearance = NSAppearance(named: .aqua)
    // The failed call remains reachable inside its expanded fold and stage.
    // (Session B retained nothing, so the whole turn is one fold here.)
    click("completed-process:text:lifecycle-progress:0")
    try await settle()
    click("activity-phase:activity:tool:lifecycle-check")
    try await settle()
    precondition(taskPanelControl(window, "tool-call:lifecycle-check") != nil, "The failed call remains reachable inside the fold")
    click("completed-process:text:lifecycle-progress:0")
    try await settle()
    precondition(!readingTextViews(host).contains { $0.string.contains("我先检查窗口状态") }, "Re-collapsing the fold hides the process again")
    click("completed-process:text:lifecycle-progress:0")
    try await settle()
    precondition(readingTextViews(host).contains { $0.string.contains("我先检查窗口状态") }, "Completed process remains reachable")
    let next = try decode([record("next-prompt", [["type": "text", "text": "继续验证"]], role: "user"), record("next-thought", [["type": "thinking", "thinking": "PRIVATE_NEXT_REASONING"]])])
    host.rootView = ReadingDesignFixture(messages: done + next, running: true, session: "lifecycle-B", folds: true)
    try await settle()
    precondition(readingTextViews(host).contains { $0.string.contains("我先检查窗口状态") }, "Starting another turn preserves a manually opened history fold")
    precondition(taskPanelControl(window, "live-thinking-summary") == nil, "Without a public summary the UI does not invent one")
    host.rootView = ReadingDesignFixture(messages: done, session: "lifecycle-A", folds: true)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:lifecycle-read") != nil, "Switching sessions restores the expanded step")
    print("PASS: native live public summary, two-line bound, default completed folds, preserved edit/error, manual expansion through completion/new turn/session switch")
}

/// A single work stage may span several record pages, without losing pending
/// states or the reader's selected page when the live turn changes.
@MainActor private func checkReadingStagePages() async throws {
    func records(_ count: Int, done: Bool = false, failedLast: Bool = false) throws -> [KimiMessage] {
        var rows: [[String: Any]] = [["id": "page-user", "role": "user", "created_at": "",
            "content": [["type": "text", "text": "检查连续工作阶段"]]]]
        for index in 0..<count {
            let id = "page-tool-\(index)"
            rows += [["id": id, "role": "assistant", "created_at": "", "content": [
                ["type": "tool_use", "tool_call_id": id, "tool_name": "bash", "input": ["command": "git -C /repo show marker-\(index) marker-\(index)"]]]],
                ["id": id + "-result", "role": "tool", "created_at": "", "content": [
                    ["type": "tool_result", "tool_call_id": id, "output": "ok", "is_error": failedLast && index == count - 1]]]]
        }
        if done { rows.append(["id": "page-answer", "role": "assistant", "created_at": "", "content": [["type": "text", "text": "检查结束。"]]]) }
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let host = NSHostingView(rootView: ReadingDesignFixture(messages: try records(26), running: true, session: "stage-page-A", folds: true))
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    func settle() async throws { try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded() }
    func click(_ identifier: String) {
        guard let frame = taskPanelControl(window, identifier) else { preconditionFailure("Missing page control: \(identifier)") }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
    let stage = "activity:tool:page-tool-0"
    try await settle()
    precondition(taskPanelLabel(window, "activity-phase:" + stage)?.contains("git show") == true,
                 "The stage header names the latest targets")
    precondition(taskPanelControl(window, "activity-phase:activity:tool:page-tool-24") == nil)
    click("activity-phase:" + stage)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-0") != nil)
    precondition(taskPanelControl(window, "tool-call:page-tool-24") == nil, "First page does not mount later records")
    click("stage-next-page:" + stage)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-0") == nil)
    precondition(taskPanelControl(window, "tool-call:page-tool-24") != nil)
    click("activity-phase:" + stage)
    try await settle()
    click("activity-phase:" + stage)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-24") != nil, "Collapsing and reopening preserves the record page")
    host.rootView = ReadingDesignFixture(messages: try records(27), running: true, session: "stage-page-A", folds: true)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-26") != nil && taskPanelControl(window, "tool-call:page-tool-0") == nil)
    host.rootView = ReadingDesignFixture(messages: try records(27, done: true), session: "stage-page-A", folds: true)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-24") != nil, "Completion preserves a manually opened stage and page")
    host.rootView = ReadingDesignFixture(messages: try records(26), running: true, session: "stage-page-B", folds: true)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-24") == nil, "Another session does not inherit expansion")
    host.rootView = ReadingDesignFixture(messages: try records(27, done: true), session: "stage-page-A", folds: true)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-24") != nil, "Returning restores the selected page")
    click("stage-previous-page:" + stage)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-0") != nil && taskPanelControl(window, "tool-call:page-tool-24") == nil)
    let searchRecords = try records(27, done: true)
    let hit = ConversationSearch().hits(in: searchRecords, query: "marker-26", running: false).hits.first!
    NotificationCenter.default.post(name: .init("PerchRevealConversationHit"), object: ConversationFindTarget(
        session: "stage-page-A", hit: hit, query: "marker-26"))
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-26") != nil && taskPanelControl(window, "tool-call:page-tool-0") == nil,
                 "Find opens the page containing its exact tool record")
    precondition(readingTextViews(host).contains { $0.string.contains("marker-26") })
    let repeatedHit = ConversationSearch().hits(in: searchRecords, query: "marker-", running: false).hits.first {
        $0.toolID == "page-tool-26" && $0.toolOccurrence == 1
    }!
    NotificationCenter.default.post(name: .init("PerchRevealConversationHit"), object: ConversationFindTarget(
        session: "stage-page-A", hit: repeatedHit, query: "marker-"))
    try await settle()
    precondition(readingTextViews(host).contains { text in
        text.string.contains("marker-26") && text.selectedRange() == (text.string as NSString).range(of: "marker-", options: .backwards)
    }, "A repeated query selects its record-local occurrence on a later page, excluding earlier records")
    host.rootView = ReadingDesignFixture(messages: try records(26, failedLast: true), running: true, session: "stage-page-C")
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-25") != nil,
                 "A current failed call on a later page cannot be hidden by pagination")
    click("activity-phase:" + stage)
    try await settle()
    precondition(taskPanelControl(window, "tool-call:page-tool-25") != nil && taskPanelControl(window, "tool-call:page-tool-24") == nil)
    print("PASS: native single-stage pagination, bounded records, find/active failure visibility, collapse/append/completion/session-return continuity")
}
