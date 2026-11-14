import Foundation
import WorkbenchCore

/// Round 12's find-bar result reuse must be invisible: every warm-instance call
/// equals a fresh instance's complete search across token growth under both a
/// changing and a fixed query, in-place payload edits (same-byte-length answer
/// text, a tool input's zero sign, a tool call id, timestamps of both a skipped
/// and an entry-bearing message), metadata-only edits, windows rebuilt from the
/// same wire data, prepended pages, running-flag flips, query/regex/case/role
/// switches and canonically equal but encoding-distinct queries.
///
/// Reuse may engage only when the search inputs are identical in the sense the
/// results depend on: encoding-exact query keys, and messages that are bitwise
/// equal or value-equal with byte-identical rendered fields — canonical value
/// equality alone is weaker than search equivalence (a zero sign renders, an
/// NFC/NFD pair matches differently).
///
/// On the matched baseline (unoptimized product, same tests) this walk fails by
/// design at the first transition that reaches the pre-existing prefix-cache
/// holes — the tool-input zero-sign flip, and after it the NFD query switch:
/// the baseline's Earlier reuse compares windows and queries by canonical value
/// and serves stale prefix hits. The candidate must pass every step.
func checkSearchEntryReuse() throws {
    let prose = String(repeating: "这一轮的说明包含 English identifiers 与中文混排，长到不会内联进字符串。", count: 3)
    let toolOutput = (0..<40).map { "\($0)\tlet value\($0) = compute(\($0)) // 源代码行" }.joined(separator: "\n")
    let answer = "第 0 轮完成，ALPHA 已经处理：\(prose) caf\u{00e9}。"
    let editedAnswer = answer.replacingOccurrences(of: "ALPHA", with: "ALPHB")
    precondition(answer.utf8.count == editedAnswer.utf8.count,
                 "The in-place edit keeps the answer's byte length")

    struct Wire {
        var answer: String
        var answerStamp = "000004"
        var r0Stamp = "000003"
        var r0Role = "tool"
        var retries = -0.0
        var toolCallID = "read-0"
        var answerMetadata: [String: Any]? = nil
    }
    func raw(_ w: Wire) -> [[String: Any]] {
        var answerMessage: [String: Any] = ["id": "f0", "role": "assistant", "created_at": w.answerStamp,
                                            "content": [["type": "text", "text": w.answer]]]
        if let metadata = w.answerMetadata { answerMessage["metadata"] = metadata }
        return [
            ["id": "u0", "role": "user", "created_at": "000001",
             "content": [["type": "text", "text": "第 0 轮：请检查 ALPHA 实现。"]]],
            ["id": "a0", "role": "assistant", "created_at": "000002", "content": [
                ["type": "thinking", "thinking": "先读取 File0.swift 再决定下一步"],
                ["type": "tool_use", "tool_call_id": w.toolCallID, "tool_name": "Read",
                 "input": ["file_path": "/fixture/Sources/File0.swift", "retries": w.retries]]]],
            ["id": "r0", "role": w.r0Role, "created_at": w.r0Stamp, "content": [
                ["type": "tool_result", "tool_call_id": w.toolCallID, "output": toolOutput, "is_error": false]]],
            answerMessage,
            ["id": "u1", "role": "user", "created_at": "000005",
             "content": [["type": "text", "text": "第 1 轮：继续推进 caf\u{00e9}。"]]],
        ]
    }
    func decoded(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func live(_ tokens: Int, retries: Double = -0.0) throws -> [KimiMessage] {
        // A text tail: thinking parts are not part of an entry's sources, so a
        // thinking tail would leave the latest-turn query without hits to compare.
        // The trailing tool call carries the float input: flipping its zero sign
        // inside the latest turn isolates the per-entry cache from the prefix one.
        try decoded([
            ["id": "live:1", "role": "assistant", "created_at": "",
             "content": [["type": "text",
                          "text": String(repeating: "推理 BETA 段。", count: tokens)]]],
            ["id": "live:2", "role": "assistant", "created_at": "",
             "content": [["type": "tool_use", "tool_call_id": "live-read", "tool_name": "Read",
                          "input": ["file_path": "/fixture/Sources/Live.swift", "retries": retries]]]],
        ])
    }

    let baseWire = Wire(answer: answer)
    let base = try decoded(raw(baseWire))
    // Same byte length, different value: an in-place payload edit.
    let edited = try decoded(raw(Wire(answer: editedAnswer)))
    // The skipped tool-result message's timestamp vs an entry-bearing one's.
    let restamped = try decoded(raw(Wire(answer: answer, r0Stamp: "000009")))
    // Equal by value, different payloads: what a snapshot refresh hands over.
    let rebuilt = try decoded(raw(Wire(answer: answer, r0Stamp: "000009")))
    precondition(restamped == rebuilt, "A window rebuilt from the same wire data is equal by value")
    let older = try decoded([["id": "u-old", "role": "user", "created_at": "000000",
                              "content": [["type": "text", "text": "更早的一轮：ALPHA 之前。"]]]])

    let search = ConversationSearch()
    @discardableResult
    func equalsOracle(_ messages: [KimiMessage], _ query: String, running: Bool,
                      options: ConversationFindOptions = ConversationFindOptions(),
                      _ note: String) -> ConversationFindResult {
        let warm = search.hits(in: messages, query: query, running: running, options: options)
        let oracle = ConversationSearch().hits(in: messages, query: query, running: running, options: options)
        precondition(warm == oracle, "\(note): find results for \(query) must equal a complete search")
        return warm
    }

    var window = base + (try live(1))
    let first = equalsOracle(window, "ALPHA", running: true, "first window")
    precondition(first.hits.count >= 2, "ALPHA appears in the prompt and the answer")
    let signedZero = equalsOracle(window, "-0", running: true, "first window, negative-zero tool input")
    precondition(!signedZero.hits.isEmpty,
                 "the pretty-printed tool input renders the negative zero sign")
    let liveOnly = equalsOracle(window, "BETA", running: true, "first window, latest-turn query")
    precondition(liveOnly.hits.count == 1, "the live tail holds one BETA occurrence")
    precondition(!liveOnly.hits.contains { first.hits.contains($0) },
                 "the latest-turn query hits only the live entry")

    // Growth under an unchanged query: each step's first BETA search follows the
    // previous step's BETA search with only the live messages changed, so cached
    // nonempty hits of the changed entry must be invalidated, not served stale.
    for tokens in 2...6 {
        window = base + (try live(tokens))
        let grown = equalsOracle(window, "BETA", running: true,
                                 "growth under an unchanged query, token \(tokens)")
        precondition(grown.hits.count == tokens,
                     "the grown live entry re-searches to \(tokens) occurrences")
        equalsOracle(window, "ALPHA", running: true, "token \(tokens)")
        equalsOracle(window, "BETA", running: true, "token \(tokens), back to the latest-turn query")
    }
    // Query switches must never answer from another query's cache.
    equalsOracle(window, "File0.swift", running: true, "query switch to a tool input")
    equalsOracle(window, "retries", running: true, "query switch to the numeric input key")
    equalsOracle(window, "第 1 轮", running: true, "query switch to CJK")
    equalsOracle(window, "ALPHA", running: true, "query switch back")
    // Option switches: case sensitivity, regex, role filter.
    var caseSensitive = ConversationFindOptions()
    caseSensitive.caseSensitive = true
    let insensitive = equalsOracle(window, "alpha", running: true, "case-insensitive lowercase query")
    let sensitive = equalsOracle(window, "alpha", running: true, options: caseSensitive,
                                 "case-sensitive lowercase query")
    precondition(insensitive.hits.count >= 2 && sensitive.hits.isEmpty,
                 "case folding happens only with the case-insensitive option")
    var regex = ConversationFindOptions()
    regex.regex = true
    let pattern = equalsOracle(window, "AL+PHA", running: true, options: regex, "regex query")
    precondition(pattern.hits.count == insensitive.hits.count,
                 "the case-insensitive regex matches exactly the folded literal occurrences")
    equalsOracle(window, "AL+PHA", running: true, "the same pattern as a literal query")
    var userOnly = ConversationFindOptions()
    userOnly.role = .user
    equalsOracle(window, "ALPHA", running: true, options: userOnly, "user-role filter")
    var assistantOnly = ConversationFindOptions()
    assistantOnly.role = .assistant
    equalsOracle(window, "ALPHA", running: true, options: assistantOnly, "assistant-role filter")
    equalsOracle(window, "ALPHA", running: true, "role filter back to all")

    // A prefix tool input's zero sign, with the SAME query immediately before
    // and after the flip so both reuse tiers face the transition: -0.0 == 0.0
    // as values, but the rendering keeps the sign. On the matched baseline this
    // is the first failing transition — round 8's Earlier reuse accepts the
    // value-equal window and serves the stale "-0" prefix hits.
    window = base + (try live(6))
    equalsOracle(window, "-0", running: true, "negative zero, before the prefix flip")
    window = (try decoded(raw(Wire(answer: answer, retries: 0.0)))) + (try live(7, retries: 0.0))
    let flipped = equalsOracle(window, "-0", running: true,
                               "tool input zero sign flip under an unchanged query")
    precondition(flipped.hits.isEmpty, "the flipped input renders without the minus sign")
    equalsOracle(window, "retries", running: true, "the flipped input still renders its key")
    equalsOracle(window, "ALPHA", running: true, "zero sign flip, unrelated query")
    // The same flip confined to the latest turn isolates the per-entry cache:
    // the prefix stays byte-identical (its reused hits must survive), only the
    // live tool entry's rendered input changes (its cached hits must not).
    window = base + (try live(8))
    let beforeLive = equalsOracle(window, "-0", running: true,
                                  "negative zero, before the latest-turn flip")
    precondition(beforeLive.hits.contains { $0.entryID == "activity:tool:live-read" },
                 "the live tool entry holds a negative-zero hit before the flip")
    window = base + (try live(8, retries: 0.0))
    let afterLive = equalsOracle(window, "-0", running: true,
                                 "latest-turn zero sign flip under an unchanged query")
    precondition(!afterLive.hits.contains { $0.entryID == "activity:tool:live-read" },
                 "the flipped live tool entry's cached hits must not survive")
    // The prefix a0 entry merges its thinking and tool phases, so its id
    // anchors on the first message: "thinking:a0:0".
    precondition(afterLive.hits.contains { $0.entryID == "thinking:a0:0" },
                 "the byte-identical prefix keeps its reused negative-zero hit")

    // A timestamp edit on a message an entry bears (isolated: nothing else changes).
    window = (try decoded(raw(Wire(answer: answer, answerStamp: "000006")))) + (try live(8))
    equalsOracle(window, "ALPHA", running: true, "in-entry timestamp edited in place")
    // A metadata-only edit: metadata never renders into sources.
    window = (try decoded(raw(Wire(answer: answer, answerMetadata: ["annotations": ["state": "kept"]]))))
        + (try live(9))
    equalsOracle(window, "ALPHA", running: true, "metadata-only edit")
    // A role flip on the tool-result message the timeline skips.
    window = (try decoded(raw(Wire(answer: answer, r0Role: "user")))) + (try live(10))
    equalsOracle(window, "ALPHA", running: true, "skipped tool-result role flip")
    // A rerouted tool call id must reach the hit's tool routing.
    window = (try decoded(raw(Wire(answer: answer, toolCallID: "read-9")))) + (try live(11))
    let rerouted = equalsOracle(window, "File0.swift", running: true, "tool call id rerouted")
    precondition(rerouted.hits.first?.toolID == "read-9",
                 "hit tool routing follows the rerouted call id")
    window = base + (try live(11))
    let restoredRoute = equalsOracle(window, "File0.swift", running: true, "tool call id restored")
    precondition(restoredRoute.hits.first?.toolID == "read-0",
                 "hit tool routing follows the restored call id")

    // Canonically equal queries are different search keys: a regex pattern is
    // syntax, and an NFC/NFD pair matches differently. Both the prefix-level
    // (Earlier) and the per-entry caches must key on the exact encoding.
    let nfc = "caf\u{00e9}"
    let nfd = "cafe\u{0301}"
    precondition(nfc == nfd && !nfc.utf8.elementsEqual(nfd.utf8),
                 "canonical equality must not imply encoding equality")
    var regexKey = ConversationFindOptions()
    regexKey.regex = true
    let composed = equalsOracle(window, nfc, running: true, options: regexKey, "regex NFC query")
    precondition(!composed.hits.isEmpty, "the precomposed pattern matches the precomposed fixture text")
    let decomposed = equalsOracle(window, nfd, running: true, options: regexKey,
                                  "regex NFD query after the canonically equal NFC query")
    precondition(decomposed.hits.isEmpty, "the decomposed pattern must not match the precomposed text")
    equalsOracle(window, nfc, running: true, options: regexKey, "regex NFC query again after the NFD query")
    var literalKey = ConversationFindOptions()
    literalKey.caseSensitive = true
    equalsOracle(window, nfc, running: true, options: literalKey, "literal NFC query, case sensitive")
    equalsOracle(window, nfd, running: true, options: literalKey,
                 "literal NFD query after the canonically equal NFC query")
    equalsOracle(window, nfc, running: true, options: literalKey, "literal NFC query again")
    equalsOracle(window, "ALPHA", running: true, "default query after the encoding-key transitions")

    // Running flips rebuild the latest turn's entries under the other flag.
    equalsOracle(window, "ALPHA", running: false, "running flip off")
    equalsOracle(window, "BETA", running: false, "running flip off, latest-turn query")
    equalsOracle(window, "ALPHA", running: true, "running flip on")
    // An in-place payload edit of the same byte length ends every reuse.
    window = edited + (try live(12))
    equalsOracle(window, "ALPHA", running: true, "answer edited in place")
    equalsOracle(window, "ALPHB", running: true, "the edited value is searchable")
    window = edited + (try live(13))
    equalsOracle(window, "ALPHA", running: true, "token after the answer edit")
    // A timestamp edit on the skipped tool-result message.
    window = restamped + (try live(14))
    equalsOracle(window, "ALPHA", running: true, "skipped-message timestamp edited in place")
    // A rebuilt window is value-equal with different payloads: reuse survives
    // because identical wire bytes render identically.
    window = rebuilt + (try live(15))
    equalsOracle(window, "ALPHA", running: true, "window rebuilt from the same wire data")
    equalsOracle(window, "BETA", running: true, "rebuilt window, latest-turn query")
    window = rebuilt + (try live(16))
    equalsOracle(window, "ALPHA", running: true, "token after the rebuild")
    // A prepended page moves the split and grows the cached earlier window.
    window = older + rebuilt + (try live(17))
    equalsOracle(window, "ALPHA", running: true, "older page prepended")
    equalsOracle(window, "更早的一轮", running: true, "the prepended page is searchable")
    window = older + rebuilt + (try live(18))
    equalsOracle(window, "ALPHA", running: true, "token after the page")
    equalsOracle(window, "BETA", running: true, "token after the page, latest-turn query")
    print("PASS: find-bar entry reuse equals a complete search across growth, payload edits, zero-sign and encoding flips, reroutes, rebuilds, pages, running flips and query/option switches")
}
