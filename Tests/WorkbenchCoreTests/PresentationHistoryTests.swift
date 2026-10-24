import Foundation
import WorkbenchCore

/// The presentation model reuses the turns before the latest prompt while only
/// the latest turn changes. Every snapshot must still equal a complete
/// recomputation, including the cases where a tool identity, a live tool or an
/// entry identity crosses the split and reuse must not happen.
func checkConversationPresentationHistory() throws {
    typealias Model = ConversationPresentationModel
    typealias Row = Model.Row
    var clock = 0
    func message(_ id: String, _ role: String, _ content: [[String: Any]]) -> [String: Any] {
        clock += 1
        return ["id": id, "role": role, "created_at": String(format: "%06d", clock), "content": content]
    }
    func decode(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func completed(_ turn: Int, result: Bool = true) -> [[String: Any]] {
        var raw = [
            message("u\(turn)", "user", [["type": "text", "text": "第 \(turn) 轮问题"]]),
            message("a\(turn)", "assistant", [["type": "thinking", "thinking": "思考 \(turn)"],
                                               ["type": "text", "text": "先读取文件 \(turn)"],
                                               ["type": "tool_use", "tool_call_id": "read-\(turn)", "tool_name": "Read",
                                                "input": ["path": "File\(turn).swift"]]])]
        if result {
            raw.append(message("r\(turn)", "tool", [["type": "tool_result", "tool_call_id": "read-\(turn)",
                                                      "output": "内容 \(turn)", "is_error": false]]))
        }
        raw.append(message("b\(turn)", "assistant", [["type": "tool_use", "tool_call_id": "bash-\(turn)", "tool_name": "Bash",
                                                      "input": ["command": "swift test", "description": "Run tests \(turn)"]]]))
        raw.append(message("br\(turn)", "tool", [["type": "tool_result", "tool_call_id": "bash-\(turn)",
                                                   "output": "Command failed with exit code: 1", "is_error": turn % 2 == 0]]))
        if turn == 1 {
            raw.append(message("anon", "assistant", [["type": "tool_use", "tool_name": "Read", "input": ["path": "anon"]]]))
        }
        raw.append(message("f\(turn)", "assistant", [["type": "text", "text": "第 \(turn) 轮完成"]]))
        return raw
    }
    let history = try decode((0..<4).flatMap { completed($0, result: $0 != 2) })
    let prompt = try decode([message("u4", "user", [["type": "text", "text": "继续"]])])
    let call = try decode([message("a4", "assistant", [["type": "thinking", "thinking": "检查"],
                                                       ["type": "tool_use", "tool_call_id": "read-4", "tool_name": "Read",
                                                        "input": ["path": "Live.swift"]]])])
    let result = try decode([message("r4", "tool", [["type": "tool_result", "tool_call_id": "read-4",
                                                      "output": "完成", "is_error": false]])])
    func thought(_ tokens: Int) throws -> [KimiMessage] {
        try decode([["id": "live:1", "role": "assistant", "created_at": "",
                     "content": [["type": "thinking", "thinking": String(repeating: "推理 ", count: tokens)]]]])
    }
    let thoughts = try (0...20).map(thought)
    let lateResult = try decode([message("late", "tool", [["type": "tool_result", "tool_call_id": "read-2",
                                                            "output": "迟到的结果", "is_error": false]])])
    let unidentified = try decode([message("anon", "assistant", [["type": "tool_use", "tool_name": "Read", "input": ["path": "anon"]]])])
    let sharedID = try decode([message("f3", "assistant", [["type": "text", "text": "同 ID 的进度"]])])
    let older = try decode([message("u-old", "user", [["type": "text", "text": "更早的问题"]]),
                            message("f-old", "assistant", [["type": "text", "text": "更早的回答"]])])
    let next = try decode([message("u5", "user", [["type": "text", "text": "下一轮"]])])
    let liveRead = try KimiWire.decoder().decode([KimiLiveTool].self, from: Data(
        #"[{"tool_call_id":"read-4","name":"Read","args":{"path":"Live.swift"},"last_progress":"读取中"}]"#.utf8))
    let liveReused = try KimiWire.decoder().decode([KimiLiveTool].self, from: Data(
        #"[{"tool_call_id":"bash-1","name":"Bash","args":{"command":"again"}}]"#.utf8))

    struct Step {
        let name: String
        let input: Model.Input
        let reuses: Bool?
    }
    func input(_ messages: [KimiMessage], live: [KimiLiveTool] = [], running: Set<String> = [], isRunning: Bool = true,
               online: Bool = true, epoch: String = "one", language: String = "zh") -> Model.Input {
        Model.Input(messages: messages, live: live, running: running, isRunning: isRunning, online: online,
                    epoch: epoch, language: language, summariesEnabled: true, includeToolOutput: true)
    }
    let base = history + prompt + call
    let steps: [Step] = [
        Step(name: "first", input: input(base + thoughts[1], live: liveRead), reuses: false),
        Step(name: "token", input: input(base + thoughts[2], live: liveRead), reuses: true),
        Step(name: "running set", input: input(base + thoughts[3], live: liveRead, running: ["read-4"]), reuses: true),
        Step(name: "tail result", input: input(base + result + thoughts[4]), reuses: true),
        Step(name: "result for an earlier call", input: input(base + result + lateResult + thoughts[5]), reuses: false),
        Step(name: "still crossing", input: input(base + result + lateResult + thoughts[6]), reuses: false),
        Step(name: "crossing removed", input: input(base + result + thoughts[7]), reuses: false),
        Step(name: "reused again", input: input(base + result + thoughts[8]), reuses: true),
        Step(name: "offline", input: input(base + result + thoughts[8], online: false), reuses: false),
        Step(name: "online", input: input(base + result + thoughts[9]), reuses: false),
        Step(name: "token after reconnect", input: input(base + result + thoughts[10]), reuses: true),
        Step(name: "positional identity", input: input(base + unidentified + thoughts[11]), reuses: false),
        Step(name: "earlier tool running", input: input(base + result + thoughts[12], running: ["read-2"]), reuses: false),
        Step(name: "earlier tool stopped", input: input(base + result + thoughts[13]), reuses: false),
        Step(name: "token after stop", input: input(base + result + thoughts[14]), reuses: true),
        Step(name: "shared entry identity", input: input(base + sharedID + thoughts[15]), reuses: nil),
        Step(name: "older page", input: input(older + base + result + thoughts[16]), reuses: false),
        Step(name: "token after page", input: input(older + base + result + thoughts[17]), reuses: true),
        Step(name: "language", input: input(older + base + result + thoughts[17], language: "en"), reuses: false),
        Step(name: "token in english", input: input(older + base + result + thoughts[18], language: "en"), reuses: true),
        Step(name: "completed", input: input(older + base + result, isRunning: false, language: "en"), reuses: true),
        Step(name: "live tool with an earlier identity", input: input(older + base + result + thoughts[1], live: liveReused, language: "en"), reuses: false),
        Step(name: "remembered live tool", input: input(older + base + result + thoughts[2], language: "en"), reuses: false),
        Step(name: "next prompt", input: input(older + base + result + next, language: "en"), reuses: false),
        Step(name: "token in next turn", input: input(older + base + result + next + thoughts[1], language: "en"), reuses: true),
        Step(name: "epoch", input: input(older + base + result + next + thoughts[2], epoch: "two", language: "en"), reuses: false),
        Step(name: "token after epoch", input: input(older + base + result + next + thoughts[3], epoch: "two", language: "en"), reuses: true),
        Step(name: "only the first prompt", input: input(prompt + call + thoughts[1]), reuses: false),
        Step(name: "no prompt", input: input(call + result + thoughts[1]), reuses: false),
    ]

    func displayed(_ rows: [Row], activity: [String: ActivityNarrativeRow]) -> [Row] {
        let live = rows.last { $0.entry.presentation == .progress && $0.activity?.stageClosed == false }?.entry.id
        return rows.compactMap { row in
            if row.entry.id == live { return Row(entry: row.entry, tools: row.tools, activity: nil) }
            let narrative = activity[row.entry.id] ?? row.activity
            if let narrative, narrative.isAnchor, !narrative.stageClosed, row.entry.isNarrativeSource(for: narrative.narrative) { return nil }
            return Row(entry: row.entry, tools: row.tools, activity: narrative)
        }
    }

    var metrics: ConversationPresentationUpdateMetrics?
    let model = Model(key: "host:kimi:s", metricsHandler: { metrics = $0 })
    var referenceTools = ToolVisibilityProjection(), referenceTurns = ConversationProjection()
    var previous: Model.Input?
    var reused = 0
    var remembered: [String: KimiLiveTool] = [:]
    for step in steps {
        if let previous, previous.epoch != step.input.epoch { referenceTools = ToolVisibilityProjection(); remembered = [:] }
        for tool in step.input.live { remembered[tool.id] = tool }
        if let previous, previous.epoch != step.input.epoch || previous.language != step.input.language {
            referenceTurns = ConversationProjection()
        }
        previous = step.input
        let visible = referenceTools.update(step.input.messages, sessionID: model.key, live: step.input.live,
                                            running: step.input.running, online: step.input.online)
        let timeline = referenceTurns.update(visible.messages, isRunning: step.input.isRunning)
        let narrative = ActivityNarrativeProjection.make(entries: timeline.entries, tools: visible.tools, isRunning: step.input.isRunning)
        let rows = timeline.entries.map { entry -> Row in
            let ids = Set(entry.messages.flatMap(\.content).compactMap(\.toolCallId))
            return Row(entry: entry, tools: visible.tools.filter { ids.contains($0.key) }, activity: narrative.rows[entry.id])
        }
        metrics = nil
        let snapshot = model.update(step.input)
        precondition(snapshot.rows == rows, "\(step.name): rows must equal a complete recomputation")
        precondition(snapshot.navigation == timeline.navigation && snapshot.narrative == narrative, "\(step.name): navigation and narrative")
        precondition(snapshot.batch == ActivitySummaryBatch.latest(in: timeline.entries, tools: visible.tools,
            isRunning: step.input.isRunning, enabled: true, includeToolOutput: true), "\(step.name): summary batch")
        // Remembered live tools count toward the budget; give a fresh model the same ones.
        let oracle = Model(key: model.key)
        _ = oracle.update(.init(messages: [], live: Array(remembered.values), epoch: step.input.epoch, language: step.input.language))
        _ = oracle.update(step.input)
        precondition(model.retainedPayloadCost == oracle.retainedPayloadCost, "\(step.name): payload admission cost")
        if let expected = step.reuses {
            precondition(metrics?.reusedHistory == expected, "\(step.name): history reuse must be \(expected)")
        }
        if metrics?.reusedHistory == true { reused += 1 }

        // Summary overlays on an earlier and on the latest turn, with and without folding.
        let earlierProgress = rows.first { $0.entry.presentation == .progress }?.entry.id
        let latestRow = rows.last?.entry.id
        func overlay(_ id: String?, anchor: Bool, closed: Bool) -> [String: ActivityNarrativeRow] {
            guard let id else { return [:] }
            return [id: ActivityNarrativeRow(narrative: .init(turnID: "u", stageID: "external-\(id)", phase: .editing,
                headline: "外部摘要", source: .commentary, lifecycle: closed ? .final : .streaming), isAnchor: anchor, stageClosed: closed)]
        }
        let overlays = [[:], overlay(earlierProgress, anchor: true, closed: false), overlay(earlierProgress, anchor: true, closed: true),
                        overlay(latestRow, anchor: false, closed: false)]
        for activity in overlays {
            for folds in [true, false] {
                for running in [step.input.isRunning, !step.input.isRunning] {
                    let shown = displayed(rows, activity: activity)
                    let expected = folds ? ConversationProcessFold.fold(rows: shown, isRunning: running) : shown
                    let parents = expected.reduce(into: [String: String]()) { map, row in
                        for folded in row.foldedRows ?? [] { map[folded.entry.id] = row.entry.id }
                    }
                    for _ in 0..<2 {
                        let presented = snapshot.presented(activity: activity, foldsProcess: folds, isRunning: running)
                        precondition(presented.rows == expected && presented.foldParents == parents,
                                     "\(step.name): presented rows must equal displayedRows and the fold")
                    }
                }
            }
        }
    }
    precondition(reused >= 9, "Token updates must reuse the earlier turns")

    // The split projection concatenates to the complete projection.
    let split = ToolVisibilityProjection(), whole = ToolVisibilityProjection()
    var prefix: ToolVisibilityProjection.Prefix?
    for (index, messages) in [base + thoughts[1], base + thoughts[2], base + result + lateResult, base + result + thoughts[3]].enumerated() {
        let at = messages.lastIndex(where: \.isUserPrompt)!
        let parts = split.update(messages, splittingAt: at, sessionID: "s", live: liveRead)
        let reference = whole.update(messages, sessionID: "s", live: liveRead)
        precondition(parts.prefix.messages + parts.tail.messages == reference.messages
                     && parts.prefix.tools.merging(parts.tail.tools) { _, latest in latest } == reference.tools,
                     "Split projection must concatenate to the complete projection")
        precondition(parts.separable == (index != 2), "A result for an earlier call crosses the split")
        if index == 1 { precondition(parts.prefix === prefix, "An unchanged prefix is reused") }
        if index == 3 { precondition(parts.prefix !== prefix, "A prefix projected with a crossing identity is not reused") }
        prefix = parts.prefix
    }
    print("PASS: presentation history reuse matches complete recomputation across tokens, paging, crossings, language, epoch and overlays")
}

func checkSessionEditStatsCache() throws {
    var clock = 0
    func edit(_ id: String, path: String, old: String, new: String) -> [String: Any] {
        clock += 1
        return ["id": id, "role": "assistant", "created_at": String(clock), "content": [
            ["type": "tool_use", "tool_call_id": id, "tool_name": "Edit",
             "input": ["file_path": path, "old_string": old, "new_string": new]]]]
    }
    func user(_ id: String) -> [String: Any] {
        clock += 1
        return ["id": id, "role": "user", "created_at": String(clock), "content": [["type": "text", "text": id]]]
    }
    func decode(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    let first = try decode([user("u1"), edit("e1", path: "a.swift", old: "a\nb", new: "a\nc\nd")])
    let second = try decode([user("u2"), edit("e2", path: "a.swift", old: "x", new: "y"), edit("e3", path: "b.swift", old: "", new: "1\n2")])
    let revised = try decode([user("u1"), edit("e1", path: "a.swift", old: "a\nb", new: "z")])
    let older = try decode([user("u0"), edit("e0", path: "c.swift", old: "q", new: "")])
    let cache = SessionEditStatsCache()
    for messages in [first, first + second, first + second + Array(second.suffix(1)), revised + second,
                     older + revised + second, older + revised + second, Array(second.prefix(1)), [], first] {
        let cached = cache.derive(from: messages), reference = SessionEditStats.derive(from: messages)
        precondition(cached?.perFile == reference?.perFile && cached?.total == reference?.total,
                     "Cached session edit tallies must equal a complete derivation")
    }
    print("PASS: session edit tallies reuse earlier turns only while they are unchanged")
}
