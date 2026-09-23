import AppKit
import SwiftUI
import WorkbenchCore

@main struct ActivityPreviewApp: App {
    @NSApplicationDelegateAdaptor(ActivityDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Task activity preview") { ActivityPreview().preferredColorScheme(.light) }
            .defaultSize(width: 900, height: 650)
    }
}
private struct ActivityPreview: View {
    @State private var phase = "Tools"
    @State private var narrativeMode = "Commentary"
    @State private var narrow = false
    @State private var includeHistory = true
    @State private var includePlan = true
    @State private var includeDescription = true
    @State private var reviewCount = 0
    @State private var reconnectCount = 0
    @State private var retryCount = 0
    @State private var turn = 1
    @State private var clocks = ConversationTimings()
    @State private var observedOnly = false
    @State private var includeTasks = true
    @State private var failTaskList = false
    @State private var readOutputs: Set<String> = []
    @State private var stops = 0
    @State private var listRefreshes = 0
    @State private var transcriptOpens = 0
    private var busy: Bool { phase != "Done" && phase != "Failed" }
    private var messages: [KimiMessage] {
        var rows: [[String: Any]] = [
            ["id": "u\(turn)", "role": "user", "created_at": "", "content": [["type": "text", "text": "Inspect a fixture project"]]]
        ]
        if includeHistory {
            for index in 1...20 {
                rows.append(["id": "history-call-\(index)", "role": "assistant", "created_at": "", "content": [
                    ["type": "tool_use", "tool_call_id": "history-\(index)", "tool_name": "Bash", "input": ["command": "echo fixture-\(index)"]]
                ]])
                rows.append(["id": "history-result-\(index)", "role": "tool", "created_at": "", "content": [
                    ["type": "tool_result", "tool_call_id": "history-\(index)", "output": "Fixture result"]
                ]])
            }
        }
        if phase != "Thinking" {
            let todos: [[String: String]] = [
                ["title": "Inspect the existing layout", "status": "done"],
                ["title": "Check the activity presentation", "status": phase == "Done" ? "done" : "in_progress"],
                ["title": "Verify keyboard and narrow layouts", "status": phase == "Done" ? "done" : "pending"]]
            if narrativeMode == "Commentary" {
                rows.append(["id": "progress", "role": "assistant", "created_at": "", "content": [
                    ["type": "text", "text": "解冲突：保留我的结构，吸收 main 的新文案："]
                ]])
            }
            rows += [
                ["id": "plan", "role": "assistant", "created_at": "", "content": [["type": "tool_use", "tool_call_id": "plan", "tool_name": "TodoList", "input": ["todos": todos]]]],
                ["id": "plan-result", "role": "tool", "created_at": "", "content": [["type": "tool_result", "tool_call_id": "plan", "is_error": false, "output": "Plan updated"]]],
                ["id": "tool", "role": "assistant", "created_at": "", "content": [["type": "tool_use", "tool_call_id": "read", "tool_name": "Read", "input": includeDescription ? ["path": "/fixture/Sample.swift", "description": "Inspect imports in Sample.swift"] : ["path": "/fixture/Sample.swift"]]]]
            ]
            if ["Done", "Failed", "Responding"].contains(phase) {
                rows.append(["id": "result", "role": "tool", "created_at": "", "content": [["type": "tool_result", "tool_call_id": "read", "is_error": phase == "Failed", "output": phase == "Failed" ? "Permission denied (fixture)" : "Read complete"]]])
            }
            if !busy {
                rows.append(["id": "answer", "role": "assistant", "created_at": "", "content": [
                    ["type": "text", "text": "Fixture response complete."]
                ]])
            }
        }
        if !includePlan { rows.removeAll { ["plan", "plan-result"].contains($0["id"] as? String ?? "") } }
        return try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    private let live = try! KimiWire.decoder().decode([KimiLiveTool].self, from: Data(#"[{"tool_call_id":"read","name":"Read","args":{"path":"/fixture/Sample.swift"},"last_progress":"Read 20 lines; checking imports"}]"#.utf8))
    private var narrative: ActivityNarrative? {
        let source: ActivityNarrativeSource
        let headline: String
        let detail: String?
        switch narrativeMode {
        case "Commentary":
            source = .commentary
            headline = "解冲突"
            detail = "保留我的结构，吸收 main 的新文案"
        case "Provider":
            source = .provider
            headline = "Inspecting the unified activity narrative"
            detail = "Codex reasoning summary metadata is shown without exposing private reasoning."
        case "External":
            source = .external
            headline = "Refining the activity narrative presentation"
            detail = nil
        case "External failure":
            source = .local
            headline = "Validating the activity narrative locally"
            detail = nil
        case "Local":
            source = .local
            headline = "Reviewing Sample.swift"
            detail = nil
        default:
            return nil
        }
        let narrativePhase: ActivityNarrativePhase = phase == "Failed" ? .blocked
            : narrativeMode == "Commentary" ? .integrating
            : phase == "Done" ? .validating : .exploring
        return ActivityNarrative(turnID: "preview-\(turn)", stageID: "preview-\(turn)-stage",
            phase: narrativePhase, subject: headline, headline: headline, detail: detail,
            source: source, evidenceIDs: ["read"], lifecycle: busy ? .streaming : .final)
    }
    /// Roster and task-list fixtures in the server's own wire shapes.
    private var board: KimiTaskBoard {
        guard includeTasks else { return KimiTaskBoard() }
        func stamp(_ secondsAgo: TimeInterval) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
        }
        let roster = try! KimiWire.decoder().decode([KimiTask].self, from: Data("""
        [{"id":"agent_01","session_id":"preview","kind":"subagent","description":"Inspect the existing layout","status":"running","created_at":"\(stamp(95))","started_at":"\(stamp(90))","run_in_background":false,"subagent_phase":"working","subagent_type":"coder","parent_tool_call_id":"agent-call","model":"kimi-k2","thinking_effort":"high","swarm_index":0},
         {"id":"agent_02","session_id":"preview","kind":"subagent","description":"Check the activity presentation","status":"running","created_at":"\(stamp(40))","run_in_background":false,"subagent_phase":"queued","subagent_type":"explore","parent_tool_call_id":"agent-call"},
         {"id":"agent_03","session_id":"preview","kind":"subagent","description":"Verify keyboard and narrow layouts","status":"failed","created_at":"\(stamp(200))","started_at":"\(stamp(198))","completed_at":"\(stamp(180))","run_in_background":false,"subagent_phase":"failed","subagent_type":"coder","parent_tool_call_id":"agent-call"},
         {"id":"agent_04","session_id":"preview","kind":"subagent","description":"Wait for a permission decision","status":"running","created_at":"\(stamp(60))","started_at":"\(stamp(58))","run_in_background":false,"subagent_phase":"suspended","suspended_reason":"approval","subagent_type":"coder","parent_tool_call_id":"agent-call"}]
        """.utf8))
        let tasks = try! KimiWire.decoder().decode([KimiTask].self, from: Data("""
        [{"id":"task_1","session_id":"preview","kind":"bash","description":"Run the fixture test suite","status":"running","command":"swift test --filter FixtureTests","created_at":"\(stamp(125))","started_at":"\(stamp(125))","run_in_background":true},
         {"id":"task_2","session_id":"preview","kind":"subagent","description":"Search the transcript history","status":"completed","created_at":"\(stamp(300))","started_at":"\(stamp(300))","completed_at":"\(stamp(240))","agent_id":"agent_09","subagent_type":"explore","model":"kimi-k2","run_in_background":true,"output_preview":"Test Suite passed\\n12 tests, 0 failures"},
         {"id":"task_3","session_id":"preview","kind":"tool","description":"Wait for the fixture answer","status":"cancelled","created_at":"\(stamp(400))","started_at":"\(stamp(400))","completed_at":"\(stamp(380))","run_in_background":true}]
        """.utf8))
        var board = KimiTaskBoard(subagents: roster)
        board.reconcile(background: tasks)
        for id in readOutputs { board.store(output: "PASS: fixture suite\n24 tests, 0 failures", for: id) }
        return board
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Local fixture · No agent connections").font(.headline); Spacer(); Toggle("Narrow", isOn: $narrow) }
            Toggle("Include 20 historical tool calls (hidden from the popover)", isOn: $includeHistory)
            Toggle("Include task plan", isOn: $includePlan)
            Toggle("Include tool description", isOn: $includeDescription)
            Toggle("Joined an existing turn (unknown start)", isOn: $observedOnly)
            Toggle("Include subagents and background tasks", isOn: $includeTasks)
            Toggle("Fail the task list read", isOn: $failTaskList)
            Picker("Scenario", selection: $phase) {
                ForEach(["Thinking", "Tools", "Approval", "Offline", "Stopping", "Responding", "Done", "Failed"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            Picker("Narrative", selection: $narrativeMode) {
                ForEach(["Commentary", "Provider", "Local", "External", "External failure", "None"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            Text("Reviews: \(reviewCount) · Reconnects: \(reconnectCount) · External retries: \(retryCount) · Turn: \(turn)")
            Text("Output reads: \(readOutputs.sorted().joined(separator: ", ")) · Stops: \(stops) · List refreshes: \(listRefreshes) · Transcripts: \(transcriptOpens)")
            Button("Next turn") { turn += 1; phase = "Thinking" }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Text(busy ? "Live stage · the activity bar owns the headline"
                          : "Closed stage · the transcript owns one historical headline")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if !busy, let narrative {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: narrative.phase == .blocked ? "exclamationmark.circle" : "checkmark.circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(narrative.headline).font(.system(size: 12, weight: .medium))
                            if let detail = narrative.detail { Text(detail).font(.system(size: 11)) }
                        }
                    }.foregroundStyle(narrative.phase == .blocked ? Color.orange : Color.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: busy ? "circle.dotted" : "checkmark")
                    Text("读取 Sample.swift")
                    Spacer()
                    Text(busy ? "Running" : "Completed")
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(12).frame(width: narrow ? 316 : 816, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            ConversationActivityBar(activity: ConversationActivity(
                messages: messages, isRunning: busy,
                liveTools: ["Tools", "Approval", "Offline", "Stopping"].contains(phase) ? live : [],
                online: phase != "Offline", isThinking: phase == "Thinking", isResponding: phase == "Responding",
                pendingCount: phase == "Approval" ? 2 : 0, isStopping: phase == "Stopping"),
                isRunning: busy, timing: clocks.turns["preview"], online: phase != "Offline",
                pendingCount: phase == "Approval" ? 2 : 0,
                narrativeOverride: narrative,
                externalFailureOverride: narrativeMode == "External failure" ? "Fixture timeout; the local title remains available." : nil,
                onReview: { reviewCount += 1 }, onReconnect: { reconnectCount += 1 },
                onRetryExternal: narrativeMode == "External failure" ? { retryCount += 1 } : nil,
                board: board,
                taskListError: failTaskList ? "Fixture task list unavailable" : nil,
                onTaskOutput: { readOutputs.insert($0.id) }, onTaskStop: { _ in stops += 1 },
                onTasksRefresh: { listRefreshes += 1 }, onOpenTranscript: { _ in transcriptOpens += 1 })
                .frame(width: narrow ? 340 : 840)
            Text("Continue this task, or share a new idea…").foregroundStyle(.secondary)
                .frame(width: narrow ? 308 : 808, height: 64, alignment: .topLeading).padding(16).workbenchControlSurface()
        }.padding(24)
            .onChange(of: turn, initial: true) { _, _ in updateTiming(newTurn: true) }
            .onChange(of: phase) { _, _ in updateTiming() }
            .onChange(of: observedOnly) { _, _ in turn += 1; phase = "Thinking" }
    }
    private func updateTiming(newTurn: Bool = false) {
        let id = String(turn)
        if newTurn && !observedOnly { clocks.submitted(id, at: Date().addingTimeInterval(-79)) }
        clocks.observe(sessionID: "preview", turnID: id, requestID: id, running: busy, waiting: phase == "Approval")
    }
}
private final class ActivityDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
