import AppKit
import SwiftUI
import WorkbenchCore

@MainActor func checkTaskContextPanel() async throws {
    func precondition(_ condition: @autoclosure () -> Bool,
                      _ message: @autoclosure () -> String = String(),
                      file: StaticString = #filePath,
                      line: UInt = #line) {
        guard condition() else {
            let detail = message()
            FileHandle.standardOutput.write(Data("TASK-CONTEXT-FAIL line=\(line): \(detail)\n".utf8))
            Swift.preconditionFailure(detail, file: file, line: line)
        }
    }

    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    let legacySplitFramesKey = "NSSplitView Subview Frames WorkbenchWorkspace"
    UserDefaults.standard.set([
        "0.000000, 0.000000, 15.000000, 780.000000, NO, NO",
        "16.000000, 0.000000, 1264.000000, 780.000000, NO, NO",
    ], forKey: legacySplitFramesKey)
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

    // Exercise the production AppKit split container with a real transcript and
    // composer. The conversation host must survive inspector and destination changes.
    let page = TaskContextFixtureWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 780),
                                       styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    page.isReleasedWhenClosed = false
    defer { page.close(); page.contentViewController = nil }
    var contentMounts = 0
    var contentView: NSView?
    let hosting = NSHostingController(rootView: TaskContextInspectorFixture(
        model: model, connection: connection,
        contentMounted: { view in contentMounts += 1; contentView = view }))
    hosting.sizingOptions = []
    page.contentViewController = hosting
    page.makeKeyAndOrderFront(nil)
    page.setContentSize(NSSize(width: 1280, height: 780))
    model.showDashboard = false
    model.draftingNewTask = false
    model.taskContextWindow.locked = a
    try await Task.sleep(for: .milliseconds(300))

    func splitController(from mountedView: NSView?) -> WorkbenchSplitController? {
        var responder: NSResponder? = mountedView
        while let current = responder {
            if let split = current as? WorkbenchSplitController { return split }
            if let controller = current as? NSViewController {
                var parent = controller.parent
                while let candidate = parent {
                    if let split = candidate as? WorkbenchSplitController { return split }
                    parent = candidate.parent
                }
            }
            responder = current.nextResponder
        }
        return nil
    }
    guard let split = splitController(from: contentView) else { fatalError("The production split controller must mount") }
    precondition(split.splitViewItems.count == 2,
                 "The workspace split must contain only the full canvas and inline inspector")
    let detailItem = split.splitViewItems[0]
    let inspectorItem = split.splitViewItems[1]
    func splitFrame(_ item: NSSplitViewItem) -> NSRect {
        let view = item.viewController.view
        return view.convert(view.bounds, to: split.view)
    }
    func frame(_ view: NSView?) -> NSRect {
        guard let view else { return .zero }
        return view.convert(view.bounds, to: split.view)
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func traceLayout(_ stage: String) {
        let parent = split.splitView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let line = "TASK-CONTEXT-LAYOUT \(stage): collapsed=\(inspectorItem.isCollapsed), sidebarVisible=\(split.isFloatingSidebarVisible), inset=\(split.detailContentLeadingInset), overlay=\(split.isSidebarOverlayingContent), detail=\(splitFrame(detailItem)), inspector=\(splitFrame(inspectorItem)), split=\(frame(split.splitView)), root=\(split.view.bounds), parent=\(parent), directChild=\(split.splitView.superview === split.view), translates=\(split.splitView.translatesAutoresizingMaskIntoConstraints), autoresizing=\(split.splitView.autoresizingMask.rawValue), window=\(String(describing: page.contentView?.bounds))"
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    precondition(split.splitView.autosaveName == "WorkbenchWorkspace.v3",
                 "The floating-sidebar layout must not restore an older split topology")
    precondition(UserDefaults.standard.array(forKey: legacySplitFramesKey)?.count == 2,
                 "Mounting the new layout must leave the legacy autosave value isolated")
    precondition(inspectorItem.isCollapsed && !model.taskContextWindow.embeddedVisible)
    var detailFrame = splitFrame(detailItem)
    var sidebarFrame = frame(split.floatingSidebarView)
    let safeFrame = split.view.safeAreaRect
    traceLayout("mounted")
    precondition(split.isFloatingSidebarVisible && !split.floatingSidebarView!.isHidden &&
                 abs(sidebarFrame.minX - WorkspaceLayoutMetrics.sidebarInset) < 1 &&
                 sidebarFrame.minY >= WorkspaceLayoutMetrics.sidebarInset - 1 &&
                 safeFrame.maxY - sidebarFrame.maxY >= WorkspaceLayoutMetrics.sidebarInset - 1,
                 "The sidebar must float with visible left, top, and bottom margins: panel=\(sidebarFrame), safe=\(safeFrame)")
    precondition(detailFrame.intersection(sidebarFrame).width >= sidebarFrame.width - 1,
                 "The floating sidebar must overlap the full canvas instead of consuming a split column")

    model.taskContextWindow.embeddedVisible = true
    try await Task.sleep(for: .milliseconds(300))
    split.splitView.layoutSubtreeIfNeeded()
    page.displayIfNeeded()
    detailFrame = splitFrame(detailItem)
    sidebarFrame = frame(split.floatingSidebarView)
    var inspectorFrame = splitFrame(inspectorItem)
    var hostedContentFrame = frame(split.detailContentView)
    traceLayout("wide")
    precondition(!inspectorItem.isCollapsed,
                 "Opening at 1280 points must keep the inline inspector visible")
    precondition(inspectorFrame.width >= 279 && inspectorFrame.width <= 421,
                 "Inspector width must stay within its native 280–420 point range: \(inspectorFrame)")
    precondition(abs(inspectorFrame.height - split.splitView.bounds.height) < 1 &&
                 abs(detailFrame.height - inspectorFrame.height) < 1,
                 "Inspector and detail must share the full split-view height")
    precondition(inspectorFrame.minX >= detailFrame.maxX &&
                 inspectorFrame.minX - detailFrame.maxX <= split.splitView.dividerThickness + 1,
                 "Inspector must be adjacent to, not overlay, the conversation")
    precondition(split.detailContentLeadingInset > 0 &&
                 hostedContentFrame.minX >= sidebarFrame.maxX + WorkspaceLayoutMetrics.sidebarGap - 1,
                 "A wide canvas must keep hosted content clear of the floating sidebar")
    precondition(contentView?.window === page)

    page.setContentSize(NSSize(width: 1000, height: 780))
    for _ in 0..<20 {
        split.view.layoutSubtreeIfNeeded(); page.displayIfNeeded()
        if inspectorItem.isCollapsed && split.detailContentLeadingInset > 0 { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    detailFrame = splitFrame(detailItem)
    var splitBoundsFrame = frame(split.splitView)
    traceLayout("responsive")
    let collapsedDividerAllowance = split.splitView.dividerThickness + 1
    precondition(inspectorItem.isCollapsed && split.isFloatingSidebarVisible &&
                 split.detailContentLeadingInset > 0 &&
                 abs(splitBoundsFrame.minX - split.view.bounds.minX) < 1 &&
                 abs(splitBoundsFrame.maxX - split.view.bounds.maxX) < 1 &&
                 abs(detailFrame.minX - splitBoundsFrame.minX) < 1 &&
                 splitBoundsFrame.maxX - detailFrame.maxX <= collapsedDividerAllowance,
                 "At 1000 points the inspector must yield before the sidebar stops avoiding content; inspectorCollapsed=\(inspectorItem.isCollapsed), sidebarVisible=\(split.isFloatingSidebarVisible), inset=\(split.detailContentLeadingInset), overlay=\(split.isSidebarOverlayingContent), detail=\(detailFrame), split=\(splitBoundsFrame), root=\(split.view.bounds), window=\(String(describing: page.contentView?.bounds))")

    page.setContentSize(NSSize(width: 800, height: 780))
    for _ in 0..<20 {
        split.view.layoutSubtreeIfNeeded(); page.displayIfNeeded()
        if inspectorItem.isCollapsed && split.isSidebarOverlayingContent { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    detailFrame = splitFrame(detailItem)
    splitBoundsFrame = frame(split.splitView)
    traceLayout("responsive")
    precondition(inspectorItem.isCollapsed && split.isFloatingSidebarVisible &&
                 split.isSidebarOverlayingContent && split.detailContentLeadingInset == 0 &&
                 abs(splitBoundsFrame.minX - split.view.bounds.minX) < 1 &&
                 abs(splitBoundsFrame.maxX - split.view.bounds.maxX) < 1 &&
                 abs(detailFrame.minX - splitBoundsFrame.minX) < 1 &&
                 splitBoundsFrame.maxX - detailFrame.maxX <= collapsedDividerAllowance,
                 "At 800 points the sidebar must overlay, not compress, the full conversation canvas; inspectorCollapsed=\(inspectorItem.isCollapsed), sidebarVisible=\(split.isFloatingSidebarVisible), inset=\(split.detailContentLeadingInset), overlay=\(split.isSidebarOverlayingContent), detail=\(detailFrame), split=\(splitBoundsFrame), root=\(split.view.bounds), window=\(String(describing: page.contentView?.bounds))")

    page.setContentSize(NSSize(width: 1280, height: 780))
    for _ in 0..<20 {
        split.view.layoutSubtreeIfNeeded(); page.displayIfNeeded()
        if !inspectorItem.isCollapsed && !split.isSidebarOverlayingContent { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    detailFrame = splitFrame(detailItem)
    inspectorFrame = splitFrame(inspectorItem)
    splitBoundsFrame = frame(split.splitView)
    traceLayout("responsive")
    precondition(!inspectorItem.isCollapsed && split.isFloatingSidebarVisible &&
                 !split.isSidebarOverlayingContent && detailFrame.width >= 599 &&
                 inspectorFrame.width >= 279 && inspectorFrame.width <= 421 &&
                 abs(splitBoundsFrame.minX - split.view.bounds.minX) < 1 &&
                 abs(splitBoundsFrame.maxX - split.view.bounds.maxX) < 1,
                 "Restoring a wide window must restore the inline inspector and sidebar avoidance; inspectorCollapsed=\(inspectorItem.isCollapsed), sidebarVisible=\(split.isFloatingSidebarVisible), inset=\(split.detailContentLeadingInset), overlay=\(split.isSidebarOverlayingContent), detail=\(detailFrame), inspector=\(inspectorFrame), split=\(splitBoundsFrame), root=\(split.view.bounds), window=\(String(describing: page.contentView?.bounds))")

    let canvasBeforeToggle = detailFrame
    split.toggleSidebar(nil)
    split.view.layoutSubtreeIfNeeded(); page.displayIfNeeded()
    detailFrame = splitFrame(detailItem)
    hostedContentFrame = frame(split.detailContentView)
    let composerForCentering = descendants(page.contentView!).compactMap { $0 as? DraftTextView }.first!
    let composerSurfaceForCentering = composerForCentering.enclosingScrollView ?? composerForCentering
    let centeredComposerFrame = composerSurfaceForCentering.convert(composerSurfaceForCentering.bounds, to: split.view)
    precondition(!split.isFloatingSidebarVisible && split.floatingSidebarView!.isHidden &&
                 split.detailContentLeadingInset == 0 && detailFrame == canvasBeforeToggle &&
                 abs(hostedContentFrame.minX - detailFrame.minX) < 1 &&
                 abs(hostedContentFrame.width - detailFrame.width) < 1 &&
                 abs(centeredComposerFrame.midX - detailFrame.midX) < 2 &&
                 UserDefaults.standard.bool(forKey: WorkbenchSplitController.sidebarVisibilityDefaultsKey) == false,
                 "Hiding the sidebar must leave the canvas fixed and center reading controls in the full detail area")
    split.toggleSidebar(nil)
    split.setFloatingSidebarWidth(10_000)
    precondition(split.floatingSidebarWidth == WorkspaceLayoutMetrics.sidebarMaximumWidth)
    split.setFloatingSidebarWidth(1)
    split.view.layoutSubtreeIfNeeded(); page.displayIfNeeded()
    let restoredSidebarState = WorkbenchSplitController()
    precondition(split.isFloatingSidebarVisible &&
                 split.floatingSidebarWidth == WorkspaceLayoutMetrics.sidebarMinimumWidth &&
                 restoredSidebarState.isFloatingSidebarVisible &&
                 restoredSidebarState.floatingSidebarWidth == WorkspaceLayoutMetrics.sidebarMinimumWidth &&
                 UserDefaults.standard.double(forKey: WorkbenchSplitController.sidebarWidthDefaultsKey) ==
                    Double(WorkspaceLayoutMetrics.sidebarMinimumWidth) &&
                 UserDefaults.standard.bool(forKey: WorkbenchSplitController.sidebarVisibilityDefaultsKey),
                 "Sidebar visibility and clamped resize width must persist")
    let composer = descendants(page.contentView!).compactMap { $0 as? DraftTextView }.first!
    let composerSurface = composer.enclosingScrollView ?? composer
    let pointer = composer.convert(NSPoint(x: composer.visibleRect.maxX - 25, y: composer.visibleRect.minY + 8),
                                   to: page.contentView)
    let hitPoint = page.contentView!.convert(pointer, to: page.contentView!.superview)
    let pointerHit = page.contentView!.hitTest(hitPoint)
    let hitsComposer = pointerHit === composer || pointerHit === composerSurface ||
        (pointerHit?.isDescendant(of: composerSurface) ?? false)

    if let directory = ProcessInfo.processInfo.environment["PERCH_TASK_PANEL_CAPTURES"],
       let view = page.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to:
            URL(fileURLWithPath: directory).appendingPathComponent("layout-inspector.png"))
    }

    if !hitsComposer {
        func ancestry(_ view: NSView?) -> String {
            var entries: [String] = []
            var current = view
            while let node = current {
                let frame = node.window === page ? node.convert(node.bounds, to: page.contentView) : .zero
                entries.append("\(type(of: node)){frame=\(frame),hidden=\(node.isHidden),clips=\(node.clipsToBounds)}")
                current = node.superview
            }
            return entries.joined(separator: " <- ")
        }
        let inspectorRoot = inspectorItem.viewController.view
        let detailRoot = detailItem.viewController.view
        let replyPrefix = (pointerHit as? ReplyTextView)?.string.prefix(120)
            .replacingOccurrences(of: "\n", with: "\\n") ?? "n/a"
        let drafts = descendants(page.contentView!).compactMap { $0 as? DraftTextView }.map { draft in
            "DraftTextView{window=\(draft.window === page),hidden=\(draft.isHidden),editable=\(draft.isEditable),frame=\(draft.convert(draft.bounds, to: page.contentView))}"
        }.joined(separator: "; ")
        let pointerHitDescription = pointerHit.map { String(describing: type(of: $0)) } ?? "nil"
        preconditionFailure("The adjacent inspector must leave the composer available to pointer input; hit=\(pointerHitDescription), pointer=\(pointer), composer=\(composerSurface.convert(composerSurface.bounds, to: page.contentView)), replyPrefix=\(replyPrefix), inInspector=\(pointerHit?.isDescendant(of: inspectorRoot) ?? false), inDetail=\(pointerHit?.isDescendant(of: detailRoot) ?? false), hitAncestry=\(ancestry(pointerHit)), composerAncestry=\(ancestry(composer)), drafts=[\(drafts)]")
    }

    // Workbench and new-task destinations hide the inspector without erasing the
    // user's expanded preference. Returning restores the same native split item.
    model.showDashboard = true
    try await Task.sleep(for: .milliseconds(250))
    precondition(inspectorItem.isCollapsed && model.taskContextWindow.embeddedVisible)
    let dashboardReads = reads.filter { $0 == "/sessions/a?turns=20" }.count
    try await Task.sleep(for: .milliseconds(2200))
    precondition(reads.filter { $0 == "/sessions/a?turns=20" }.count == dashboardReads,
                 "A destination-hidden inspector must end its reads")
    model.showDashboard = false
    try await Task.sleep(for: .milliseconds(250))
    precondition(!inspectorItem.isCollapsed && model.taskContextWindow.embeddedVisible)
    model.draftingNewTask = true
    try await Task.sleep(for: .milliseconds(200))
    precondition(inspectorItem.isCollapsed && model.taskContextWindow.embeddedVisible)
    model.draftingNewTask = false
    try await Task.sleep(for: .milliseconds(250))
    precondition(!inspectorItem.isCollapsed && model.taskContextWindow.embeddedVisible)

    // Direct observation must reflect a native collapse without waiting for a split-view resize notification.
    inspectorItem.isCollapsed = true
    try await Task.sleep(for: .milliseconds(250))
    precondition(!model.taskContextWindow.embeddedVisible,
                 "Collapsing the native inspector must update the task-panel preference")
    let collapsedReads = reads.filter { $0 == "/sessions/a?turns=20" }.count
    try await Task.sleep(for: .milliseconds(2200))
    precondition(reads.filter { $0 == "/sessions/a?turns=20" }.count == collapsedReads,
                 "Collapsing the native inspector must end its reads")

    model.taskContextWindow.embeddedVisible = true
    try await Task.sleep(for: .milliseconds(250))
    precondition(!inspectorItem.isCollapsed)
    model.taskContextWindow.show(model: model)
    try await Task.sleep(for: .milliseconds(250))
    precondition(model.taskContextWindow.visible && !model.taskContextWindow.embeddedVisible && inspectorItem.isCollapsed)
    let detached = model.taskContextWindow.window!
    click(detached.contentView!.bounds.width - 50, 26, in: detached)
    try await Task.sleep(for: .milliseconds(250))
    precondition(model.taskContextWindow.embeddedVisible && !model.taskContextWindow.visible &&
                 model.taskContextWindow.window == nil && !inspectorItem.isCollapsed,
                 "Docking must return to the native inspector and release the panel")

    inspectorItem.isCollapsed = true
    try await Task.sleep(for: .milliseconds(250))
    precondition(!model.taskContextWindow.embeddedVisible && contentMounts == 1 && model.selectedReference == b &&
                 connection.drafts["b"] == "其他任务草稿",
                 "Inspector changes must preserve transcript identity, selection, and draft")
    model.taskContextWindow.locked = nil
    print("PASS: floating sidebar margins, wide avoidance, narrow overlay, full-canvas centering, persisted resize and visibility, native inspector collapse, destination suspension and restore, detached panel round trip, stable transcript, source isolation, stop targeting, cancellation, draft and file route")
}

/// Layout fixtures must exercise viewports larger than the CI runner's display.
/// Production windows keep AppKit's normal screen constraints.
private final class TaskContextFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct TaskContextInspectorFixture: View {
    let model: WorkbenchModel
    let connection: NativeAgentConnection
    let contentMounted: (NSView) -> Void

    var body: some View {
        let inspectorVisible = model.taskContextWindow.embeddedVisible &&
            !model.showDashboard && !model.draftingNewTask
        WorkspaceSplitView(
            newConversation: {},
            inspectorVisible: inspectorVisible,
            inspectorVisibilityChanged: { visible in
                if !model.showDashboard && !model.draftingNewTask {
                    model.taskContextWindow.embeddedVisible = visible
                }
            },
            sidebar: { Color.clear },
            header: { Text("准备调研报告") },
            actions: { TaskContextButton(model: model) },
            inspector: {
                TaskContextView(model: model,
                    detach: { model.taskContextWindow.show(model: model) },
                    close: { model.taskContextWindow.embeddedVisible = false })
            },
            content: {
                NativeAgentView(connection: connection, onResultDisplayed: { _ in })
                    .background(TaskContextContentProbe(mounted: contentMounted))
            })
    }
}

private struct TaskContextContentProbe: NSViewRepresentable {
    let mounted: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); mounted(view); return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
