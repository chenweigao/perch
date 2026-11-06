import AppKit
import ApplicationServices
import SwiftUI
import WorkbenchCore

private struct TaskPlanFixture: View {
    let controller: TaskContextWindowController
    let source: SessionReference
    let todos: [ConversationTodo]
    var scheme: ColorScheme = .light
    var body: some View {
        TaskPlanSection(controller: controller, source: source, todos: todos)
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
    }
}

@MainActor func checkTaskPlanDisclosure() async throws {
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    func todos(_ complete: Bool) throws -> [ConversationTodo] {
        let rows: [[String: Any]] = [
            ["id": "plan", "role": "assistant", "created_at": "1", "content": [
                ["type": "tool_use", "tool_call_id": "plan", "tool_name": "TodoList", "input": ["todos": [
                    ["title": "定位首次测量遗漏", "status": "done"],
                    ["title": "同步容器初始高度", "status": "done"],
                    ["title": "验证快速切换会话与返回后，长标题和面板高度是否正确", "status": complete ? "done" : "in_progress"]]]]]],
            ["id": "result", "role": "tool", "created_at": "2", "content": [
                ["type": "tool_result", "tool_call_id": "plan", "is_error": false, "output": "Updated"]]]
        ]
        return ConversationTodo.current(in: try KimiWire.decoder().decode([KimiMessage].self,
            from: JSONSerialization.data(withJSONObject: rows)))
    }
    let unfinished = try todos(false), finished = try todos(true)
    let controller = TaskContextWindowController()
    let a = SessionReference(hostID: UUID(), terminalID: "same-session", kind: .kimi)
    let b = SessionReference(hostID: UUID(), terminalID: "same-session", kind: .kimi)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 312, height: 420),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingController(rootView: TaskPlanFixture(controller: controller, source: a, todos: unfinished))
    window.contentViewController = hosting
    window.makeKeyAndOrderFront(nil)
    defer { window.close(); window.contentViewController = nil }
    func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }
    func visibleStep() -> Bool { taskPanelControl(window, "task-context-plan-step-2") != nil }
    func show(_ source: SessionReference, _ values: [ConversationTodo]) async throws {
        hosting.rootView = TaskPlanFixture(controller: controller, source: source, todos: values)
        try await settle()
    }
    func toggle() async throws {
        guard let frame = taskPanelControl(window, "task-context-plan-toggle") else {
            preconditionFailure("The plan disclosure must be accessible")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        try await settle()
    }
    try await settle()
    precondition(visibleStep() && controller.planExpansion[a] == nil, "An unfinished plan starts open without a manual preference")
    try await show(a, finished)
    precondition(!visibleStep(), "An untouched completed plan folds automatically")
    try await show(a, unfinished)
    precondition(visibleStep(), "An untouched new unfinished plan opens")
    try await toggle()
    precondition(!visibleStep() && controller.planExpansion[a] == false)
    try await show(a, finished)
    try await show(a, unfinished)
    precondition(!visibleStep(), "Refresh and completion preserve a manual collapse")
    try await show(b, unfinished)
    precondition(visibleStep(), "Another host with the same session id has its own choice")
    try await show(a, unfinished)
    precondition(!visibleStep(), "Returning restores the first session's choice")
    try await toggle()
    try await show(a, finished)
    precondition(visibleStep() && controller.planExpansion[a] == true, "Completion preserves a manual expansion")
    window.contentViewController = nil
    let remounted = NSHostingController(rootView: TaskPlanFixture(controller: controller, source: a, todos: finished))
    window.contentViewController = remounted
    try await settle()
    precondition(visibleStep(), "Reopening or docking does not discard a manual choice")
    for width: CGFloat in [280, 312, 400] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            remounted.rootView = TaskPlanFixture(controller: controller, source: a, todos: unfinished, scheme: appearance == .aqua ? .light : .dark)
            window.setContentSize(NSSize(width: width, height: 420))
            window.appearance = NSAppearance(named: appearance)
            try await settle()
            precondition(visibleStep())
            if let folder = ProcessInfo.processInfo.environment["PERCH_TASK_PANEL_CAPTURES"],
               let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: folder).appendingPathComponent("plan-\(Int(width))-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
    print("PASS: native plan default disclosure, manual click, refresh/completion, host isolation, session return and remount")
}
