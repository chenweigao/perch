import AppKit
import SwiftUI
import WorkbenchCore

@MainActor func checkTaskContextPanel() async throws {
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    AppLanguage.applyToSystem(.zhHans)
    NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-task-panel-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "# 方案\n\n用于任务面板的文档。".write(to: root.appendingPathComponent("Report.md"), atomically: true, encoding: .utf8)
    let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "Task panel fixture", destination: "")
    let a = SessionReference(hostID: host.id, terminalID: "a", kind: .claude)
    let b = SessionReference(hostID: host.id, terminalID: "b", kind: .claude)
    var reads: [String] = [], stops: [String] = []
    var stopped = false
    func summary(_ id: String) -> [String: Any] {
        ["id": id, "provider": "claude", "title": id == "a" ? "整理项目方案" : "准备调研报告",
         "cwd": root.path, "busy": false, "archived": false, "updated": 1, "completed": 1,
         "pending": id == "a" ? 1 : 0, "model": "fixture"]
    }
    let connection = NativeAgentConnection(host: host) { path, body in
        reads.append(path)
        if path == "/sessions" { return try JSONSerialization.data(withJSONObject: ["sessions": [summary("a"), summary("b")]]) }
        if path.hasSuffix("/stop") {
            stops.append(path); stopped = true
            return Data("{}".utf8)
        }
        let id = path.split(separator: "/").last!.split(separator: "?").first.map(String.init)!
        var data = summary(id)
        data["revision"] = stopped ? 2 : 1
        data["messages"] = [
            ["id": "u", "role": "user", "created_at": "", "content": [["type": "text", "text": "整理方案"]]],
            ["id": "a", "role": "assistant", "created_at": "", "content": [
                ["type": "text", "text": "## 调研报告\n\n已整理参考资料和关键结论，接下来会核对文档中的时间范围。\n\n你可以继续在正文里阅读与补充要求，也可以从右侧任务面板打开[方案](Report.md)。"],
                ["type": "tool_use", "tool_call_id": "write", "tool_name": "Write", "input": ["file_path": "Report.md"]],
                ["type": "tool_use", "tool_call_id": "failed", "tool_name": "Read", "input": ["path": "missing.txt"]]
            ]],
            ["id": "r", "role": "tool", "created_at": "", "content": [
                ["type": "tool_result", "tool_call_id": "write", "is_error": false, "output": "Saved"],
                ["type": "tool_result", "tool_call_id": "failed", "is_error": true, "output": "Not found"]
            ]]
        ]
        if id == "b" {
            data["messages"] = [["id": "report", "role": "assistant", "created_at": "", "content": [[
                "type": "text", "text": "## 调研报告\n\n参考资料已整理。右侧面板可以查看文档，正文继续保留阅读空间。\n\n" +
                    ["Report", "References", "Notes", "Outline", "Appendix", "Summary"].map { "- [\($0)](\($0).md)" }.joined(separator: "\n")
            ]]]]
        }
        data["interactions"] = id == "a" ? [["id": "question", "title": "报告需要包含哪些时间范围？"]] : []
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        data["subagents"] = id == "a" ? [[
            "id": "research", "kind": "claude", "taskId": "child", "toolUseIds": ["research"],
            "description": "核对参考资料", "subagentType": "Explore", "status": stopped ? "stopped" : "running",
            "canStop": !stopped, "stopRequested": false, "startedAt": formatter.string(from: Date()),
            "updatedAt": formatter.string(from: Date()), "lastToolName": "Read"
        ]] : []
        return try JSONSerialization.data(withJSONObject: data)
    }
    let model = WorkbenchModel()
    defer { model.shutdown() }
    model.connections = [HostConnection(host: host)]
    model.registerEnvironment(kimi: KimiConnection(host: host), native: connection)
    try await connection.refresh()
    try await Task.sleep(for: .milliseconds(100))
    let second = model.allSessions.first { $0.reference == b }!
    model.open(second)
    try await Task.sleep(for: .milliseconds(150))
    let before = connection.selectedID
    let read = try await model.readTaskContext(a)
    precondition(read.files.count == 1 && read.files[0].written && read.requests.count == 1)
    precondition(read.tasks.count == 1 && connection.selectedID == before && model.selectedReference == b,
                 "Reading a locked task must not select it in the main conversation")
    try await connection.stopTaskContextAgent("research", session: "a")
    precondition(stops == ["/sessions/a/subagents/research/stop"] && connection.selectedID == before)
    let updated = try await model.readTaskContext(a)
    precondition(updated.tasks.first?.status == "cancelled")
    do { try await connection.stopTaskContextAgent("research", session: "a"); fatalError("Cannot stop a finished task") }
    catch { precondition(stops.count == 1) }
    stopped = false

    // A cancellation-ignoring A read cannot replace the newer B presentation.
    let state = TaskContextState()
    var late: CheckedContinuation<TaskContextSnapshot, Never>?
    let old = Task { await state.follow(a, online: true) { await withCheckedContinuation { late = $0 } } }
    await Task.yield()
    let newer = Task { await state.follow(b, online: true) {
        TaskContextSnapshot(title: "B", directory: root.path, busy: false, messages: [])
    } }
    for _ in 0..<20 where state.snapshot?.title != "B" { try await Task.sleep(for: .milliseconds(10)) }
    old.cancel(); late!.resume(returning: read)
    await old.value
    precondition(state.reference == b && state.snapshot?.title == "B" && !state.loading)
    newer.cancel(); await newer.value
    await state.follow(nil, online: false) { fatalError("Hidden panels do not read") }
    precondition(state.snapshot == nil)

    model.taskContextWindow.locked = a
    model.taskContextWindow.show(model: model)
    let window = model.taskContextWindow.window!
    try await Task.sleep(for: .milliseconds(400))
    precondition(window.isVisible && model.selectedReference == b)
    for width: CGFloat in [340, 420, 620] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.setContentSize(NSSize(width: width, height: 640))
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(150))
            window.displayIfNeeded()
            precondition(abs(window.contentView!.bounds.width - width) < 1)
            if let directory = ProcessInfo.processInfo.environment["PERCH_TASK_PANEL_CAPTURES"],
               let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("task-\(Int(width))-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
    func click(_ x: CGFloat, _ distanceFromTop: CGFloat, in target: NSWindow? = nil) {
        let window = target ?? window
        let view = window.contentView!
        let y = view.isFlipped ? distanceFromTop : view.bounds.height - distanceFromTop
        let point = view.convert(NSPoint(x: x, y: y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
    }
    click(window.contentView!.bounds.width - 26, 26)
    try await Task.sleep(for: .milliseconds(150))
    precondition(model.taskContextWindow.locked == nil, "The native pin control resumes following")
    click(window.contentView!.bounds.width - 26, 26)
    try await Task.sleep(for: .milliseconds(150))
    precondition(model.taskContextWindow.locked == b, "The native pin control captures the current task")
    model.taskContextWindow.locked = a
    try await Task.sleep(for: .milliseconds(150))
    connection.drafts["a"] = "原有草稿"
    connection.drafts["b"] = "其他任务草稿"
    click(window.contentView!.bounds.width - 48, window.contentView!.bounds.height - 22)
    try await Task.sleep(for: .milliseconds(250))
    guard let sheet = window.attachedSheet else { fatalError("Add instructions must open a captured-task draft sheet") }
    sheet.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(250))
    guard let editor = sheet.firstResponder as? NSTextView else { fatalError("Task draft input must start focused") }
    editor.insertText("补充验证依据", replacementRange: editor.selectedRange())
    try await Task.sleep(for: .milliseconds(100))
    let submit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    precondition(sheet.performKeyEquivalent(with: submit))
    try await Task.sleep(for: .milliseconds(200))
    precondition(connection.drafts["a"] == "原有草稿\n\n补充验证依据" && connection.drafts["b"] == "其他任务草稿")
    precondition(!reads.contains { $0.contains("/prompt") }, "Adding a draft must never send")
    model.open(second)
    try await Task.sleep(for: .milliseconds(150))
    model.openWorkspaceFile(GroupOutcome(title: "方案", link: read.files[0].path, source: a))
    for _ in 0..<100 where model.fileBrowser.loading { try await Task.sleep(for: .milliseconds(20)) }
    precondition(model.fileBrowser.documents.current?.source == a && model.selectedReference == b)
    model.fileWindow.close()
    model.taskContextWindow.locked = nil
    try await Task.sleep(for: .milliseconds(200))
    precondition(model.selectedReference == b && connection.selectedID == b.terminalID)
    model.taskContextWindow.close()
    try await Task.sleep(for: .milliseconds(100))
    let count = reads.count
    try await Task.sleep(for: .milliseconds(2200))
    precondition(reads.count == count, "Closing a panel must end its reads")
    precondition(!model.taskContextWindow.visible && model.taskContextWindow.window == nil)
    model.taskContextWindow.show(model: model)
    precondition(model.taskContextWindow.window != nil, "A closed panel can be reopened")
    model.taskContextWindow.close()

    // Measure actual laid-out cards, including expansion and overflow, rather
    // than asserting the same size formula as the implementation.
    let fitting = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 700),
                           styleMask: [.titled], backing: .buffered, defer: false)
    fitting.isReleasedWhenClosed = false
    defer { fitting.close(); fitting.contentViewController = nil }
    var fittedView: NSView?
    fitting.contentViewController = NSHostingController(rootView: VStack(spacing: 0) {
        TaskContextView(model: model, maximumHeight: 420)
            .background(TaskContextContentProbe { fittedView = $0 })
        Spacer(minLength: 0)
    })
    fitting.setContentSize(NSSize(width: 340, height: 700))
    model.taskContextWindow.locked = b
    fitting.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(300))
    let shortHeight = fittedView!.bounds.height
    precondition(shortHeight > 150 && shortHeight < 360, "Short content should shrink: \(shortHeight)")
    click(70, shortHeight - 24, in: fitting)
    try await Task.sleep(for: .milliseconds(200))
    let expandedHeight = fittedView!.bounds.height
    precondition(expandedHeight > shortHeight + 30 && expandedHeight <= 420,
                 "Expanding files should grow the card: \(shortHeight) -> \(expandedHeight)")
    click(40, expandedHeight - 24, in: fitting)
    try await Task.sleep(for: .milliseconds(200))
    precondition(abs(fittedView!.bounds.height - shortHeight) < 1, "Collapsing files should shrink again")
    model.taskContextWindow.locked = a
    try await Task.sleep(for: .milliseconds(250))
    precondition(abs(fittedView!.bounds.height - 420) < 1, "Long content stops at the available height")
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    let scroll = scrollViews(fitting.contentView!).first!
    precondition(scroll.documentView!.frame.height > scroll.contentView.bounds.height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.documentView!.frame.height - scroll.contentView.bounds.height))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(100))
    precondition(scroll.contentView.bounds.minY > 0 && abs(fittedView!.bounds.height - 420) < 1)
    fitting.close(); fitting.contentViewController = nil

    // Exercise the embedded production container with a real transcript/composer.
    // Its content identity must survive toggling and crossing the width breakpoint.
    let page = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 780),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    page.isReleasedWhenClosed = false
    defer { page.close(); page.contentViewController = nil }
    var contentMounts = 0
    var contentView: NSView?
    let hosting = NSHostingController(rootView: VStack(spacing: 0) {
        HStack {
            Text("准备调研报告").font(.headline)
            Spacer()
            TaskContextButton(model: model)
        }.padding(.horizontal, 18).frame(height: 44)
        TaskContextWorkspace(model: model) {
            NativeAgentView(connection: connection, onResultDisplayed: { _ in })
                .background(TaskContextContentProbe { view in contentMounts += 1; contentView = view })
        }
    }.background(WorkbenchTheme.contentBackground))
    hosting.sizingOptions = []
    page.contentViewController = hosting
    page.setContentSize(NSSize(width: 1200, height: 780))
    page.makeKeyAndOrderFront(nil)
    model.taskContextWindow.locked = a
    try await Task.sleep(for: .milliseconds(200))
    precondition(!model.taskContextWindow.embeddedVisible)
    if let directory = ProcessInfo.processInfo.environment["PERCH_TASK_PANEL_CAPTURES"],
       let view = page.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to:
            URL(fileURLWithPath: directory).appendingPathComponent("layout-closed.png"))
    }
    click(1200 - 32, 22, in: page)
    try await Task.sleep(for: .milliseconds(250))
    precondition(model.taskContextWindow.embeddedVisible && model.taskContextWindow.window == nil,
                 "The header opens in-page without creating a window: size=\(page.contentView!.bounds.size), embedded=\(model.taskContextWindow.embeddedVisible)")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func editors(_ view: NSView) -> [DraftTextView] { descendants(view).compactMap { $0 as? DraftTextView } }
    func readingColumn() -> NSView {
        descendants(page.contentView!).first { String(describing: type(of: $0)) == "ConversationDocumentView" }!
    }
    func horizontalFrames() -> (reading: CGRect, editor: CGRect) {
        let document = readingColumn(), editor = editors(page.contentView!).first!
        return (document.convert(document.bounds, to: page.contentView), editor.convert(editor.bounds, to: page.contentView))
    }
    let opened = horizontalFrames()
    precondition(abs(opened.reading.width - 680) < 1)
    click(1200 - 32, 22, in: page)
    try await Task.sleep(for: .milliseconds(150))
    let closed = horizontalFrames()
    precondition(abs(closed.reading.width - opened.reading.width) < 1 && abs(closed.editor.width - opened.editor.width) < 1,
                 "Opening the card must preserve both reading and composer widths")
    precondition(abs(closed.reading.midX - 600) < 1 && abs(closed.editor.midX - 600) < 1,
                 "Closing recenters both columns")
    precondition(closed.reading.minX > opened.reading.minX + 150 &&
                 abs((closed.reading.minX - opened.reading.minX) - (closed.editor.minX - opened.editor.minX)) < 1,
                 "The transcript and composer shift together")
    click(1200 - 32, 22, in: page)
    try await Task.sleep(for: .milliseconds(150))
    for (width, height): (CGFloat, CGFloat) in [(1200, 780), (1100, 780), (1056, 780), (1055, 780), (600, 500), (800, 780), (800, 500)] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            page.setContentSize(NSSize(width: width, height: height))
            page.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(200))
            page.displayIfNeeded()
            let frames = horizontalFrames()
            precondition(abs(frames.reading.width - min(680, width - 72)) < 1,
                         "Context must not squeeze the actual reading column at \(width): \(frames.reading)")
            precondition(abs(frames.reading.midX - frames.editor.midX) < 1,
                         "Transcript and composer must remain aligned")
            if width < 1056 {
                precondition(abs(contentView!.bounds.width - width) < 1 && abs(frames.reading.midX - width / 2) < 1)
                let text = descendants(readingColumn()).compactMap { $0 as? ReplyTextView }
                    .first { !$0.visibleRect.isEmpty }!
                let point = text.convert(NSPoint(x: text.visibleRect.minX + 8, y: text.visibleRect.minY + 8),
                                         to: page.contentView!.superview)
                let target = page.contentView!.hitTest(point)
                // Native block padding may hit its stack rather than NSTextView;
                // either must remain inside the transcript, never the context strip.
                precondition(target?.isDescendant(of: readingColumn()) == true,
                             "Compact context must leave the transcript available to pointer input: width=\(width), target=\(String(describing: target))")
            }
            if let directory = ProcessInfo.processInfo.environment["PERCH_TASK_PANEL_CAPTURES"],
               let view = page.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("layout-\(Int(width))-\(Int(height))-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
    page.setContentSize(NSSize(width: 1200, height: 780))
    page.appearance = NSAppearance(named: .aqua)
    model.taskContextWindow.locked = nil
    try await Task.sleep(for: .milliseconds(200))
    if let directory = ProcessInfo.processInfo.environment["PERCH_TASK_PANEL_CAPTURES"],
       let view = page.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to:
            URL(fileURLWithPath: directory).appendingPathComponent("layout-documents.png"))
    }
    // The full card still exposes detach; returning to a compact page keeps
    // the reading position and draft in the same mounted conversation.
    click(1200 - 68, 44 + 12 + 22, in: page)
    try await Task.sleep(for: .milliseconds(150))
    precondition(model.taskContextWindow.visible && !model.taskContextWindow.embeddedVisible)
    model.taskContextWindow.embed(model: model)
    page.setContentSize(NSSize(width: 800, height: 500))
    page.appearance = NSAppearance(named: .darkAqua)
    try await Task.sleep(for: .milliseconds(150))
    let composer = editors(page.contentView!).first!
    page.makeKeyAndOrderFront(nil)
    // Check AppKit's actual pointer target separately from keyboard focus. A
    // synthetic NSWindow.sendEvent doesn't reliably focus NSTextView here.
    func checkInputTarget() {
        let point = composer.convert(NSPoint(x: composer.visibleRect.maxX - 25, y: composer.visibleRect.minY + 8),
                                     to: page.contentView!.superview)
        precondition(page.contentView!.hitTest(point) === composer,
                     "The compact card must leave the actual composer available to pointer input")
    }
    checkInputTarget()
    precondition(page.makeFirstResponder(composer))
    composer.insertText(String(repeating: "\n补充验证依据", count: 8),
                        replacementRange: NSRange(location: composer.string.utf16.count, length: 0))
    try await Task.sleep(for: .milliseconds(200))
    precondition(connection.drafts["b"]!.contains("补充验证依据") && composer.visibleRect.height > 80)
    checkInputTarget()
    connection.drafts["b"] = "其他任务草稿"
    try await Task.sleep(for: .milliseconds(150))
    model.taskContextWindow.locked = b
    try await Task.sleep(for: .milliseconds(200))
    if let directory = ProcessInfo.processInfo.environment["PERCH_TASK_PANEL_CAPTURES"],
       let view = page.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to:
            URL(fileURLWithPath: directory).appendingPathComponent("layout-compact-documents.png"))
    }
    model.taskContextWindow.locked = a
    click(800 - 32, 22, in: page)
    try await Task.sleep(for: .milliseconds(200))
    precondition(!model.taskContextWindow.embeddedVisible && abs(contentView!.bounds.width - 800) < 1)
    let hiddenReads = reads.filter { $0 == "/sessions/a?turns=20" }.count
    try await Task.sleep(for: .milliseconds(2200))
    precondition(reads.filter { $0 == "/sessions/a?turns=20" }.count == hiddenReads,
                 "Collapsing the in-page card ends its reads")
    click(800 - 32, 22, in: page)
    try await Task.sleep(for: .milliseconds(150))
    // Compact context opens its independent window without covering the page.
    click(660, 44 + 24, in: page)
    try await Task.sleep(for: .milliseconds(200))
    precondition(model.taskContextWindow.visible && !model.taskContextWindow.embeddedVisible)
    let detached = model.taskContextWindow.window!
    click(detached.contentView!.bounds.width - 50, 26, in: detached)
    try await Task.sleep(for: .milliseconds(200))
    precondition(model.taskContextWindow.embeddedVisible && !model.taskContextWindow.visible && model.taskContextWindow.window == nil,
                 "Docking returns to the page and releases the separate window")
    precondition(contentMounts == 1 && model.selectedReference == b && connection.drafts["b"] == "其他任务草稿",
                 "Panel layout changes must preserve transcript identity, selection and draft")
    page.makeKeyAndOrderFront(nil)
    click(728, 44 + 24, in: page)
    try await Task.sleep(for: .milliseconds(150))
    precondition(!model.taskContextWindow.embeddedVisible, "The card close control collapses it")
    print("PASS: task context fixed reading/composer widths, synchronized shifting and recentering, adaptive card and compact transcript/composer hit testing, content-fit/expand/collapse/overflow heights, multiline input, native windows, wide/compact light/dark, toggle/detach/dock/close/pin/draft controls, stable transcript, source isolation, stop targeting, cancellation and file route")
}

private struct TaskContextContentProbe: NSViewRepresentable {
    let mounted: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); mounted(view); return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
