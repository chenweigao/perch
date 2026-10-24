import Foundation
import QuartzCore
import WorkbenchCore

/// The synchronous model work one streaming delta costs a long, running Kimi
/// session whose older pages were loaded by scrolling up: the conversation
/// mutation, the activity bar's derivation, the transcript's presentation
/// update and the transcript body's row projection, in the order the views
/// evaluate them. Not part of the checked-in suite; run with
/// WORKBENCH_BENCH=streaming. It excludes SwiftUI/AppKit layout and FPS.
func benchStreamingDelta() throws {
    let completedTurns = Int(ProcessInfo.processInfo.environment["STREAMING_TURNS"] ?? "") ?? 230
    let cyclesPerTurn = 34
    let runningCycles = 20
    let measured = 30
    let thinking = String(repeating: "先确认当前实现与调用方的约束，再决定下一步 inspect the call sites. ", count: 9)
    let prompt = String(repeating: "请继续推进这个任务，修复问题并验证结果。", count: 8)
    let answer = (0..<12).map { "- 第 \($0) 项结论：`Identifier\($0)` 已经处理，并附带 English notes for the reader." }
        .joined(separator: "\n")
    let readOutput = (0..<60).map { "\($0)\tlet value\($0) = compute(\($0)) // 源代码行" }.joined(separator: "\n")
    let bashOutput = (0..<24).map { "PASS case \($0) 通过 in 0.0\($0)s" }.joined(separator: "\n")
    let grepOutput = (0..<16).map { "Sources/File\($0).swift:\($0 * 7): match 匹配行" }.joined(separator: "\n")
    let oldBlock = (0..<14).map { "    let value\($0) = compute(\($0)) // 原有实现" }.joined(separator: "\n")
    let newBlock = (0..<16).map { "    let value\($0) = computeFaster(\($0)) // 新实现" }.joined(separator: "\n")
    let written = (0..<90).map { "line \($0): 写入的文件内容 with mixed text" }.joined(separator: "\n")

    var raw: [[String: Any]] = []
    var clock = 0
    func stamp() -> String { clock += 1; return String(format: "2026-10-23T%09d", clock) }
    func cycle(turn: Int, step: Int) {
        let id = "t\(turn)-s\(step)"
        let tool: [String: Any]
        let output: String
        switch step % 10 {
        case 0, 3, 6:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Read",
                    "input": ["file_path": "/repo/Sources/File\(step).swift"]]
            output = readOutput
        case 1, 4, 8:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Bash",
                    "input": ["command": "swift test --filter Case\(step)", "description": "Run case \(step)"]]
            output = bashOutput
        case 2, 7:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Grep",
                    "input": ["pattern": "compute\\(", "path": "/repo/Sources"]]
            output = grepOutput
        case 5:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Edit",
                    "input": ["file_path": "/repo/Sources/File\(step).swift", "old_string": oldBlock, "new_string": newBlock]]
            output = "ok"
        default:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Write",
                    "input": ["file_path": "/repo/Generated/Out\(turn)-\(step).swift", "content": written]]
            output = "ok"
        }
        var content: [[String: Any]] = [["type": "thinking", "thinking": thinking]]
        if step % 4 == 0 { content.append(["type": "text", "text": "检查第 \(step) 步的结果。"]) }
        content.append(tool)
        raw.append(["id": "a-\(id)", "role": "assistant", "created_at": stamp(), "content": content])
        raw.append(["id": "r-\(id)", "role": "tool", "created_at": stamp(), "content": [
            ["type": "tool_result", "tool_call_id": "call-\(id)", "is_error": false, "output": output]]])
    }
    for turn in 0...completedTurns {
        raw.append(["id": "u-\(turn)", "role": "user", "created_at": stamp(),
                    "content": [["type": "text", "text": "第 \(turn) 轮：\(prompt)"]]])
        let running = turn == completedTurns
        for step in 0..<(running ? runningCycles : cyclesPerTurn) { cycle(turn: turn, step: step) }
        if !running {
            raw.append(["id": "f-\(turn)", "role": "assistant", "created_at": stamp(), "content": [
                ["type": "thinking", "thinking": thinking], ["type": "text", "text": "完成。\n\n\(answer)"]]])
        }
    }
    let snapshotJSON: [String: Any] = [
        "as_of_seq": 1, "epoch": "bench",
        "session": ["id": "s", "title": "bench", "updated_at": "1", "busy": true, "main_turn_active": true,
                    "metadata": ["cwd": "/repo"], "agent_config": ["model": "bench"]],
        "messages": ["items": raw, "has_more": false],
        "in_flight_turn": ["turn_id": 1, "assistant_text": "", "thinking_text": "开始思考。", "running_tools": []],
        "pending_approvals": [], "pending_questions": []
    ]
    let snapshotData = try JSONSerialization.data(withJSONObject: snapshotJSON)
    var conversation = KimiConversation(try KimiWire.decoder().decode(KimiSnapshot.self, from: snapshotData))
    let decoder = KimiWire.decoder()
    func delta(_ text: String, offset: Int) throws -> KimiEvent {
        try decoder.decode(KimiEvent.self, from: JSONSerialization.data(withJSONObject: [
            "type": "thinking.delta", "session_id": "s", "epoch": "bench", "volatile": true, "offset": offset,
            "payload": ["agentId": "main", "turnId": 1, "delta": text]] as [String: Any]))
    }

    let handle = ConversationPresentationHandle()
    let cache = ConversationPresentationCache()
    let editStats = SessionEditStatsCache()
    let key = "host:kimi:s"
    var stages: [String: [Double]] = [:]
    var presentationStages: [String: [Double]] = [:]
    var rowCount = 0, entryCount = 0
    func ms(_ start: Double) -> Double { (CACurrentMediaTime() - start) * 1_000 }
    func nanos(_ value: UInt64) -> Double { Double(value) / 1_000_000 }
    var metrics: ConversationPresentationUpdateMetrics?
    let model = ConversationPresentationModel(key: key, metricsHandler: { metrics = $0 })
    _ = model.update(.init(messages: conversation.displayMessages, isRunning: true, epoch: "bench", language: "zh"))

    for update in 0..<(measured + 5) {
        let event = try delta("继续推理第 \(update) 段。", offset: conversation.live?.thinkingText.utf16.count ?? 0)
        var t = CACurrentMediaTime()
        _ = conversation.apply(event)
        let apply = ms(t)

        // KimiWorkspaceView: the activity bar's summary of the whole loaded window.
        t = CACurrentMediaTime()
        let workspaceMessages = conversation.displayMessages
        let display1 = ms(t)
        t = CACurrentMediaTime()
        let activity = ConversationActivity(messages: workspaceMessages, isRunning: true, liveTools: [], online: true,
                                            isThinking: true, isResponding: false, editStats: editStats)
        let activityMs = ms(t)

        // KimiTimeline + ConversationTranscript.
        t = CACurrentMediaTime()
        let timelineMessages = conversation.displayMessages
        let display2 = ms(t)
        let input = ConversationPresentationModel.Input(messages: timelineMessages, live: [], running: [], isRunning: true,
                                                        online: true, epoch: "bench", language: "zh")
        t = CACurrentMediaTime()
        let snapshot = handle.update(key: key, input: input, cache: cache)
        let presentation = ms(t)
        metrics = nil
        _ = model.update(input)
        t = CACurrentMediaTime()
        let presented = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
        let presentedMs = ms(t)
        t = CACurrentMediaTime()
        let memoryKeys = presented.rows.map { key + ":" + $0.entry.id }
        let contentsMs = ms(t)
        rowCount = memoryKeys.count
        precondition(activity.isVisible)
        if update < 2 {
            let reference = ConversationProcessFold.fold(rows: snapshot.displayedRows { _ in nil }, isRunning: true)
            let parents = reference.reduce(into: [String: String]()) { map, row in
                for folded in row.foldedRows ?? [] { map[folded.entry.id] = row.entry.id }
            }
            precondition(presented.rows == reference && presented.foldParents == parents, "presented must equal displayedRows + fold")
            precondition(activity.edits?.total == SessionEditStats.derive(from: workspaceMessages)?.total)
            entryCount = snapshot.rows.count
        }
        guard update >= 5 else { continue }
        for (name, value) in [("apply", apply), ("display_messages_workspace", display1), ("conversation_activity", activityMs),
                              ("display_messages_timeline", display2), ("presentation_update", presentation),
                              ("presented_rows", presentedMs), ("memory_keys", contentsMs)] {
            stages[name, default: []].append(value)
        }
        if let metrics {
            for (name, value) in [("input_comparison", metrics.inputComparisonNanoseconds), ("tool_projection", metrics.toolProjectionNanoseconds),
                                  ("turn_projection", metrics.turnProjectionNanoseconds), ("narrative", metrics.narrativeNanoseconds),
                                  ("row_projection", metrics.rowProjectionNanoseconds), ("summary", metrics.summaryNanoseconds),
                                  ("retained_cost", metrics.retainedCostNanoseconds), ("total", metrics.totalNanoseconds)] {
                presentationStages[name, default: []].append(nanos(value))
            }
        }
    }
    // One older page arriving while reading: the full projection a page costs.
    var paged: [Double] = []
    for page in 0..<3 {
        let older = try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: (0..<100).map { index -> [String: Any] in
            ["id": "older-\(page)-\(index)", "role": index == 0 ? "user" : "assistant", "created_at": String(format: "2026-10-22T%04d%04d", 9 - page, index),
             "content": [["type": "text", "text": "较早的第 \(page) 页第 \(index) 条。"]]]
        }))
        let messages = older + conversation.displayMessages
        let t = CACurrentMediaTime()
        let snapshot = handle.update(key: key, input: .init(messages: messages, isRunning: true, epoch: "bench", language: "zh"), cache: cache)
        _ = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
        _ = ConversationActivity(messages: messages, isRunning: true, isThinking: true, editStats: editStats)
        paged.append(ms(t))
    }
    // Leaving the session releases its presentation state and loaded window.
    var released: [Double] = []
    for _ in 0..<3 {
        // An independent copy: the tuple is the only owner of the window and its projection.
        var held: (ConversationPresentationModel, ConversationPresentationModel.Snapshot, KimiConversation)? = try {
            let copy = KimiConversation(try decoder.decode(KimiSnapshot.self, from: snapshotData))
            let leaving = ConversationPresentationModel(key: key)
            let snapshot = leaving.update(.init(messages: copy.displayMessages, isRunning: true, epoch: "bench", language: "zh"))
            _ = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
            return (leaving, snapshot, copy)
        }()
        let t = CACurrentMediaTime()
        held = nil
        released.append(ms(t))
        precondition(held == nil)
    }
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    func line(_ name: String, _ value: Double, indent: String = "  ") -> String {
        indent + name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "median_ms=%8.2f", value)
    }
    let order = ["apply", "display_messages_workspace", "conversation_activity", "display_messages_timeline",
                 "presentation_update", "presented_rows", "memory_keys"]
    let total = order.reduce(0) { $0 + median(stages[$1]!) }
    print("streaming_bench messages=\(conversation.displayMessages.count) entries=\(entryCount) rows=\(rowCount) measured=\(measured)")
    for name in order { print(line(name, median(stages[name]!))) }
    print(line("chain_total", total))
    print("  presentation_update breakdown (separate warm model with metrics):")
    for name in ["input_comparison", "tool_projection", "turn_projection", "narrative", "row_projection", "summary", "retained_cost", "total"] {
        print(line(name, median(presentationStages[name]!), indent: "    "))
    }
    print(line("older_page_full_chain", median(paged)))
    print(line("release_model_state", median(released)))
}
