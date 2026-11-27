import Foundation
import WorkbenchCore

/// Pins round-2 shard A lazy navigation: cold projection builds identity-only
/// summaries (excerpt walk deferred to first read), materialized values equal
/// the eager factory byte-for-byte, and reference identity tracks turn rebuild
/// so view change detection never forces materialization.
func checkLazyNavigation() throws {
    func decode(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    var raw: [[String: Any]] = []
    for i in 0..<12 {
        raw.append(["id": "u\(i)", "role": "user", "created_at": "u\(i)",
                    "content": [["type": "text", "text": "问题 \(i)：解释结论，混排 identifier 与 English words。"]]])
        if i % 3 == 0 {
            raw.append(["id": "t\(i)", "role": "assistant", "created_at": "t\(i)", "content": [
                ["type": "tool_use", "tool_call_id": "tool-\(i)", "tool_name": "Bash",
                 "input": ["command": "run fixture \(i)"]]]])
            raw.append(["id": "tr\(i)", "role": "tool", "created_at": "tr\(i)", "content": [
                ["type": "tool_result", "tool_call_id": "tool-\(i)", "is_error": false,
                 "output": ["rows": ["中文结果 ok"]]]]])
        }
        raw.append(["id": "a\(i)", "role": "assistant", "created_at": "a\(i)",
                    "content": [["type": "text", "text": "回答 \(i) 结论。\n\n```swift\nlet value = \(i)\n```"]]])
    }
    let messages = try decode(raw)
    let model = ConversationPresentationModel(key: "lazy-nav")
    let snapshot = model.update(.init(messages: messages, language: "zh"))
    let nav = snapshot.navigation
    precondition(nav.count >= 2, "lazy-nav fixture must yield multiple turns (chunk path)")

    // 1. Cold projection leaves earlier summaries unmaterialized (anti-blind:
    //    the tail turn stays eager, so a fully-eager regression fails here).
    for summary in nav.dropLast() {
        precondition(!summary.materialized, "cold projection must not extract earlier excerpts")
    }

    // 2/3. Per-turn eager reference: ids in order, excerpts byte-equal.
    var turns: [[KimiMessage]] = []
    var current: [KimiMessage] = []
    for message in messages {
        if message.isUserPrompt && !current.isEmpty { turns.append(current); current = [] }
        current.append(message)
    }
    if !current.isEmpty { turns.append(current) }
    var reference: [ConversationTurnSummary] = []
    for turn in turns {
        let entries = ConversationTimelineEntry.make(turn)
        if let summary = ConversationTurnSummary.make(turn, entries: entries) { reference.append(summary) }
    }
    precondition(nav.count == reference.count, "navigation count must equal eager reference")
    for (summary, eager) in zip(nav, reference) {
        precondition(summary.id == eager.id, "navigation id order must equal eager")
        precondition(summary.prompt == eager.prompt, "lazy prompt must equal eager byte-for-byte")
        precondition(summary.reply == eager.reply, "lazy reply must equal eager byte-for-byte")
        precondition(summary.materialized, "reading excerpts must materialize")
        precondition(summary.prompt == eager.prompt, "materialization must be idempotent")
    }

    // 4. Reference identity: input-equal update keeps instances; a rebuilt
    //    turn yields a new instance while reused turns keep theirs.
    let again = model.update(.init(messages: messages, language: "zh"))
    precondition(again.navigation.count == nav.count, "input-equal update keeps navigation shape")
    precondition(zip(again.navigation, nav).allSatisfy { $0 === $1 },
                 "input-equal update must keep summary instances")
    var edited = messages
    if let index = edited.firstIndex(where: { $0.id == "a0" }) {
        edited[index] = try decode([["id": "a0", "role": "assistant", "created_at": "a0",
                                     "content": [["type": "text", "text": "修改后的回答 0 结论。"]]]])[0]
    }
    let after = model.update(.init(messages: edited, language: "zh"))
    precondition(after.navigation.count == nav.count, "edit must keep turn count")
    precondition(after.navigation[0] !== nav[0], "rebuilt turn must yield a new summary instance")
    precondition(after.navigation[nav.count - 2] === nav[nav.count - 2],
                 "reused turn must keep its summary instance")

    // 5. Lazy factory defers; value equality materializes both sides.
    let entries0 = ConversationTimelineEntry.make(turns[0])
    let lazyRef = ConversationTurnSummary.lazy(turns[0], entries: entries0)
    let eagerRef = ConversationTurnSummary.make(turns[0], entries: entries0)
    precondition(lazyRef != nil && eagerRef != nil, "fixture turn 0 must yield a summary")
    precondition(!lazyRef!.materialized, "lazy factory must not extract")
    precondition(lazyRef! == eagerRef!, "lazy must equal eager by value")
    precondition(lazyRef!.materialized && eagerRef!.materialized, "equality must materialize both sides")

    // 6. Non-prompt turn yields no summary (guard parity with make).
    let noPrompt = try decode([["id": "x", "role": "assistant", "created_at": "x",
                                "content": [["type": "text", "text": "only answer"]]]])
    precondition(ConversationTurnSummary.lazy(noPrompt, entries: ConversationTimelineEntry.make(noPrompt)) == nil,
                 "lazy factory must mirror make's user-prompt guard")
    print("PASS: lazy navigation — cold deferral (anti-blind), eager byte-equality, identity tracking, equality materialization")
}
