import Foundation
import WorkbenchCore

/// Round 12's per-entry find-result reuse must be invisible: every warm-instance
/// call equals a fresh instance's complete search across token growth, in-place
/// payload edits of the same byte length, timestamp edits, windows rebuilt from
/// the same wire data, prepended pages, running-flag flips and query, regex,
/// case-sensitivity and role-filter switches. Reuse may engage only under
/// identical (messages, isRunning, query, options); every difference must take
/// the complete path the fresh oracle represents. Whether reuse engages is
/// measured by the A/B find-bar metric, not asserted here, so the matched
/// baseline (unoptimized product, same tests) compiles and passes this walk.
func checkSearchEntryReuse() throws {
    let prose = String(repeating: "这一轮的说明包含 English identifiers 与中文混排，长到不会内联进字符串。", count: 3)
    let toolOutput = (0..<40).map { "\($0)\tlet value\($0) = compute(\($0)) // 源代码行" }.joined(separator: "\n")
    func wire(answer: String, stamp: String) -> [[String: Any]] {
        [
            ["id": "u0", "role": "user", "created_at": "000001",
             "content": [["type": "text", "text": "第 0 轮：请检查 ALPHA 实现。"]]],
            ["id": "a0", "role": "assistant", "created_at": "000002", "content": [
                ["type": "thinking", "thinking": "先读取 File0.swift 再决定下一步"],
                ["type": "tool_use", "tool_call_id": "read-0", "tool_name": "Read",
                 "input": ["file_path": "/fixture/Sources/File0.swift"]]]],
            ["id": "r0", "role": "tool", "created_at": stamp, "content": [
                ["type": "tool_result", "tool_call_id": "read-0", "output": toolOutput, "is_error": false]]],
            ["id": "f0", "role": "assistant", "created_at": "000004",
             "content": [["type": "text", "text": answer]]],
            ["id": "u1", "role": "user", "created_at": "000005",
             "content": [["type": "text", "text": "第 1 轮：继续推进 caf\u{00e9}。"]]],
        ]
    }
    func decoded(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func live(_ tokens: Int) throws -> [KimiMessage] {
        // A text tail: thinking parts are not part of an entry's sources, so a
        // thinking tail would leave the latest-turn query without hits to compare.
        try decoded([["id": "live:1", "role": "assistant", "created_at": "",
                      "content": [["type": "text",
                                   "text": String(repeating: "推理 BETA 段。", count: tokens)]]]])
    }
    let answer = "第 0 轮完成，ALPHA 已经处理：\(prose) caf\u{00e9}。"
    let editedAnswer = answer.replacingOccurrences(of: "ALPHA", with: "ALPHB")
    precondition(answer.utf8.count == editedAnswer.utf8.count,
                 "The in-place edit keeps the answer's byte length")
    let base = try decoded(wire(answer: answer, stamp: "000003"))
    let edited = try decoded(wire(answer: editedAnswer, stamp: "000003"))
    let restamped = try decoded(wire(answer: answer, stamp: "000009"))
    // Equal by value, different payloads: what a snapshot refresh hands over.
    let rebuilt = try decoded(wire(answer: answer, stamp: "000009"))
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
    let liveOnly = equalsOracle(window, "BETA", running: true, "first window, latest-turn query")
    precondition(!liveOnly.hits.isEmpty, "the growing live tail must stay searchable")
    precondition(!liveOnly.hits.contains { first.hits.contains($0) },
                 "the latest-turn query hits only the live entry")
    for tokens in 2...6 {
        window = base + (try live(tokens))
        equalsOracle(window, "ALPHA", running: true, "token \(tokens)")
        equalsOracle(window, "BETA", running: true, "token \(tokens), latest-turn query")
    }
    // Query switches must never answer from another query's cache.
    equalsOracle(window, "File0.swift", running: true, "query switch to a tool input")
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
    // Canonically equal queries are different search keys: a regex pattern is
    // syntax, and an NFC/NFD pair matches differently. Both the prefix-level
    // (Earlier) and the per-entry caches must key on the exact encoding. On the
    // unoptimized matched baseline this transition fails by design: its
    // pre-existing Earlier cache compares queries canonically and serves the
    // NFC query's prefix hits to the NFD query.
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
    window = edited + (try live(7))
    equalsOracle(window, "ALPHA", running: true, "answer edited in place")
    equalsOracle(window, "ALPHB", running: true, "the edited value is searchable")
    window = edited + (try live(8))
    equalsOracle(window, "ALPHA", running: true, "token after the answer edit")
    window = restamped + (try live(9))
    equalsOracle(window, "ALPHA", running: true, "timestamp edited in place")
    // A rebuilt window is value-equal with different payloads: reuse survives.
    window = rebuilt + (try live(10))
    equalsOracle(window, "ALPHA", running: true, "window rebuilt from the same wire data")
    window = rebuilt + (try live(11))
    equalsOracle(window, "ALPHA", running: true, "token after the rebuild")
    equalsOracle(window, "BETA", running: true, "token after the rebuild, latest-turn query")
    // A prepended page moves the split and grows the cached earlier window.
    window = older + rebuilt + (try live(12))
    equalsOracle(window, "ALPHA", running: true, "older page prepended")
    equalsOracle(window, "更早的一轮", running: true, "the prepended page is searchable")
    window = older + rebuilt + (try live(13))
    equalsOracle(window, "ALPHA", running: true, "token after the page")
    equalsOracle(window, "BETA", running: true, "token after the page, latest-turn query")
    print("PASS: find-bar entry reuse equals a complete search across growth, edits, rebuilds, pages, running flips and query/option switches")
}
