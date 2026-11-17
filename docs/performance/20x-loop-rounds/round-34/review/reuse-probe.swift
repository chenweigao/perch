import Foundation
import WorkbenchCore

    let completedTurns = Int(ProcessInfo.processInfo.environment["STREAMING_TURNS"] ?? "") ?? 230
    let cyclesPerTurn = 34
    let runningCycles = 20
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
    func turn(_ turn: Int, running: Bool) {
        raw.append(["id": "u-\(turn)", "role": "user", "created_at": stamp(),
                    "content": [["type": "text", "text": "第 \(turn) 轮：\(prompt)"]]])
        for step in 0..<(running ? runningCycles : cyclesPerTurn) { cycle(turn: turn, step: step) }
        if !running {
            raw.append(["id": "f-\(turn)", "role": "assistant", "created_at": stamp(), "content": [
                ["type": "thinking", "thinking": thinking], ["type": "text", "text": "完成。\n\n\(answer)"]]])
        }
    }
    // Earlier turns of the same shape, read later as 100-message history
    // pages (bench uses 5 turns/3 pages; the profile harness extends to 30
    // turns/20 pages so measured prepends dominate the per-cycle re-warm —
    // each prepend is mechanically identical, window grows 16k->18k, both
    // disclosed).
    for index in -30..<0 { turn(index, running: false) }
    let earlierRaw = raw
    raw = []
    for index in 0...completedTurns { turn(index, running: index == completedTurns) }
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
    let messages = conversation.displayMessages

    let decoder = KimiWire.decoder()
    let earlier = try decoder.decode([KimiMessage].self,
        from: JSONSerialization.data(withJSONObject: earlierRaw))

func field(_ value: Any, _ key: String) -> Any {
    Mirror(reflecting: value).children.first { $0.label == key }!.value
}
func history(_ snapshot: ConversationPresentationModel.Snapshot) -> AnyObject {
    field(snapshot, "history") as AnyObject
}
func turns(_ snapshot: ConversationPresentationModel.Snapshot) -> [AnyObject] {
    field(history(snapshot), "turns") as! [AnyObject]
}
func memoRows(_ turn: AnyObject) -> [ConversationPresentationModel.Row]? {
    let optional = field(turn, "presentation")
    guard let tuple = Mirror(reflecting: optional).children.first?.value else { return nil }
    return (field(tuple, "value") as! ConversationPresentationModel.Presentation).rows
}
func ptr(_ rows: [ConversationPresentationModel.Row]?) -> UInt? {
    rows?.withUnsafeBufferPointer { $0.baseAddress.map { UInt(bitPattern: $0) } }
}
let key = "host:kimi:s"
var latestMetrics: ConversationPresentationUpdateMetrics?
let model = ConversationPresentationModel(key: key, metricsHandler: { latestMetrics = $0 })
let tools = ToolVisibilityProjection()
var window = messages
func input(_ window: [KimiMessage]) -> ConversationPresentationModel.Input {
    .init(messages: window, isRunning: true, epoch: "bench", language: "zh")
}
var previousSnapshot = model.update(input(window))
_ = previousSnapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
var previousSplit = tools.update(window, splittingAt: window.lastIndex(where: \.isUserPrompt)!, sessionID: key)
for page in 0..<20 {
    let priorTurns = turns(previousSnapshot)
    let priorMemos = Dictionary(uniqueKeysWithValues: priorTurns.map { (ObjectIdentifier($0), ptr(memoRows($0))) })
    let start = earlier.count - 100 * (page + 1)
    window = Array(earlier[start..<(start + 100)]) + window
    let snapshot = model.update(input(window))
    let updatedTurns = turns(snapshot)
    let sameTurns = updatedTurns.filter { priorMemos.keys.contains(ObjectIdentifier($0)) }
    let preexistingMemos = sameTurns.filter { ptr(memoRows($0)) == priorMemos[ObjectIdentifier($0)]! }
    _ = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
    let retainedMemos = sameTurns.filter { ptr(memoRows($0)) == priorMemos[ObjectIdentifier($0)]! }
    let split = tools.update(window, splittingAt: window.lastIndex(where: \.isUserPrompt)!, sessionID: key)
    let oldChunks = Set(previousSplit.prefix.chunks!.map(ObjectIdentifier.init))
    let retainedChunks = split.prefix.chunks!.filter { oldChunks.contains(ObjectIdentifier($0)) }.count
    let metrics = latestMetrics!
    print("page=\(page + 1) messages=\(window.count) chunks_reused=\(retainedChunks) history_turn_refs_reused=\(sameTurns.count) existing_memos_before=\(preexistingMemos.count) existing_memos_after=\(retainedMemos.count) metrics_reused=\(metrics.reusedTurnCount) metrics_rebuilt=\(metrics.rebuiltTurnCount) history_container_same=\(history(snapshot) === history(previousSnapshot))")
    precondition(sameTurns.count >= 230 && retainedMemos.count == sameTurns.count)
    previousSnapshot = snapshot
    previousSplit = split
}
print("PASS: existing turn, chunk and presentation memo identities survive ordinal shifts; only History/global assembly is rebuilt")
