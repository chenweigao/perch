import AppKit
import ApplicationServices
import SwiftUI
import WorkbenchCore

/// The task page's detail, driven through its real controls. SwiftUI builds the
/// accessibility tree these checks locate controls in only inside AppKit's event
/// loop, so this phase runs interactively, like reading-controls.
@MainActor func checkTaskDetailUI() async throws {
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    AppLanguage.applyToSystem(.zhHans)
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "Task detail fixture", destination: "")
    let a = SessionReference(hostID: host.id, terminalID: "a", kind: .claude)
    let b = SessionReference(hostID: host.id, terminalID: "b", kind: .claude)
    var stops: [String] = []
    var stopped = false
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let started = formatter.string(from: Date().addingTimeInterval(-95))
    func summary(_ id: String) -> [String: Any] {
        ["id": id, "provider": "claude", "title": id == "a" ? "整理项目方案" : "准备调研报告",
         "cwd": NSTemporaryDirectory(), "busy": false, "archived": false, "updated": 1, "completed": 1,
         "pending": 0, "model": "fixture"]
    }
    let connection = NativeAgentConnection(host: host) { path, _ in
        if path == "/sessions" { return try JSONSerialization.data(withJSONObject: ["sessions": [summary("a"), summary("b")]]) }
        if path.hasSuffix("/stop") {
            stops.append(path); stopped = true
            return Data("{}".utf8)
        }
        let id = path.split(separator: "/").last!.split(separator: "?").first.map(String.init)!
        var data = summary(id)
        data["revision"] = stopped ? 2 : 1
        data["messages"] = [["id": "u-" + id, "role": "user", "created_at": "", "content": [["type": "text", "text": "整理方案"]]]]
        data["interactions"] = []
        var entry: [String: Any] = [
            "id": "research", "kind": "claude", "taskId": "child", "toolUseIds": ["research"],
            "description": "核对参考资料", "subagentType": "Explore", "status": stopped ? "stopped" : "running",
            "canStop": !stopped, "stopRequested": false, "startedAt": started,
            "updatedAt": formatter.string(from: Date()), "lastToolName": "Read",
            "usage": ["totalTokens": 18_342, "toolUses": 12]
        ]
        if stopped { entry["summary"] = "已核对 6 份参考资料，其中 2 份的时间范围需要确认。" }
        data["subagents"] = id == "a" ? [entry] : []
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
    model.taskContextWindow.locked = a
    model.taskContextWindow.page = .task
    model.taskContextWindow.embeddedVisible = true
    defer { model.taskContextWindow.embeddedVisible = false; model.taskContextWindow.locked = nil }

    let window = NSWindow(contentRect: NSRect(x: 160, y: 120, width: 360, height: 680), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    defer { window.orderOut(nil); window.contentView = nil }
    window.contentView = NSHostingView(rootView: TaskContextView(model: model)
        .background(Color(nsColor: .windowBackgroundColor)))
    window.makeKeyAndOrderFront(nil)

    @discardableResult func control(_ identifier: String, present: Bool = true, seconds: Double = 3) async throws -> NSRect? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            let frame = taskPanelControl(window, identifier)
            if (frame != nil) == present { return frame }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        preconditionFailure("\(identifier) must \(present ? "appear" : "disappear") in the task panel; identifiers: \(taskPanelIdentifiers(window))")
    }
    func press(_ identifier: String) async throws {
        let frame = try await control(identifier)!
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    // The whole row opens the locked task in place of the list.
    let research = TaskContextRoute(source: a, taskID: "research")
    try await control("task-context-row-research", seconds: 5)
    captureTaskPanel(window.contentView, "task-list")
    try await press("task-context-row-research")
    precondition(model.taskContextWindow.detail == research && model.selectedReference == b,
                 "The whole row opens the task without selecting its session")
    try await control("task-context-back")
    try await control("task-context-result", present: false)
    try await control("task-context-open-session")
    try await control("task-context-transcript", present: false)
    captureTaskPanel(window.contentView, "task-detail-subagent")

    // Stop targets the locked session's subagent; the page updates in place.
    try await press("task-context-stop")
    for _ in 0..<100 where stops.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    precondition(stops == ["/sessions/a/subagents/research/stop"] && model.selectedReference == b,
                 "The detail page stops the locked task's subagent")
    try await control("task-context-stop", present: false, seconds: 5)
    try await control("task-context-result")
    precondition(model.taskContextWindow.detail == research, "A finished task updates in place, with its result")
    captureTaskPanel(window.contentView, "task-detail-subagent-stopped")
    stopped = false

    try await press("task-context-back")
    precondition(model.taskContextWindow.detail == nil, "Back returns to the list")
    try await press("task-context-row-research")
    precondition(model.taskContextWindow.detail == research)

    // Opening the session keeps the panel on its task; the conversation can
    // then show the subagent's own transcript.
    try await press("task-context-open-session")
    for _ in 0..<100 where connection.snapshot?.id != "a" { try await Task.sleep(for: .milliseconds(20)) }
    precondition(model.selectedReference == a && model.taskContextWindow.detail == research)
    try await press("task-context-transcript")
    precondition(connection.subagents.presented == NativeSubagentSubject(sessionID: "a", key: "research"),
                 "The detail page opens the subagent transcript in the conversation that shows it")
    connection.subagents.present(nil)
    model.open(second)
    try await Task.sleep(for: .milliseconds(150))
    precondition(model.taskContextWindow.detail == research, "A locked panel keeps its task while the selection moves")
    model.taskContextWindow.locked = nil
    for _ in 0..<50 where model.taskContextWindow.detail != nil { try await Task.sleep(for: .milliseconds(20)) }
    precondition(model.taskContextWindow.detail == nil, "Following another session leaves the previous session's task")
    print("PASS: task detail drill-in, stop targeting, in-place update, back, open session and transcript, lock and follow rules")

    try await checkCommandDetail(model: model, host: host, directory: NSTemporaryDirectory())
}

/// A Kimi background process in detail: its command, a running output tail that
/// fills the page, and Stop. Rendered from fixed state, without a connection.
@MainActor private func checkCommandDetail(model: WorkbenchModel, host: SSHHost, directory: String) async throws {
    let source = SessionReference(hostID: host.id, terminalID: "kimi-fixture", kind: .kimi)
    let item = WorkspaceSession(reference: source, title: "Perch 支持 Qoder 模型", directory: directory, hostName: host.name,
                                detail: "", online: true, section: .running, canMarkReviewed: false)
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let task = KimiTask(id: "bash-1", kind: "bash", description: "监控 PR #213 的 GitHub Actions", status: "running",
                        startedAt: formatter.string(from: Date().addingTimeInterval(-1108)),
                        command: "gh pr checks 213 --watch --interval 15", runInBackground: true)
    var listed = TaskContextSnapshot(title: item.title, directory: directory, busy: true, messages: [], tasks: [task])
    listed.listedTaskIDs = [task.id]
    let snapshot = listed
    let state = TaskContextState()
    let panel = Task { await state.follow(source, online: true) { snapshot } }
    for _ in 0..<50 where state.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
    let lines = (1...40).map { "build (macos-26, \($0))\tpending\t\($0 * 15)s" }.joined(separator: "\n")
    await state.followOutput(task.id, source: source, running: false) {
        KimiTask(id: task.id, kind: "bash", description: task.description, status: "running",
                 outputPreview: lines, outputBytes: 40_000)
    }
    precondition(state.outputs[task.id]?.truncated == true)
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 340, height: 640), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil); window.contentView = nil }
    window.contentView = NSHostingView(rootView: TaskContextDetailView(
        model: model, item: item, route: TaskContextRoute(source: source, taskID: task.id), snapshot: state.snapshot,
        state: state, online: false, active: false, back: {})
        .font(.system(size: WorkbenchTheme.Typography.body))
        .background(Color(nsColor: .windowBackgroundColor)))
    window.makeKeyAndOrderFront(nil)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        for _ in 0..<100 where taskPanelControl(window, "task-context-output") == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(taskPanelControl(window, "task-context-output") != nil && taskPanelControl(window, "task-context-stop") != nil,
                     "A running listed process shows its output tail and Stop")
        precondition(taskPanelControl(window, "task-context-transcript") == nil &&
                     taskPanelControl(window, "task-context-open-session") == nil, "A background process has no transcript")
        try await Task.sleep(for: .milliseconds(150))
        captureTaskPanel(window.contentView, "task-detail-command-\(appearance == .aqua ? "light" : "dark")")
    }
    panel.cancel(); await panel.value
    print("PASS: task detail of a running Kimi process: command, output tail and Stop")
}

/// Writes a capture when PERCH_TASK_PANEL_CAPTURES names a directory.
@MainActor private func captureTaskPanel(_ view: NSView?, _ name: String) {
    guard let directory = ProcessInfo.processInfo.environment["PERCH_TASK_PANEL_CAPTURES"], let view,
          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
}

/// The window's accessibility elements, depth first. SwiftUI virtual elements
/// expose AX selectors without necessarily declaring the complete protocol.
@MainActor private func taskPanelElements(_ window: NSWindow) -> [(identifier: String?, node: NSObject)] {
    var visited = Set<ObjectIdentifier>()
    var elements: [(identifier: String?, node: NSObject)] = []
    func visit(_ value: Any) {
        guard let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return }
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        elements.append((attribute("accessibilityIdentifier") as? String, node))
        for child in attribute("accessibilityChildren") as? [Any] ?? [] { visit(child) }
    }
    if let root = window.contentView { visit(root) }
    return elements
}

@MainActor private func taskPanelIdentifiers(_ window: NSWindow) -> [String] {
    taskPanelElements(window).compactMap(\.identifier).filter { !$0.isEmpty }
}

/// The window frame of the visible task panel control with this accessibility
/// identifier, or nil while there is none.
@MainActor private func taskPanelControl(_ window: NSWindow, _ identifier: String) -> NSRect? {
    guard let element = taskPanelElements(window).first(where: { $0.identifier == identifier })?.node,
          element.responds(to: NSSelectorFromString("accessibilityFrame")),
          let frame = (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
          !frame.isEmpty else { return nil }
    return window.convertFromScreen(frame)
}
