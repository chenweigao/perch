import AppKit
import ApplicationServices
import QuartzCore
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

    // Inline turn status: compact disclosure + busy indicator, pure-text plan/changes
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
    let context = ConversationActionContext(hostID: UUID(), kind: .kimi, sessionID: "inline-check",
                                            recapKey: "inline-check:1", recapMessageID: "final-answer")
    let activityEntry = ConversationTimelineEntry.make(runningMessages, isRunning: true).last { $0.presentation == .activity }!
    let projectedTools = ToolVisibilityProjection().update(runningMessages, sessionID: "inline-running", running: busyIDs, online: true).tools
    let userMentionMsg = try decode([[
        "id": "u-mention", "role": "user", "created_at": "1",
        "content": [["type": "text", "text": "@\"/workspace/Sources/AgentWorkbench/ToolActivityView.swift\" @\"/workspace/Sources/WorkbenchCore/ToolPresentation.swift\" 对齐正文与工具卡的视觉细节"]]
    ]])[0]
    let exploreRaw: [[String: Any]] = [
        ["id": "e1", "role": "assistant", "created_at": "2", "content": [
            ["type": "tool_use", "tool_call_id": "r1", "tool_name": "Read",
             "input": ["path": "/workspace/Sources/AgentWorkbench/ToolActivityView.swift", "line_offset": 1, "n_lines": 120]],
            ["type": "tool_use", "tool_call_id": "r2", "tool_name": "Read",
             "input": ["path": "/workspace/Sources/AgentWorkbench/ToolActivityView.swift", "line_offset": 240, "n_lines": 95]],
            ["type": "tool_use", "tool_call_id": "g1", "tool_name": "Grep",
             "input": ["pattern": "ThoughtDisclosure"]]
        ]],
        ["id": "e1-res", "role": "tool", "created_at": "3", "content": [
            ["type": "tool_result", "tool_call_id": "r1", "is_error": false, "output": "ok"],
            ["type": "tool_result", "tool_call_id": "r2", "is_error": false, "output": "ok"],
            ["type": "tool_result", "tool_call_id": "g1", "is_error": false, "output": "ok"]
        ]]
    ]
    let exploreMessages = try decode(exploreRaw)
    let exploreEntry = ConversationTimelineEntry.make(exploreMessages, isRunning: false).first!
    let exploreTools = ToolVisibilityProjection().update(exploreMessages, sessionID: "explore-check", running: [], online: true).tools
    let editTool = VisibleTool(
        id: "edit-showcase", name: "Edit",
        input: .object([
            "path": .string("/workspace/Sources/AgentWorkbench/ToolActivityView.swift"),
            "old_string": .string("let label = L(\"读取与搜索 · \\(items.count) 次调用\")\nText(verbatim: label).lineLimit(1)"),
            "new_string": .string("let label = ToolPresentation.explorationBucketSummary(items)\nText(verbatim: label).fixedSize()")
        ]),
        output: .string("Replaced 1 occurrence"),
        status: .succeeded)
    let slowBashTool = VisibleTool(
        id: "slow-bash", name: "Bash",
        input: .object(["command": .string("/bin/zsh -lc \"cd /workspace && swift test --filter WorkbenchChecks\"")]),
        output: .string("Wall time: 14.2 seconds\nAll tests passed."),
        status: .succeeded)
    let longExternal = ActivityNarrative(
        turnID: "turn", stageID: "stage:external", phase: .exploring,
        subject: "性能分析",
        headline: "已确认瓶颈为全量候选冷仿真导致整页阻塞，非 trace 加载问题，建议前端渐进渲染及后端优化搜索模式。",
        source: .external, lifecycle: .final)
    let foldRowItem = ConversationPresentationModel.Row(
        entry: activityEntry, tools: projectedTools,
        activity: ActivityNarrativeRow(narrative: longExternal, isAnchor: true, stageClosed: true))
    ConversationReadingMemory.shared.expansions["upgrade-showcase:edit:expanded"] = true
    ConversationReadingMemory.shared.expansions["upgrade-showcase:collapsed-thought:thought"] = false
    let collapsedThought = "先检查旧布局的截断原因。\n确认 `!busy` 守卫已生效，继续补充边界校验与内联 Diff 视图。"
    let streamingThoughtMsg = try decode([[
        "id": "t-live", "role": "assistant", "created_at": "4",
        "content": [["type": "thinking", "thinking": """
        **核对工具卡内联 Diff 与代码块折叠**
        <!-- -->
        - 将 `Edit` 工具卡的原始 JSON 替换为红绿双色 `ToolInlineDiffCard`，保留文件跳转与行数统计。
        ```swift
        struct ToolInlineDiffCard: View {
            let diff: ToolInlineDiff
            var body: some View { EmptyView() }
        }
        ```
        继续验证 10 秒慢命令耗时阈值与收起态单行摘要。
        """]]
    ]])
    let inlineHost = NSHostingView(rootView: VStack(alignment: .leading, spacing: 14) {
        KimiMessageView(message: userMentionMsg, tools: [:], api: nil, sessionId: "inline-running")
        KimiActivityView(entry: exploreEntry, tools: exploreTools, api: nil, sessionId: "explore-check",
                         isLive: true, planProgress: progressLive, reduceMotionOverride: false)
            .environment(\.conversationActionContext, context)
        ComposerActionButton(isRunning: true, isStopping: false, canSend: false, canStop: true,
                             onSend: {}, onStop: {})
        KimiToolCard(tool: exploreTools["r1"]!, mergedReadRange: ":1–120, 240–334")
        KimiToolCard(tool: slowBashTool)
        ThoughtDisclosure(text: collapsedThought)
            .environment(\.conversationMemoryKey, "upgrade-showcase:collapsed-thought")
        ThoughtOutput(messages: streamingThoughtMsg, finished: false)
            .environment(\.conversationMemoryKey, "upgrade-showcase:live-thought")
        KimiToolCard(tool: editTool)
            .environment(\.conversationMemoryKey, "upgrade-showcase:edit")
        Divider().opacity(0.35)
        ProcessFoldRow(rows: [foldRowItem], api: nil, sessionId: "inline-running")
            .environment(\.conversationActionContext, context)
    }.padding(20).environment(\.locale, Locale(identifier: "zh-Hans")).frame(width: 680, height: 670)
        .background(WorkbenchTheme.contentBackground))
    window.contentView = inlineHost
    window.setContentSize(NSSize(width: 680, height: 670))
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        try await Task.sleep(for: .milliseconds(350))
        inlineHost.layoutSubtreeIfNeeded()
        if let bitmap = inlineHost.bitmapImageRepForCachingDisplay(in: inlineHost.bounds) {
            inlineHost.cacheDisplay(in: inlineHost.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/private/tmp/perch-design-upgrade-\(suffix).png"))
        }
    }
    window.appearance = NSAppearance(named: .aqua)
    try await Task.sleep(for: .milliseconds(200))
    inlineHost.layoutSubtreeIfNeeded()
    func busyIndicators(_ view: NSView) -> [NSView] {
        if String(describing: type(of: view)) == "PerchBusyView" { return [view] }
        return view.subviews.flatMap(busyIndicators)
    }
    precondition(glints(inlineHost).isEmpty, "The compact process header stays still while its status indicates progress")
    precondition(!busyIndicators(inlineHost).contains { $0.bounds.width == 13 && $0.bounds.height == 13 },
                 "A completed stage must not retain a generic waiting indicator")
    precondition(!busyIndicators(inlineHost).contains { $0.bounds.size == CGSize(width: 28, height: 28) },
                 "PI's composer stop control has no activity arc")
    // The toolbar interaction suite measures the action's native frame through
    // running, waiting, offline, stopping and completion. Its AX wrapper here
    // is not the native 28pt layout box.

    let sqlNoteText = """
    规划已完成，开始派发：新计划有约 55.05 万项待算，已完成 189 项。旧结果已通过库存核对复用。

    按这个缺口，普通计算至少要达到约 2.3 万项/小时才能在 24 小时内完成；跨机阶段还需要额外时间。我现在测执行窗口，并核对刚出现的 10 个失败。
    """
    let sqlStageMessages = try decode([
        ["id": "sql-note", "role": "assistant", "created_at": "1",
         "content": [["type": "text", "text": sqlNoteText]]],
        ["id": "sql-calls", "role": "assistant", "created_at": "2", "content": (1...8).map { i -> [String: Any] in
            if i == 8 {
                return ["type": "tool_use", "tool_call_id": "sql-\(i)", "tool_name": "Edit",
                        "input": ["path": "/workspace/sql/query.sql", "old_string": "SELECT *", "new_string": "SELECT id,\n  status,\n  created_at,\n  updated_at,\n  batch_key,\n  score,\n  elapsed_ms"]]
            }
            return ["type": "tool_use", "tool_call_id": "sql-\(i)", "tool_name": "Read",
                    "input": ["path": "/workspace/sql/step_\(i).sql"]]
        }],
        ["id": "sql-results", "role": "tool", "created_at": "3", "content": (1...8).map { i in
            ["type": "tool_result", "tool_call_id": "sql-\(i)", "is_error": false, "output": "ok"]
        }]
    ])
    let sqlEntries = ConversationTimelineEntry.make(sqlStageMessages, isRunning: true)
    let sqlTools = ToolVisibilityProjection().update(sqlStageMessages, sessionID: "sql-live", running: [], online: true).tools
    let sqlProjection = ActivityNarrativeProjection.make(entries: sqlEntries, tools: sqlTools, isRunning: true)
    precondition(sqlProjection.stages.allSatisfy { $0.narrative.phase != .blocked },
                 "Progress note mentioning failures must not mark its stage blocked")
    let sqlNoteNarrative = sqlProjection.stages.first!.narrative
    let sqlEditNarrative = ActivityNarrative(
        turnID: "turn", stageID: "stage:sql", phase: .editing,
        subject: "SQL 性能优化",
        headline: "用户要求将任务耗时压缩至 1 天，正在调整 SQL 查询以优化性能。",
        source: .external, lifecycle: .streaming)
    let sqlActivityEntry = sqlEntries.last { $0.presentation == .activity }!
    let streamingBenchTool = VisibleTool(
        id: "bench-run", name: "Bash",
        input: .object(["command": .string("python3 scripts/bench_window.py --shards 8")]),
        progress: .string("[001/189] warming connection pool...\n[140/189] batch_key=shard_04 throughput=24,120/h\n[189/189] verifying 10 retry candidates..."),
        status: .running)
    let localNarrative = ActivityNarrative(
        turnID: "turn", stageID: "stage:local", phase: .validating,
        subject: "python3", headline: "运行测试", source: .local, lifecycle: .streaming)
    let todoProgress = TurnStatus.Progress(done: 2, total: 4, currentTitle: "压测 2.3 万项/小时执行窗口与跨机吞吐")
    let sqlFoldItem = ConversationPresentationModel.Row(
        entry: sqlActivityEntry, tools: sqlTools,
        activity: ActivityNarrativeRow(narrative: sqlEditNarrative, isAnchor: true, stageClosed: true))
    let liveTailHost = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
        ActivityNarrativeHistoryView(narrative: sqlNoteNarrative, sourceText: sqlNoteText)
        KimiActivityView(entry: sqlActivityEntry, tools: sqlTools, api: nil, sessionId: "sql-live",
                         narrative: sqlEditNarrative, isLive: true, reduceMotionOverride: false)
            .environment(\.conversationActionContext, context)
        Divider().opacity(0.35)
        KimiActivityView(entry: activityEntry, tools: ["command": streamingBenchTool], api: nil, sessionId: "sql-bench",
                         narrative: localNarrative, isLive: true, planProgress: todoProgress, reduceMotionOverride: false)
            .environment(\.conversationActionContext, context)
        Divider().opacity(0.35)
        ProcessFoldRow(rows: [sqlFoldItem], api: nil, sessionId: "sql-live", completedDuration: 83)
            .environment(\.conversationActionContext, context)
    }.padding(24).environment(\.locale, Locale(identifier: "zh-Hans")).frame(width: 680, height: 440)
        .background(WorkbenchTheme.contentBackground))
    window.contentView = liveTailHost
    window.setContentSize(NSSize(width: 680, height: 440))
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        try await Task.sleep(for: .milliseconds(350))
        liveTailHost.layoutSubtreeIfNeeded()
        if let bitmap = liveTailHost.bitmapImageRepForCachingDisplay(in: liveTailHost.bounds) {
            liveTailHost.cacheDisplay(in: liveTailHost.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/private/tmp/perch-live-tail-\(suffix).png"))
        }
    }
    // Read the painted tool card itself, so another row's state dot cannot
    // satisfy the assertion and native AX coordinates cannot shift the crop.
    func toolStateView(_ tool: VisibleTool, scope: String) -> some View {
        KimiToolCard(tool: tool).padding(16)
            .frame(width: 400, height: 120, alignment: .topLeading)
            .background(WorkbenchTheme.contentBackground)
            .environment(\.conversationMemoryKey, scope)
    }
    func coloredPixels(_ bitmap: NSBitmapImageRep, green: Bool) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let matches = green ? g > r + 0.12 && g > b + 0.08
                    : r > b + 0.12 && g > b + 0.08 && r >= g - 0.05
                if matches { count += 1 }
            }
        }
        return count
    }
    let completedBenchTool = VisibleTool(id: streamingBenchTool.id, name: streamingBenchTool.name,
        input: streamingBenchTool.input, output: .string("Benchmark complete."), status: .succeeded)
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let scope = "activity-state-dot:" + suffix
        let toolHost = NSHostingView(rootView: toolStateView(streamingBenchTool, scope: scope))
        window.appearance = NSAppearance(named: appearance)
        window.contentView = toolHost; window.setContentSize(NSSize(width: 400, height: 120))
        for (state, tool) in [("running", streamingBenchTool), ("completed", completedBenchTool)] {
            toolHost.rootView = toolStateView(tool, scope: scope)
            try await Task.sleep(for: .milliseconds(350))
            toolHost.layoutSubtreeIfNeeded()
            let bitmap = toolHost.bitmapImageRepForCachingDisplay(in: toolHost.bounds)!
            toolHost.cacheDisplay(in: toolHost.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: "/private/tmp/perch-tool-state-\(suffix)-\(state).png"))
            let yellow = coloredPixels(bitmap, green: false), green = coloredPixels(bitmap, green: true)
            precondition(state == "running" ? yellow >= 8 : green >= 8 && yellow == 0,
                         "The same tool paints yellow while executing and green after completion in \(suffix): \(yellow) yellow, \(green) green")
        }
    }
    print("PASS: activity bar state transitions, pending/reconnect actions, composer turn feedback, factual tool activity and Recap target")
    try await checkLiveStatusFooter()
}

@MainActor private func checkLiveStatusFooter() async throws {
    NSApp.activate(ignoringOtherApps: true)
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 700, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    var measuredHeight: CGFloat = 0
    func root(_ phase: ConversationRunPhase?, reduced: Bool = false, locale: String = "zh-Hans") -> AnyView {
        AnyView(ConversationLiveStatus(phase: phase, reduceMotionOverride: reduced).equatable()
            .environment(\.locale, Locale(identifier: locale))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WorkbenchTheme.contentBackground))
    }
    let host = NSHostingView(rootView: root(.thinking))
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
    }
    func mark(_ view: NSView) -> ConversationLiveMarkView? {
        (view as? ConversationLiveMarkView) ?? view.subviews.lazy.compactMap(mark).first
    }
    func opacities(_ view: ConversationLiveMarkView) -> [Float] {
        (view.layer?.sublayers ?? []).map { $0.presentation()?.opacity ?? $0.opacity }
    }
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"] ?? "/private/tmp/perch-live-status")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (suffix, width, appearance) in [("light", 700.0, NSAppearance.Name.aqua), ("narrow-dark", 340.0, .darkAqua)] {
        window.appearance = NSAppearance(named: appearance); window.setContentSize(NSSize(width: width, height: 180))
        for (phase, label) in [(ConversationRunPhase.thinking, "思考中"), (.executing, "执行中"), (.running, "运行中"), (.waitingForConfirmation, "等待你确认"), (.waitingForAnswer, "等待你回答"), (.stopping, "正在停止")] {
            host.rootView = root(phase)
            try await settle()
            precondition(taskPanelLabel(window, "conversation-live-status")?.contains(label) == true,
                         "The live footer speaks only its current phase: \(label)")
            precondition(abs(measuredHeight - ConversationLiveStatus.height) < 0.5,
                         "Every live phase shares one footer height")
            let icon = mark(host)!
            if !phase.animates {
                precondition((icon.layer?.sublayers ?? []).allSatisfy { $0.animationKeys()?.isEmpty != false },
                             "Waiting and stopping must hold still")
            }
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("live-status-\(suffix)-\(label).png"))
        }
    }
    host.rootView = root(.thinking); try await settle()
    let icon = mark(host)!
    let before = opacities(icon)
    try await Task.sleep(for: .milliseconds(420))
    let after = opacities(icon)
    precondition(zip(before, after).contains { abs($0 - $1) > 0.1 }, "The thinking mark visibly breathes without changing status text")
    host.rootView = root(.thinking, reduced: true); try await settle()
    precondition((mark(host)!.layer?.sublayers ?? []).allSatisfy { $0.animationKeys()?.isEmpty != false }, "Reduce Motion stops the same mounted mark")
    host.rootView = root(.thinking, locale: "en"); try await settle()
    precondition(taskPanelLabel(window, "conversation-live-status")?.contains("Thinking") == true, "An unchanged phase follows the app language")
    window.orderOut(nil); try await settle()
    precondition((mark(host)!.layer?.sublayers ?? []).allSatisfy { $0.animationKeys()?.isEmpty != false }, "An invisible window pauses the mark")
    window.makeKeyAndOrderFront(nil)
    host.rootView = root(nil); try await settle()
    precondition(taskPanelControl(window, "conversation-live-status") == nil && mark(host) == nil, "Completion removes the live footer and its animation")
    print("PASS: live footer phases, stable geometry, visible native motion, waiting/reduced/hidden pause, locale refresh and completed teardown")
}
