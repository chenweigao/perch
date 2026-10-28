import AppKit
import SwiftUI
import Observation
import WorkbenchCore

@MainActor @Observable private final class ActivityBarCheckState {
    var phase = "running"
    var width: CGFloat = 720
    var reviews = 0
    var reconnects = 0
    var barFrame = CGRect.zero
}

private struct ActivityBarCheckPhase {
    let activity: ConversationActivity
    let running: Bool
    let online: Bool
    let pending: Int
    let timing: ConversationTiming?
}

/// Production activity bar between a stand-in transcript and composer, so state
/// changes are observed exactly where they could resize the reading viewport.
private struct ActivityBarCheckFixture: View {
    let state: ActivityBarCheckState
    let phases: [String: ActivityBarCheckPhase]
    var body: some View {
        let phase = phases[state.phase]!
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<60, id: \.self) { index in Text(verbatim: "正文第 \(index) 行 reading position stays put.") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ConversationActivityBar(activity: phase.activity, isRunning: phase.running, timing: phase.timing,
                                    online: phase.online,
                                    offlineDetail: phase.online ? nil : "ssh: connect to host fixture.invalid: Network is unreachable",
                                    pendingCount: phase.pending,
                                    onReview: { state.reviews += 1 }, onReconnect: { state.reconnects += 1 })
                .frame(width: state.width)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("activity-check")) } action: { state.barFrame = $0 }
            Color.secondary.opacity(0.15).frame(height: 64)
        }.coordinateSpace(name: "activity-check")
            .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}

@MainActor func checkActivityBar() async throws {
    AppLanguage.applyToSystem(.zhHans)
    func decode(_ rows: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    let prompt: [String: Any] = ["id": "prompt", "role": "user", "created_at": "1",
                                 "content": [["type": "text", "text": "检查状态条在各状态下的布局"]]]
    let todos: [[String: String]] = [["title": "Inspect", "status": "done"], ["title": "Adjust", "status": "in_progress"],
                                     ["title": "Verify", "status": "pending"]]
    let plan: [[String: Any]] = [
        ["id": "plan", "role": "assistant", "created_at": "2", "content": [
            ["type": "tool_use", "tool_call_id": "plan", "tool_name": "TodoList", "input": ["todos": todos]]]],
        ["id": "plan-result", "role": "tool", "created_at": "3", "content": [
            ["type": "tool_result", "tool_call_id": "plan", "is_error": false, "output": "Plan updated"]]]
    ]
    let edit: [[String: Any]] = [
        ["id": "edit", "role": "assistant", "created_at": "4", "content": [
            ["type": "tool_use", "tool_call_id": "edit", "tool_name": "Edit",
             "input": ["path": "/fixture/Bar.swift", "old_string": "a\nb", "new_string": "a\nc\nd"]]]],
        ["id": "edit-result", "role": "tool", "created_at": "5", "content": [
            ["type": "tool_result", "tool_call_id": "edit", "is_error": false, "output": "ok"]]]
    ]
    let command: [String: Any] = ["id": "command", "role": "assistant", "created_at": "6", "content": [
        ["type": "tool_use", "tool_call_id": "command", "tool_name": "Bash",
         "input": ["command": "swift build --configuration release"]]]]
    let failure: [[String: Any]] = [
        ["id": "read", "role": "assistant", "created_at": "6", "content": [
            ["type": "tool_use", "tool_call_id": "read", "tool_name": "Read", "input": ["path": "/fixture/Locked.swift"]]]]
    ]
    let runningMessages = try decode([prompt] + plan + edit + [command])
    let failedMessages = try decode([prompt] + plan + edit + failure)
    let endedMessages = try decode([prompt] + plan + edit)
    var clocks = ConversationTimings()
    clocks.submitted("turn", at: Date().addingTimeInterval(-95))
    clocks.observe(sessionID: "fixture", turnID: "turn", requestID: "turn", running: true, waiting: false)
    let live = clocks.turns["fixture"]
    clocks.observe(sessionID: "fixture", running: false, waiting: false)
    let finished = clocks.turns["fixture"]
    precondition(live?.endedAt == nil && finished?.endedAt != nil)
    let busyIDs = ToolVisibilityProjection.runningIDs(in: runningMessages, busy: true)
    func phase(_ messages: [KimiMessage], running: Bool, online: Bool = true, pending: Int = 0,
               stopping: Bool = false, timing: ConversationTiming?) -> ActivityBarCheckPhase {
        ActivityBarCheckPhase(activity: ConversationActivity(messages: messages, isRunning: running,
                                                             running: running ? busyIDs : [], online: online,
                                                             pendingCount: pending, isStopping: stopping),
                              running: running, online: online, pending: pending, timing: timing)
    }
    let phases: [String: ActivityBarCheckPhase] = [
        "running": phase(runningMessages, running: true, timing: live),
        "pending": phase(runningMessages, running: true, pending: 2, timing: live),
        "offline": phase(runningMessages, running: true, online: false, timing: live),
        "stopping": phase(runningMessages, running: true, stopping: true, timing: live),
        "failed": phase(failedMessages, running: false, timing: finished),
        "ended": phase(endedMessages, running: false, timing: finished)
    ]
    precondition(phases["failed"]!.activity.attentionTools.count == 1, "Fixture failure must be an uncertain result")
    precondition(phases["running"]!.activity.activeTools.count == 1, "Fixture command must be running")

    func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    let state = ActivityBarCheckState()
    let host = NSHostingView(rootView: ActivityBarCheckFixture(state: state, phases: phases))
    let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 760, height: 520),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    func click(_ point: CGPoint) {
        let location = host.convert(NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
    var viewport: CGFloat?
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        for width in [CGFloat(720), 360] {
            state.width = width
            for name in ["running", "pending", "offline", "stopping", "failed", "ended", "running"] {
                state.phase = name
                try await Task.sleep(for: .milliseconds(120))
                host.layoutSubtreeIfNeeded()
                guard let scroll = scrollViews(host).first else { preconditionFailure("Missing transcript stand-in") }
                precondition(abs(state.barFrame.height - ConversationActivityBar.height) < 0.5,
                             "Activity bar is \(state.barFrame.height)pt in \(name) at \(width)pt; every state shares one height")
                if let viewport {
                    precondition(abs(scroll.frame.height - viewport) < 0.5,
                                 "\(name) at \(width)pt resized the reading viewport: \(scroll.frame.height) vs \(viewport)")
                } else { viewport = scroll.frame.height }
            }
        }
    }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        for width in [CGFloat(720), 360] {
            state.width = width
            for name in ["pending", "offline"] {
                let reviews = state.reviews
                let reconnects = state.reconnects
                state.phase = name
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                // Exercise the real trailing button even after secondary facts fold.
                click(CGPoint(x: state.barFrame.maxX - 16, y: state.barFrame.midY))
                try await Task.sleep(for: .milliseconds(150))
                precondition(state.reviews == reviews + (name == "pending" ? 1 : 0)
                             && state.reconnects == reconnects + (name == "offline" ? 1 : 0),
                             "\(name) action failed at \(width)pt in \(appearance)")
            }
        }
    }
    print("PASS: activity bar keeps one height and the reading viewport across running/pending/offline/stopping/failed/ended, wide/narrow, light/dark; pending review and reconnect actions respond")
}
