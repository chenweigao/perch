import AppKit
import ApplicationServices
import SwiftUI
import WorkbenchCore

@MainActor private func controlViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(controlViews) }
@MainActor private func controlClick(_ window: NSWindow, x: CGFloat, top: CGFloat) {
    let host = window.contentView!
    let point = host.convert(NSPoint(x: x, y: host.isFlipped ? top : host.bounds.height - top), to: nil)
    controlClick(window, point: point)
}
@MainActor private func controlClick(_ window: NSWindow, point: NSPoint) {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
    }
}
@MainActor private func controlClick(_ window: NSWindow, identifier: String) {
    var visited = Set<ObjectIdentifier>()
    func find(_ value: Any) -> NSObject? {
        guard let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return nil }
        // SwiftUI virtual elements expose AX selectors without necessarily
        // declaring the complete NSAccessibility protocol.
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        if attribute("accessibilityIdentifier") as? String == identifier { return node }
        for child in attribute("accessibilityChildren") as? [Any] ?? [] {
            if let found = find(child) { return found }
        }
        return nil
    }
    guard let element = find(window.contentView!),
          element.responds(to: NSSelectorFromString("accessibilityFrame")),
          let frame = (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
          !frame.isEmpty else { preconditionFailure("Missing visible control: \(identifier)") }
    let rect = window.convertFromScreen(frame)
    // Click the actual button's center, retaining hit-testing coverage while
    // allowing its position to change with typography and localization.
    controlClick(window, point: NSPoint(x: rect.midX, y: rect.midY))
}
@MainActor func checkReadingControls() async throws {
    AppLanguage.applyToSystem(.zhHans)
    let ownAX = AXUIElementCreateApplication(getpid())
    AXUIElementSetAttributeValue(ownAX, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    ReadingBodySize.shared.set(ReadingBodySize.standard)
    let memory = ConversationReadingMemory.shared
    let output = URL(fileURLWithPath: "/private/tmp/perch-reading-controls")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    defer { window.orderOut(nil) }
    let long = (0..<60).map { "问题第 \($0) 行 中文 👨‍👩‍👧‍👦 é — 完整复制" }.joined(separator: "\n\n")
    let native = NativeUserMessageView.acquire()
    native.expansionKey = "reading-controls:native"
    native.sourceText = long
    native.update(NativeUserMessageView.content(long)!, dark: false)
    func place() { native.frame = NSRect(origin: .zero, size: native.measure(width: 540)); native.place(width: 540) }
    native.expansionDidChange = { place() }
    place()
    let collapsed = native.frame.height
    precondition(collapsed < 300 && native.sourceText == long)
    let toggle = controlViews(native).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "user-prompt-toggle" }!
    precondition(!toggle.isHidden)
    toggle.performClick(nil)
    precondition(native.frame.height > 1000 && memory.expansions["reading-controls:native:user-prompt"] == true)
    toggle.performClick(nil)
    precondition(native.frame.height == collapsed)
    NativeUserMessageView.recycle(native)
    let reused = NativeUserMessageView.acquire()
    reused.expansionKey = "reading-controls:other"
    reused.update(NativeUserMessageView.content("短问题")!, dark: false)
    reused.place(width: 540)
    precondition(reused.measure(width: 540).height < 80)
    precondition(controlViews(reused).compactMap { $0 as? NSButton }.allSatisfy(\.isHidden))
    NativeUserMessageView.recycle(reused)

    let fallback = NSHostingView(rootView: LongUserPrompt { KimiMarkdown(text: long + "\n\n```swift\nprint(1)\n```") }
        .environment(\.conversationMemoryKey, "reading-controls:fallback")
        .frame(width: 480).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    window.contentView = fallback; window.setContentSize(NSSize(width: 720, height: 700)); window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(450))
    // The toggle sits 6 pt below the folded prompt and is 24 pt tall; click its middle.
    controlClick(window, x: 48, top: UserMessageStyle.collapsedHeight + 6 + 12)
    try await Task.sleep(for: .milliseconds(200))
    precondition(memory.expansions["reading-controls:fallback:user-prompt"] == true, "Actual fallback button expands full Markdown")

    let outputA = String(repeating: "第一段日志 ", count: 1200) + "OUTPUT_A_END"
    let outputB = String(repeating: "第二段日志 ", count: 1200) + "OUTPUT_B_END"
    let siblings = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
        DisclosureReplyText(text: outputA)
        DisclosureReplyText(text: outputB)
    }.environment(\.conversationMemoryKey, "reading-controls:output-siblings")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    window.contentView = siblings
    window.setContentSize(NSSize(width: 720, height: 900))
    try await Task.sleep(for: .milliseconds(300))
    controlClick(window, x: 65, top: 375)
    try await Task.sleep(for: .milliseconds(250))
    precondition(controlViews(siblings).filter { $0.identifier?.rawValue == "perch-long-output" }.count == 1,
                 "Manually expanding one output must not expand its sibling in the same tool scope")
    precondition(controlViews(siblings).compactMap { $0 as? NSTextView }.contains { $0.string.hasSuffix("OUTPUT_A_END") })
    precondition(!controlViews(siblings).compactMap { $0 as? NSTextView }.contains { $0.string.hasSuffix("OUTPUT_B_END") })

    func message(_ id: String, _ text: String, thinking: Bool = false, user: Bool = false) throws -> KimiMessage {
        let object: [String: Any] = ["id":id, "role":user ? "user" : "assistant", "created_at":"1",
            "content":[["type":thinking ? "thinking" : "text", thinking ? "thinking" : "text":text]]]
        return try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let rows = try (0..<19).map { index -> ConversationPresentationModel.Row in
        let entry = ConversationTimelineEntry.make([try message("page-\(index)", "记录 \(index)", thinking: true)]).first!
        return .init(entry: entry, tools: [:], activity: nil)
    }
    for size: CGFloat in [14, 18] {
        ReadingBodySize.shared.set(size)
        let key = "reading-controls:pages:\(Int(size))"
        memory.expansions[key + ":process-fold"] = true
        let pages = NSHostingView(rootView: ProcessFoldRow(rows: rows, api: nil, sessionId: "reading-controls")
            .environment(\.conversationMemoryKey, key)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        window.contentView = pages; window.setContentSize(NSSize(width: 720, height: 700))
        try await Task.sleep(for: .milliseconds(300))
        func mountedEntries() -> [String] { controlViews(pages).compactMap(\.identifier?.rawValue).filter { $0.hasPrefix("process-entry:") } }
        precondition(mountedEntries().count == 8)
        for (button, page) in [("next", 1), ("next", 2), ("previous", 1), ("previous", 0)] {
            controlClick(window, identifier: "process-\(button)-page")
            try await Task.sleep(for: .milliseconds(250))
            let start = page * ConversationProcessPage.size
            precondition(memory.processPages[key] == rows[start].entry.id, "Actual \(button)-page button selects page \(page + 1) at \(size)pt")
            let expected = rows[start..<min(start + ConversationProcessPage.size, rows.count)].map { "process-entry:" + $0.entry.id }
            precondition(Set(mountedEntries()) == Set(expected), "Only the selected bounded page is mounted")
        }
    }
    ReadingBodySize.shared.set(ReadingBodySize.standard)

    var messages = [try message("prompt", long + "\nPROMPT_FIND_END", user: true)]
    messages += try (0..<300).map { try message("thought-\($0)", ($0 == 299 ? String(repeating: "长内容 👨‍👩‍👧‍👦 é ", count: 800) : "") + "PAGE_FIND_\($0)", thinking: true) }
    messages += [try message("answer", "已完成")]
    let targetEntry = ConversationTimelineEntry.make(messages).first { $0.messages.contains { $0.id == "thought-299" } }!
    let transcript = NSHostingView(rootView: ConversationScrollView {
        ConversationTranscript(messages: messages, sessionId: "reading-controls-find", foldsProcess: true)
    })
    window.contentView = transcript; window.setContentSize(NSSize(width: 720, height: 700))
    try await Task.sleep(for: .milliseconds(350))
    let promptEntry = ConversationTimelineEntry.make(messages).first!
    NotificationCenter.default.post(name: .init("PerchRevealConversationHit"), object: ConversationFindTarget(
        session: "reading-controls-find", hit: .init(entryID: promptEntry.id, occurrence: 0, excerpt: "PROMPT_FIND_END"), query: "PROMPT_FIND_END"))
    try await Task.sleep(for: .milliseconds(450))
    precondition(controlViews(transcript).compactMap { $0 as? NSTextView }.contains {
        $0.selectedRange().length > 0 && ($0.string as NSString).substring(with: $0.selectedRange()) == "PROMPT_FIND_END"
    }, "Find expands a long prompt and selects its hidden tail")
    NotificationCenter.default.post(name: .init("PerchRevealConversationHit"), object: ConversationFindTarget(
        session: "reading-controls-find", hit: .init(entryID: targetEntry.id, occurrence: 0, excerpt: "PAGE_FIND_299"), query: "PAGE_FIND_299"))
    try await Task.sleep(for: .milliseconds(600))
    let texts = controlViews(transcript).compactMap { $0 as? NSTextView }
    precondition(texts.contains { $0.string.contains("PAGE_FIND_299") }, "Find opens the target process page and nested thought")
    precondition(texts.contains { $0.selectedRange().length > 0 && ($0.string as NSString).substring(with: $0.selectedRange()) == "PAGE_FIND_299" }, "Find selects the actual occurrence")
    print("PASS: measured native/fallback long-question folds, full Unicode source, recycled identity, bounded page clicks and search to a later page")

    let request: JSONValue = .object(["id": .string("plan"), "planReview": .object([
        "revision": .string("v1"), "content": .string("# 实施计划\n\n1. 修改阅读布局\n2. 验证搜索和复制\n3. 提交结果"), "complete": .bool(true), "status": .string("awaiting_review")])])
    let plan = NativePlanReview(request)!
    let state = PlanReviewState(); state.update(plan)
    var sends = 0
    let panel = NSHostingView(rootView: PlanReviewPanel(state: state, online: true) { _, _, _ in sends += 1 }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    window.contentView = panel; window.setContentSize(NSSize(width: 720, height: 700))
    try await Task.sleep(for: .milliseconds(250))
    for (character, key) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: key)!)
    }
    try await Task.sleep(for: .milliseconds(150))
    precondition(sends == 0, "Return, Escape and preview dismissal never approve")
    if ProcessInfo.processInfo.environment["PERCH_CAPTURE_READING_CONTROLS"] == "1" {
        let renderer = ImageRenderer(content: panel.rootView.frame(width: 720, height: 700).background(Color(nsColor: .windowBackgroundColor)))
        if let image = renderer.cgImage {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("plan-review.png"))
        }
    }
    state.feedback = "保留回滚方案"
    await state.submit("request_changes") { current, decision, feedback in
        precondition(current == plan && decision == "request_changes" && feedback == "保留回滚方案")
        state.update(nil)
        throw WorkbenchError("计划已在另一客户端处理")
    }
    precondition(!state.submitting && state.feedback == "保留回滚方案" && state.displayed == plan && state.notice != nil && !state.canDecide)
    state.dismissNotice(); precondition(state.displayed == nil)
    state.update(plan)
    await state.submit("approve") { _, _, _ in }
    precondition(!state.canDecide, "Accepted mutation with a stale read cannot be submitted twice")
    state.update(nil)
    precondition(state.displayed == nil)
    print("PASS: plan review neutral keyboard, scoped payload, conflict retention, feedback preservation and duplicate-submit prevention")
}
