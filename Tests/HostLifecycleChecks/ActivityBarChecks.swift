import AppKit
import SwiftUI
import Observation
import WorkbenchCore

@MainActor @Observable private final class ActivityBarCheckState {
    var phase = "running"
    var width: CGFloat = 720
    var reviews = 0
    var reconnects = 0
    var details = 0
    var changes = 0
    /// nil follows the runner's Reduce Motion; the sweep checks pin it.
    var reduceMotion: Bool?
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
            ConversationActivityBar(activity: phase.activity, turn: SessionTurn(running: phase.running, pending: phase.pending > 0),
                                    timing: phase.timing,
                                    online: phase.online,
                                    offlineDetail: phase.online ? nil : "ssh: connect to host fixture.invalid: Network is unreachable",
                                    pendingCount: phase.pending,
                                    onReview: { state.reviews += 1 }, onReconnect: { state.reconnects += 1 },
                                    onDetails: { state.details += 1 }, onChanges: { state.changes += 1 },
                                    reduceMotionOverride: state.reduceMotion)
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
    let progressNote: [String: Any] = ["id": "note", "role": "assistant", "created_at": "7",
                                       "content": [["type": "text", "text": "Build is still compiling."]]]
    let moreMessages = try decode([prompt] + plan + edit + [command, progressNote])
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
        "running-more": phase(moreMessages, running: true, timing: live),
        "pending": phase(runningMessages, running: true, pending: 2, timing: live),
        "offline": phase(runningMessages, running: true, online: false, timing: live),
        "stopping": phase(runningMessages, running: true, stopping: true, timing: live),
        "failed": phase(failedMessages, running: false, timing: finished),
        "ended": phase(endedMessages, running: false, timing: finished),
        "idle": phase(try decode([prompt] + edit), running: false, timing: nil)
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
    // The line itself is a button behind its text: a click on the (shimmering)
    // title opens the task panel, or the pending card while waiting.
    window.appearance = NSAppearance(named: .aqua)
    state.width = 720
    for (name, expectsDetails) in [("running", true), ("ended", true), ("pending", false)] {
        let details = state.details, reviews = state.reviews
        state.phase = name
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        click(CGPoint(x: state.barFrame.minX + 60, y: state.barFrame.midY))
        try await Task.sleep(for: .milliseconds(150))
        precondition(state.details == details + (expectsDetails ? 1 : 0) && state.reviews == reviews + (expectsDetails ? 0 : 1),
                     "A click on the \(name) line must reach the line: details \(state.details - details), reviews \(state.reviews - reviews)")
    }
    precondition(state.changes == 0, "Only the +a −d button opens the changes page")
    // The title sweeps once per progress event and holds still without one.
    func glints(_ view: NSView) -> [ShimmerGlintView] {
        (view as? ShimmerGlintView).map { [$0] } ?? view.subviews.flatMap(glints)
    }
    // Pinned so the result does not depend on the runner's Reduce Motion setting.
    state.reduceMotion = true
    state.phase = "running"
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    precondition(glints(host).isEmpty, "Reduce Motion keeps the running title still")
    state.reduceMotion = false
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    guard let glint = glints(host).first else {
        preconditionFailure("A running title must carry its shimmer (system Reduce Motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))")
    }
    let mounted = glint.sweeps
    try await Task.sleep(for: .milliseconds(500))
    precondition(glint.sweeps == mounted, "No progress, no sweep: \(glint.sweeps - mounted)")
    state.phase = "running-more"
    try await Task.sleep(for: .milliseconds(200))
    precondition(glints(host).first === glint && glint.sweeps == mounted + 1, "New output sweeps the same title once: \(glint.sweeps - mounted)")
    try await Task.sleep(for: .milliseconds(500))
    precondition(glint.sweeps == mounted + 1, "One event, one sweep")
    state.reduceMotion = nil
    // A session this client never watched run has nothing to say and takes no space.
    state.phase = "idle"
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    precondition(state.barFrame.height < 0.5, "An idle status line must take no space: \(state.barFrame.height)pt")

    // Inline turn status: open stage narrative + shimmer, pure-text plan/changes
    // links, Recap target resolution, and ReturnToLatest waiting capsule.
    let progressLive = TurnStatus.Progress.live(in: runningMessages, isRunning: true)
    precondition(progressLive == TurnStatus.Progress(done: 1, total: 3), "Running turn resolves active plan progress: \(String(describing: progressLive))")
    precondition(TurnStatus.Progress.live(in: runningMessages, isRunning: false) == nil, "Settled turn hides live plan progress")
    let answerMessage = try decode([["id": "final-answer", "role": "assistant", "created_at": "8",
                                     "content": [["type": "text", "text": "已完成重构。"]]]])
    let settledMessages = endedMessages + answerMessage
    precondition(ConversationActionContext.recapTargetID(in: settledMessages, recapKey: "fixture:1") == "final-answer",
                 "Recap targets the latest settled assistant text message")
    precondition(ConversationActionContext.recapTargetID(in: settledMessages, recapKey: nil) == nil,
                 "Running turns expose no Recap target")

    var receivedActions: [ConversationMessageAction] = []
    let token = NotificationCenter.default.addObserver(forName: .conversationAction, object: nil, queue: .main) { note in
        if let payload = note.object as? ConversationActionPayload { receivedActions.append(payload.action) }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    var returned = 0
    let context = ConversationActionContext(hostID: UUID(), kind: .kimi, sessionID: "inline-check",
                                            recapKey: "inline-check:1", recapMessageID: "final-answer")
    let activityEntry = ConversationTimelineEntry.make(runningMessages, isRunning: true).last { $0.presentation == .activity }!
    let projectedTools = ToolVisibilityProjection().update(runningMessages, sessionID: "inline-running", running: busyIDs, online: true).tools
    let longExternal = ActivityNarrative(
        turnID: "turn", stageID: "stage:external", phase: .exploring,
        subject: "性能分析",
        headline: "已确认瓶颈为全量候选冷仿真导致整页阻塞，非 trace 加载问题，建议前端渐进渲染及后端优化搜索模式。",
        source: .external, lifecycle: .final)
    let foldRowItem = ConversationPresentationModel.Row(
        entry: activityEntry, tools: projectedTools,
        activity: ActivityNarrativeRow(narrative: longExternal, isAnchor: true, stageClosed: true))
    let inlineHost = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
        KimiActivityView(entry: activityEntry, tools: projectedTools, api: nil, sessionId: "inline-running",
                         narrative: longExternal, isLive: true, planProgress: progressLive, reduceMotionOverride: false)
            .environment(\.conversationActionContext, context)
        ProcessFoldRow(rows: [foldRowItem], api: nil, sessionId: "inline-running")
            .environment(\.conversationActionContext, context)
        ReturnToLatestButton(isVisible: true,
                             waitingRequest: TurnRequest(kind: .approval, text: "rm -rf .build/release"),
                             pendingCount: 1,
                             action: { returned += 1 })
    }.padding(20).environment(\.locale, Locale(identifier: "zh-Hans")).frame(width: 680, height: 260)
        .background(Color(nsColor: .windowBackgroundColor)))
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = inlineHost
    window.setContentSize(NSSize(width: 680, height: 260))
    try await Task.sleep(for: .milliseconds(350))
    inlineHost.layoutSubtreeIfNeeded()
    if let bitmap = inlineHost.bitmapImageRepForCachingDisplay(in: inlineHost.bounds) {
        inlineHost.cacheDisplay(in: inlineHost.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/perch-fold-header.png"))
    }
    precondition(!glints(inlineHost).isEmpty, "Live inline KimiActivityView header carries ShimmerGlint")
    print("PASS: the running title sweeps once per progress event; status line clicks reach the line through its title; idle status line takes no space; activity bar keeps one height and the reading viewport across running/pending/offline/stopping/failed/ended, wide/narrow, light/dark; pending review and reconnect actions respond; inline stage header and Recap target verified")
}
