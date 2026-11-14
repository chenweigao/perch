import Foundation
import WorkbenchCore

/// Shared fixtures for the two find-bar reuse checks below.
///
/// The window: a completed turn (prompt u0, an assistant a0 with a thought and
/// a Read call whose input carries a float and a non-ASCII key, a tool result
/// r0 that timeline construction skips, an answer f0 containing "ALPHA" and a
/// precomposed "café"), a second prompt u1, and a growing live text tail whose
/// own tool call carries the same float input. Queries are chosen so hits land
/// in prefix entries, latest-turn entries and tool-routed entries.
private enum SearchReuseFixtures {
    struct Wire {
        var answer: String
        var answerStamp = "000004"
        var r0Stamp = "000003"
        var r0Role = "tool"
        var retries = -0.0
        var toolCallID = "read-0"
        var noteKey = "cl\u{00e9}"
        var answerMetadata: [String: Any]? = nil
    }
    static let prose = String(repeating: "这一轮的说明包含 English identifiers 与中文混排，长到不会内联进字符串。", count: 3)
    static let toolOutput = (0..<40).map { "\($0)\tlet value\($0) = compute(\($0)) // 源代码行" }.joined(separator: "\n")
    static let answer = "第 0 轮完成，ALPHA 已经处理：\(prose) caf\u{00e9}。"
    static let editedAnswer = answer.replacingOccurrences(of: "ALPHA", with: "ALPHB")
    static let baseWire = Wire(answer: answer)

    static func raw(_ w: Wire) -> [[String: Any]] {
        var answerMessage: [String: Any] = ["id": "f0", "role": "assistant", "created_at": w.answerStamp,
                                            "content": [["type": "text", "text": w.answer]]]
        if let metadata = w.answerMetadata { answerMessage["metadata"] = metadata }
        return [
            ["id": "u0", "role": "user", "created_at": "000001",
             "content": [["type": "text", "text": "第 0 轮：请检查 ALPHA 实现。"]]],
            ["id": "a0", "role": "assistant", "created_at": "000002", "content": [
                ["type": "thinking", "thinking": "先读取 File0.swift 再决定下一步"],
                ["type": "tool_use", "tool_call_id": w.toolCallID, "tool_name": "Read",
                 "input": ["file_path": "/fixture/Sources/File0.swift", w.noteKey: 1, "retries": w.retries]]]],
            ["id": "r0", "role": w.r0Role, "created_at": w.r0Stamp, "content": [
                ["type": "tool_result", "tool_call_id": w.toolCallID, "output": toolOutput, "is_error": false]]],
            answerMessage,
            ["id": "u1", "role": "user", "created_at": "000005",
             "content": [["type": "text", "text": "第 1 轮：继续推进 caf\u{00e9}。"]]],
        ]
    }
    static func decoded(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    /// A text tail: thinking parts are not part of an entry's sources, so a
    /// thinking tail would leave the latest-turn query without hits to compare.
    /// The trailing tool call carries the float input so its zero sign can flip
    /// inside the latest turn alone.
    static func live(_ tokens: Int, retries: Double = -0.0) throws -> [KimiMessage] {
        try decoded([
            ["id": "live:1", "role": "assistant", "created_at": "",
             "content": [["type": "text",
                          "text": String(repeating: "推理 BETA 段。", count: tokens)]]],
            ["id": "live:2", "role": "assistant", "created_at": "",
             "content": [["type": "tool_use", "tool_call_id": "live-read", "tool_name": "Read",
                          "input": ["file_path": "/fixture/Sources/Live.swift", "retries": retries]]]],
        ])
    }
}

/// Round 12's find-bar result reuse must be invisible: every warm-instance call
/// equals a fresh instance's complete search. The matrix covers token growth
/// under both a changing and a FIXED query (each growth step's first BETA
/// search follows the previous step's BETA with only the live messages changed,
/// so cached nonempty hits of the changed entry must invalidate), query
/// switches, case/regex/role option switches, isolated single-field payload
/// mutations — each sandwiched between same-query calls on the unmutated and
/// the mutated window so message validation, not query invalidation, faces the
/// transition — a latest-turn-only zero-sign flip that pins per-entry
/// invalidation while the byte-identical prefix keeps its reused hits,
/// same-byte-length answer edits, value-equal rebuilt windows, prepended pages
/// and running-flag flips.
///
/// Every step of this matrix passes on the UNOPTIMIZED matched baseline (the
/// old code recomputes or reuses only where value equality was already sound);
/// the transitions that fail on the baseline by design live in the separate
/// checkSearchCacheHoleProbes so one baseline run records all of them.
func checkSearchEntryReuse() throws {
    let F = SearchReuseFixtures.self
    precondition(F.answer.utf8.count == F.editedAnswer.utf8.count,
                 "The in-place edit keeps the answer's byte length")
    let base = try F.decoded(F.raw(F.baseWire))
    let older = try F.decoded([["id": "u-old", "role": "user", "created_at": "000000",
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
    /// One field differs from the base wire; the same query runs on the base
    /// window immediately before and on the mutated window immediately after.
    @discardableResult
    func isolatedMutation(_ mutate: (inout SearchReuseFixtures.Wire) -> Void,
                          query: String, tokens: Int = 9,
                          options: ConversationFindOptions = ConversationFindOptions(),
                          _ note: String,
                          verify: ((ConversationFindResult) throws -> Void)? = nil) throws -> ConversationFindResult {
        var wire = F.baseWire
        mutate(&wire)
        equalsOracle(base + (try F.live(tokens)), query, running: true, options: options, "\(note), before")
        let result = equalsOracle((try F.decoded(F.raw(wire))) + (try F.live(tokens)),
                                  query, running: true, options: options, note)
        try verify?(result)
        return result
    }

    var window = base + (try F.live(1))
    let first = equalsOracle(window, "ALPHA", running: true, "first window")
    precondition(first.hits.count >= 2, "ALPHA appears in the prompt and the answer")
    let signedZero = equalsOracle(window, "-0", running: true, "first window, negative-zero tool input")
    precondition(!signedZero.hits.isEmpty,
                 "the pretty-printed tool input renders the negative zero sign")
    let liveOnly = equalsOracle(window, "BETA", running: true, "first window, latest-turn query")
    precondition(liveOnly.hits.count == 1, "the live tail holds one BETA occurrence")
    precondition(!liveOnly.hits.contains { first.hits.contains($0) },
                 "the latest-turn query hits only the live entry")

    // Growth under an unchanged query first in every step.
    for tokens in 2...6 {
        window = base + (try F.live(tokens))
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
    equalsOracle(window, "cl\u{00e9}", running: true, "query switch to the non-ASCII input key")
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

    // Isolated single-field payload mutations under an unchanged query.
    try isolatedMutation({ $0.answerStamp = "000006" }, query: "ALPHA",
                         "in-entry timestamp edited in place")
    try isolatedMutation({ $0.answerMetadata = ["annotations": ["state": "kept"]] }, query: "ALPHA",
                         "metadata-only edit")
    try isolatedMutation({ $0.r0Role = "user" }, query: "ALPHA",
                         "skipped tool-result role flip")
    try isolatedMutation({ $0.r0Stamp = "000009" }, query: "ALPHA",
                         "skipped-message timestamp edited in place")
    try isolatedMutation({ $0.toolCallID = "read-9" }, query: "File0.swift",
                         "tool call id rerouted") { result in
        precondition(result.hits.first?.toolID == "read-9",
                     "hit tool routing follows the rerouted call id")
    }
    try isolatedMutation({ $0.answer = F.editedAnswer }, query: "ALPHA",
                         "answer edited in place at the same byte length") { result in
        precondition(result.hits.count == 1, "only the prompt keeps the pre-edit spelling")
    }
    try isolatedMutation({ $0.answer = F.editedAnswer }, query: "ALPHB",
                         "the edited value is searchable")

    // A latest-turn-only zero-sign flip: the prefix stays byte-identical (its
    // reused hits must survive), only the live tool entry's rendered input
    // changes (its cached nonempty hits must not). Passes on the baseline: the
    // old per-call recompute and the old sources comparison both handle it.
    window = base + (try F.live(8))
    let beforeLive = equalsOracle(window, "-0", running: true,
                                  "negative zero, before the latest-turn flip")
    precondition(beforeLive.hits.contains { $0.entryID == "activity:tool:live-read" },
                 "the live tool entry holds a negative-zero hit before the flip")
    window = base + (try F.live(8, retries: 0.0))
    let afterLive = equalsOracle(window, "-0", running: true,
                                 "latest-turn zero sign flip under an unchanged query")
    precondition(!afterLive.hits.contains { $0.entryID == "activity:tool:live-read" },
                 "the flipped live tool entry's cached hits must not survive")
    // The prefix a0 entry merges its thinking and tool phases, so its id
    // anchors on the first message: "thinking:a0:0".
    precondition(afterLive.hits.contains { $0.entryID == "thinking:a0:0" },
                 "the byte-identical prefix keeps its reused negative-zero hit")

    // Running flips rebuild the latest turn's entries under the other flag.
    equalsOracle(window, "ALPHA", running: false, "running flip off")
    equalsOracle(window, "BETA", running: false, "running flip off, latest-turn query")
    equalsOracle(window, "ALPHA", running: true, "running flip on")
    window = base + (try F.live(10))
    equalsOracle(window, "ALPHA", running: true, "growth after the flips")
    // A rebuilt window is value-equal with different payloads: reuse survives
    // because identical wire bytes render identically.
    let restamped = try F.decoded(F.raw(SearchReuseFixtures.Wire(answer: F.answer, r0Stamp: "000009")))
    let rebuilt = try F.decoded(F.raw(SearchReuseFixtures.Wire(answer: F.answer, r0Stamp: "000009")))
    precondition(restamped == rebuilt, "A window rebuilt from the same wire data is equal by value")
    window = rebuilt + (try F.live(11))
    equalsOracle(window, "ALPHA", running: true, "window rebuilt from the same wire data")
    equalsOracle(window, "BETA", running: true, "rebuilt window, latest-turn query")
    window = rebuilt + (try F.live(12))
    equalsOracle(window, "ALPHA", running: true, "token after the rebuild")
    // A prepended page moves the split and grows the cached earlier window.
    window = older + rebuilt + (try F.live(13))
    equalsOracle(window, "ALPHA", running: true, "older page prepended")
    equalsOracle(window, "更早的一轮", running: true, "the prepended page is searchable")
    window = older + rebuilt + (try F.live(14))
    equalsOracle(window, "ALPHA", running: true, "token after the page")
    equalsOracle(window, "BETA", running: true, "token after the page, latest-turn query")
    print("PASS: find-bar entry reuse equals a complete search across growth, isolated payload edits, reroutes, rebuilds, pages, running flips and query/option switches")
}

/// The transitions on which the UNOPTIMIZED matched baseline fails by design —
/// the pre-existing find-bar cache holes this round closes. They are separated
/// from the matrix so one baseline run records every hole instead of stopping
/// at the first: each probe runs on its own warm instance, prints its own
/// PROBE PASS/MISMATCH line, and only the terminal precondition ends the run.
///
///   P1 prefix zero-sign flip: -0.0 == 0.0 as values while `display` renders
///      the sign — round 8's Earlier reuse serves stale "-0" prefix hits.
///   P2 NFD regex query after the canonically equal NFC query: round 8's
///      Earlier compares queries with `==` and serves the NFC prefix hits.
///   P3 payload NFC→NFD swap under an unchanged NFC regex query: the
///      sources-equality text cache compares canonically and keeps searching
///      the stale NFC rendering.
///   P4 object-key NFC→NFD swap under an unchanged NFC regex query: same
///      fallback, through the rendered input key.
///
/// The candidate passes all four; the baseline is expected to print four
/// MISMATCH lines and then fail the terminal precondition.
func checkSearchCacheHoleProbes() throws {
    let F = SearchReuseFixtures.self
    var failures: [String] = []
    func probe(_ name: String, _ sequence: (ConversationSearch) throws -> (warm: ConversationFindResult,
                                                                           oracle: ConversationFindResult,
                                                                           sound: Bool)) {
        do {
            let (warm, oracle, sound) = try sequence(ConversationSearch())
            if warm == oracle && sound {
                print("PROBE PASS: \(name)")
            } else {
                failures.append(name)
                print("PROBE MISMATCH (stale-cache hole): \(name): warm \(warm.hits.count) hits vs oracle \(oracle.hits.count) hits, sound=\(sound)")
            }
        } catch {
            failures.append(name)
            print("PROBE MISMATCH (error): \(name)")
        }
    }

    let base = try F.decoded(F.raw(F.baseWire))

    // P1: the prefix float's zero sign flips under an unchanged "-0" query.
    var zeroWire = F.baseWire
    zeroWire.retries = 0.0
    let zeroed = try F.decoded(F.raw(zeroWire))
    probe("prefix zero-sign flip under an unchanged query") { search in
        let before = base + (try F.live(6))
        _ = search.hits(in: before, query: "-0", running: true)
        let after = zeroed + (try F.live(7, retries: 0.0))
        let warm = search.hits(in: after, query: "-0", running: true)
        let oracle = ConversationSearch().hits(in: after, query: "-0", running: true)
        return (warm, oracle, oracle.hits.isEmpty)
    }

    // P2: the NFD regex pattern after the canonically equal NFC pattern.
    let nfc = "caf\u{00e9}"
    let nfd = "cafe\u{0301}"
    precondition(nfc == nfd && !nfc.utf8.elementsEqual(nfd.utf8),
                 "canonical equality must not imply encoding equality")
    var regexKey = ConversationFindOptions()
    regexKey.regex = true
    probe("NFD regex query after the canonically equal NFC query") { search in
        let window = base + (try F.live(6))
        _ = search.hits(in: window, query: nfc, running: true, options: regexKey)
        let warm = search.hits(in: window, query: nfd, running: true, options: regexKey)
        let oracle = ConversationSearch().hits(in: window, query: nfd, running: true, options: regexKey)
        return (warm, oracle, oracle.hits.isEmpty)
    }

    // P3: the answer payload swaps to its NFD spelling under an unchanged
    // NFC regex query (u1's NFC café keeps the oracle nonempty).
    let answerNFD = F.answer.replacingOccurrences(of: "caf\u{00e9}", with: "cafe\u{0301}")
    precondition(answerNFD == F.answer, "the payload swap stays canonically equal")
    var nfdWire = F.baseWire
    nfdWire.answer = answerNFD
    let nfdPayload = try F.decoded(F.raw(nfdWire))
    probe("payload NFC to NFD swap under an unchanged regex query") { search in
        let window = base + (try F.live(6))
        _ = search.hits(in: window, query: nfc, running: true, options: regexKey)
        let swapped = nfdPayload + (try F.live(6))
        let warm = search.hits(in: swapped, query: nfc, running: true, options: regexKey)
        let oracle = ConversationSearch().hits(in: swapped, query: nfc, running: true, options: regexKey)
        return (warm, oracle, !oracle.hits.contains { $0.entryID == "text:f0:0" })
    }

    // P4: the tool input's object key swaps to its NFD spelling under an
    // unchanged NFC regex query.
    var keyWire = F.baseWire
    keyWire.noteKey = "cle\u{0301}"
    let keySwapped = try F.decoded(F.raw(keyWire))
    probe("object-key NFC to NFD swap under an unchanged regex query") { search in
        let window = base + (try F.live(6))
        _ = search.hits(in: window, query: "cl\u{00e9}", running: true, options: regexKey)
        let swapped = keySwapped + (try F.live(6))
        let warm = search.hits(in: swapped, query: "cl\u{00e9}", running: true, options: regexKey)
        let oracle = ConversationSearch().hits(in: swapped, query: "cl\u{00e9}", running: true, options: regexKey)
        return (warm, oracle, oracle.hits.isEmpty)
    }

    precondition(failures.isEmpty,
                 "find-bar cache-hole probes served stale hits: \(failures.joined(separator: ", "))")
    print("PASS: find-bar cache-hole probes (prefix zero sign, query encoding, payload encoding, key encoding) equal complete searches")
}
