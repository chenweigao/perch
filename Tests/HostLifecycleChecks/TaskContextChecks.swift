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
                ["type": "text", "text": "[方案](Report.md)"],
                ["type": "tool_use", "tool_call_id": "write", "tool_name": "Write", "input": ["file_path": "Report.md"]],
                ["type": "tool_use", "tool_call_id": "failed", "tool_name": "Read", "input": ["path": "missing.txt"]]
            ]],
            ["id": "r", "role": "tool", "created_at": "", "content": [
                ["type": "tool_result", "tool_call_id": "write", "is_error": false, "output": "Saved"],
                ["type": "tool_result", "tool_call_id": "failed", "is_error": true, "output": "Not found"]
            ]]
        ]
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
    func click(_ x: CGFloat, _ distanceFromTop: CGFloat) {
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
    print("PASS: task context native windows 340/420/620 light/dark, real pin and draft controls, source isolation, stop targeting, cancellation, file route and close/reopen")
}
