import Foundation
import WorkbenchCore

/// Round 14's tools-only projection exit must be indistinguishable from the
/// full-projection walk it replaces in the status line. The oracle below uses
/// ONLY pre-existing public API, so this check compiles and passes on the
/// matched baseline (where it compares the projection walk against itself) and
/// pins the exit's equivalence on the candidate — across duplicate call ids
/// (first slot, last data), orphan and pre-call results, unidentified parts,
/// live tools with and without window records, observation order, running and
/// online states, prompt-less windows and multi-prompt slicing.
func checkActivityToolsMatchProjection() throws {
    func oracleTools(_ messages: [KimiMessage], _ live: [KimiLiveTool],
                     _ running: Set<String>, _ online: Bool) -> [VisibleTool] {
        // Mirror ConversationActivity's own slicing to the current turn.
        let start = messages.lastIndex(where: \.isUserPrompt) ?? 0
        let current = start == 0 ? messages : Array(messages.dropFirst(start))
        let projection = ToolVisibilityProjection().update(current, sessionID: "activity", live: live,
                                                           running: running, online: online)
        var visible: [VisibleTool] = []
        for message in projection.messages {
            for part in message.content where part.type == "tool_use" {
                if let tool = projection.tools[part.toolCallId ?? ""] { visible.append(tool) }
            }
        }
        return visible
    }
    func activityTools(_ messages: [KimiMessage], _ live: [KimiLiveTool],
                       _ running: Set<String>, _ online: Bool) -> [VisibleTool] {
        ConversationActivity(messages: messages, isRunning: true, liveTools: live,
                             running: running, online: online).tools
    }
    func decodedMessages(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func decodedLive(_ raw: [[String: Any]]) throws -> [KimiLiveTool] {
        try KimiWire.decoder().decode([KimiLiveTool].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func use(_ id: String?, _ name: String, input: [String: Any] = ["k": "v"]) -> [String: Any] {
        var part: [String: Any] = ["type": "tool_use", "tool_name": name, "input": input]
        if let id { part["tool_call_id"] = id }
        return part
    }
    func result(_ id: String?, output: String = "ok", error: Bool? = nil) -> [String: Any] {
        var part: [String: Any] = ["type": "tool_result", "output": output]
        if let id { part["tool_call_id"] = id }
        if let error { part["is_error"] = error }
        return part
    }
    func compare(_ name: String, _ messages: [KimiMessage], _ live: [KimiLiveTool] = [],
                 _ running: Set<String> = [], _ online: Bool = true) {
        let warm = activityTools(messages, live, running, online)
        let oracle = oracleTools(messages, live, running, online)
        precondition(warm == oracle, "\(name): status-line tools must equal the full projection walk")
    }

    // Hand-built scenarios.
    let prompt: [[String: Any]] = [["id": "u0", "role": "user", "created_at": "0",
                                    "content": [["type": "text", "text": "第 0 轮：开始。"]]]]
    var scenarios: [(String, [[String: Any]], [[String: Any]], Set<String>, Bool)] = []
    scenarios.append(("plain cycle", prompt + [
        ["id": "a0", "role": "assistant", "created_at": "1", "content": [
            ["type": "thinking", "thinking": "想一想"], use("c1", "Read")]],
        ["id": "r0", "role": "tool", "created_at": "2", "content": [result("c1", output: "内容", error: false)]],
        ["id": "f0", "role": "assistant", "created_at": "3", "content": [["type": "text", "text": "完成。"]]],
    ], [], [], true))
    scenarios.append(("duplicate call ids keep the last data", prompt + [
        ["id": "a0", "role": "assistant", "created_at": "1", "content": [use("dup", "First", input: ["v": 1])]],
        ["id": "a1", "role": "assistant", "created_at": "2", "content": [use("dup", "Second", input: ["v": 2])]],
    ], [], [], true))
    scenarios.append(("orphan result", prompt + [
        ["id": "r0", "role": "tool", "created_at": "1", "content": [result("late", output: "迟到的结果", error: true)]],
    ], [], [], true))
    scenarios.append(("result before its call", prompt + [
        ["id": "r0", "role": "tool", "created_at": "1", "content": [result("early", output: "先到的结果")]],
        ["id": "a0", "role": "assistant", "created_at": "2", "content": [use("early", "Bash")]],
    ], [], [], true))
    scenarios.append(("unidentified call and result", prompt + [
        ["id": "a0", "role": "assistant", "created_at": "1", "content": [use(nil, "Grep"), result(nil, output: "x")]],
    ], [], [], true))
    scenarios.append(("live tools with and without records", prompt + [
        ["id": "a0", "role": "assistant", "created_at": "1", "content": [use("c1", "Read")]],
    ], [["tool_call_id": "c1", "name": "LiveCall", "last_progress": ["p": 1]],
        ["tool_call_id": "live1", "name": "LiveOne", "args": ["a": 1]],
        ["tool_call_id": "live1", "name": "LiveOneRenamed"],
        ["tool_call_id": "live2", "name": "LiveTwo"]], ["live1", "live2"], true))
    scenarios.append(("offline statuses", prompt + [
        ["id": "a0", "role": "assistant", "created_at": "1", "content": [use("c1", "Read"), use("c2", "Bash")]],
        ["id": "r0", "role": "tool", "created_at": "2", "content": [result("c1", error: false)]],
    ], [], ["c2"], false))
    scenarios.append(("prompt-less window", [
        ["id": "a0", "role": "assistant", "created_at": "1", "content": [use("c1", "Read")]],
    ], [], [], true))
    scenarios.append(("multi-prompt slicing", prompt + [
        ["id": "a0", "role": "assistant", "created_at": "1", "content": [use("old", "Read")]],
        ["id": "u1", "role": "user", "created_at": "2", "content": [["type": "text", "text": "第 1 轮"]]],
        ["id": "a1", "role": "assistant", "created_at": "3", "content": [use("new", "Bash")]],
    ], [], [], true))
    for (name, raw, liveRaw, running, online) in scenarios {
        compare(name, try decodedMessages(raw), try decodedLive(liveRaw), running, online)
    }

    // Deterministic randomized differential: small id pools force duplicates,
    // orphans and cross-message resolution.
    var seed: UInt64 = 0x726f_756e_6431_3400
    func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 11
    }
    func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    let idPool = ["call-a", "call-b", "call-c", "call-d"]
    var nonEmpty = 0
    for trial in 0..<2000 {
        var raw: [[String: Any]] = []
        if pick(4) > 0 {
            raw.append(["id": "u-\(pick(2))", "role": "user", "created_at": "p",
                        "content": [["type": "text", "text": "prompt \(pick(3))"]]])
        }
        for message in 0..<(1 + pick(8)) {
            var content: [[String: Any]] = []
            for _ in 0..<(1 + pick(3)) {
                switch pick(7) {
                case 0: content.append(["type": "text", "text": "正文 \(pick(5))"])
                case 1: content.append(["type": "thinking", "thinking": "思考 \(pick(3))"])
                case 2, 3:
                    var part = use(pick(6) > 0 ? idPool[pick(4)] : nil, "Tool\(pick(3))",
                                   input: ["k": "v\(pick(4))"])
                    if pick(8) == 0 { part["name"] = "named-\(pick(2))" }
                    content.append(part)
                default:
                    content.append(result(pick(6) > 0 ? idPool[pick(4)] : nil,
                                          output: "输出 \(pick(4))",
                                          error: pick(4) == 0 ? Bool(pick(2) == 0) : nil))
                }
            }
            let role: String
            switch pick(8) {
            case 0: role = "user"
            case 1, 2, 3: role = "assistant"
            default: role = "tool"
            }
            raw.append(["id": "m-\(message)", "role": role, "created_at": "\(message)", "content": content])
        }
        var liveRaw: [[String: Any]] = []
        for _ in 0..<pick(4) {
            var tool: [String: Any] = ["tool_call_id": idPool[pick(4)], "name": "Live\(pick(2))"]
            if pick(2) == 0 { tool["args"] = ["a": pick(3)] }
            if pick(3) == 0 { tool["last_progress"] = ["p": "step-\(pick(3))"] }
            liveRaw.append(tool)
        }
        var running = Set<String>()
        for id in idPool where pick(3) == 0 { running.insert(id) }
        let messages = try decodedMessages(raw)
        let live = try decodedLive(liveRaw)
        let online = pick(5) > 0
        compare("fuzz\(trial)", messages, live, running, online)
        if !activityTools(messages, live, running, online).isEmpty { nonEmpty += 1 }
    }
    precondition(nonEmpty > 1500, "the differential corpus must mostly produce visible tools, got \(nonEmpty)/2000")
    print("PASS: status-line tools equal the full projection walk across scenarios and 2000 seeded differential cases")
}
