import Foundation
import WorkbenchCore

/// Pins the round-35 prepend-aware incremental global indexes (the
/// ToolVisibilityProjection owner/identity caches and the History
/// entry-turns dictionary with its relative turn base).
///
/// Method: differential equality against the living reference — a FRESH
/// ConversationPresentationModel takes the full-rebuild path on every
/// update (empty caches), while a WARM model carries the incremental
/// state across the sequence. Every step feeds both models the identical
/// input and requires identical rows, navigation, narrative key and both
/// fold shapes, plus narrative-overlay presentations (the overlay path
/// reads History.entryTurns — a wrong relative base attaches overlays to
/// the wrong turns).
///
/// Scenario coverage: pure full-turn prepends; a page boundary splitting a
/// turn and the next page MERGING it back (the path that consumes one
/// cached leading turn in both structures); a REMEMBERED live tool whose
/// dangling call lives in a completed turn (its observedByTurn placement
/// reads owner[id] + base — a wrong base shift changes the tool's rendered
/// status); interior edits forcing chunk rebuilds; turn-boundary growth;
/// connection flips; language resets; trailing streaming deltas. A final
/// poisoning phase on a second warm model covers the whole-window rejection
/// routes: a prepended page duplicating an existing tool identity, a page
/// with duplicate message ids, and a live tool anchored to the current
/// prompt whose call sits in the prefix (separates() rejection) — after
/// these, the chunk path stays disabled for the session, so they run last.
func checkPrependIncremental() throws {
    func decode(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func liveTool(_ id: String, _ name: String = "Read") throws -> KimiLiveTool {
        try KimiWire.decoder().decode(KimiLiveTool.self, from: JSONSerialization.data(withJSONObject: [
            "tool_call_id": id, "name": name, "args": ["file_path": "/repo/live.swift"],
        ]))
    }
    /// One completed turn: prompt, an assistant reply with `tools` calls, and
    /// their results — raw wire rows so pages can be sliced anywhere.
    func turnRaw(_ tag: String, tools: Int = 2) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "text", "text": "结论 \(tag)：处理完成。"]]
        for k in 0..<tools {
            content.append(["type": "tool_use", "tool_call_id": "call-\(tag)-\(k)",
                            "tool_name": "Read", "input": ["file_path": "/repo/\(tag)-\(k).swift"]])
        }
        var rows: [[String: Any]] = [
            ["id": "u-\(tag)", "role": "user", "created_at": "1",
             "content": [["type": "text", "text": "第 \(tag) 轮：请推进。"]]],
            ["id": "a-\(tag)", "role": "assistant", "created_at": "2", "content": content],
        ]
        for k in 0..<tools {
            rows.append(["id": "r-\(tag)-\(k)", "role": "tool", "created_at": "3",
                         "content": [["type": "tool_result", "tool_call_id": "call-\(tag)-\(k)",
                                      "is_error": false, "output": "ok \(tag)-\(k)"]]])
        }
        return rows
    }

    // The trailing live turn carries a DANGLING tool call (no result) that
    // stays live across the whole phase: once a turn boundary completes its
    // turn, the tool becomes a remembered live tool of an earlier turn —
    // observedByTurn then reads owner[call-LIVE-T] + base, making the
    // relative-base arithmetic observable in the rendered tool status.
    var baseRaw = (0..<5).flatMap { turnRaw("A\($0)") }
    baseRaw.append(["id": "u-live", "role": "user", "created_at": "4",
                    "content": [["type": "text", "text": "当前轮：正在进行。"]]])
    baseRaw.append(["id": "a-live", "role": "assistant", "created_at": "5",
                    "content": [["type": "thinking", "thinking": "推进中……"],
                                ["type": "tool_use", "tool_call_id": "call-LIVE-T",
                                 "tool_name": "Bash", "input": ["command": "swift build"]]]])
    let rememberedLive = try liveTool("call-LIVE-T", "Bash")

    let pageFull = (0..<3).flatMap { turnRaw("B\($0)") }        // three whole older turns
    let pageC = (0..<2).flatMap { turnRaw("C\($0)", tools: 3) } // split across two pages
    // turnRaw(C0, tools: 3) is 5 messages (prompt, assistant, 3 results), so
    // index 3 splits turn C0 itself: the back page carries a leading PARTIAL
    // turn (two orphan results) that the front page later MERGES back.
    let splitAt = 3

    let warm = ConversationPresentationModel(key: "s")
    var window = try decode(baseRaw)
    var step = 0
    func compare(_ label: String, live: [KimiLiveTool] = [rememberedLive],
                 running: Set<String> = ["call-LIVE-T"],
                 online: Bool = true, language: String = "zh") throws {
        step += 1
        let input = ConversationPresentationModel.Input(messages: window, live: live, running: running,
                                                        isRunning: true, online: online, epoch: "bench",
                                                        language: language)
        let fresh = ConversationPresentationModel(key: "s")
        let w = warm.update(input)
        let f = fresh.update(input)
        precondition(w.rows == f.rows, "step \(step) (\(label)): rows diverged between incremental and full rebuild")
        precondition(w.navigation == f.navigation, "step \(step) (\(label)): navigation diverged")
        precondition(w.narrativeKey == f.narrativeKey, "step \(step) (\(label)): narrative key diverged")
        precondition(w.presented(activity: [:], foldsProcess: true, isRunning: true)
                     == f.presented(activity: [:], foldsProcess: true, isRunning: true),
                     "step \(step) (\(label)): folded presentation diverged")
        precondition(w.presented(activity: [:], foldsProcess: false, isRunning: true)
                     == f.presented(activity: [:], foldsProcess: false, isRunning: true),
                     "step \(step) (\(label)): unfolded presentation diverged")
        // Narrative overlays exercise History.entryTurns (the byTurn grouping
        // reads it): a wrong relative turn base attaches overlays to the
        // wrong turns and diverges here.
        // ALL row ids: a stale entryTurns mapping (e.g. a consumed turn's
        // entries left behind) misplaces overlays on the merged turn's rows.
        let overlayIDs = w.rows.map(\.entry.id)
        var overlay: [String: ActivityNarrativeRow] = [:]
        for id in overlayIDs {
            overlay[id] = ActivityNarrativeRow(narrative: .init(turnID: "u", stageID: "external-\(id)",
                                                                phase: .editing, headline: "外部摘要",
                                                                source: .commentary, lifecycle: .streaming),
                                               isAnchor: false, stageClosed: false)
        }
        precondition(w.presented(activity: overlay, foldsProcess: true, isRunning: true)
                     == f.presented(activity: overlay, foldsProcess: true, isRunning: true),
                     "step \(step) (\(label)): overlay presentation diverged (entryTurns indexing)")
        precondition(!w.rows.isEmpty, "step \(step) (\(label)): fixture must produce rows")
    }

    // 1. baseline, then pure full-turn prepends (the plain incremental path)
    try compare("baseline")
    window = try decode(pageFull) + window
    try compare("prepend-full-page")
    window = try decode(turnRaw("B3")) + window
    try compare("prepend-single-turn")

    // 2. page-split partial turn, then the completing page: the MERGE case
    // (the cached leading turn is consumed into a rebuilt one)
    window = try decode(Array(pageC[splitAt...])) + window
    try compare("prepend-partial-turn")
    window = try decode(Array(pageC[..<splitAt])) + window
    try compare("prepend-completes-merged-turn")

    // 3. interior edit (same id, changed text) then another prepend:
    // the edited turn's chunk must rebuild, dropping to the full path
    var edited = window
    if let index = edited.firstIndex(where: { $0.id == "a-A0" }) {
        edited[index] = try decode([["id": "a-A0", "role": "assistant", "created_at": "2",
                                     "content": [["type": "text", "text": "结论 A0：已改写。"]]]])[0]
    } else {
        fatalError("fixture: a-A0 must be present")
    }
    window = edited
    try compare("interior-edit")
    window = try decode(turnRaw("E0")) + window
    try compare("prepend-after-edit")

    // 4. turn boundary: the live turn completes, call-LIVE-T becomes a
    // remembered live tool of an earlier turn; the next prepends then run
    // the incremental path WITH observedByTurn reading owner + base.
    window += try decode([["id": "u-live2", "role": "user", "created_at": "6",
                           "content": [["type": "text", "text": "新一轮：继续。"]]],
                          ["id": "a-live2", "role": "assistant", "created_at": "7",
                           "content": [["type": "thinking", "thinking": "思考中……"]]]])
    try compare("turn-boundary-growth")
    window = try decode(turnRaw("F0", tools: 1)) + window
    try compare("prepend-with-remembered-live")
    window = try decode(turnRaw("F1")) + window
    try compare("prepend-again-with-remembered-live")

    // 5. connection flip + prepend (chunk reuse breaks; caches must reset consistently)
    try compare("offline", online: false)
    window = try decode(turnRaw("H0")) + window
    try compare("prepend-offline", online: false)
    try compare("back-online")

    // 6. language change (discardPrefix) then prepend
    try compare("language-en", language: "en")
    window = try decode(turnRaw("I0")) + window
    try compare("prepend-after-language-change", language: "en")

    // 7. a live tool whose call AND result are recorded in history (owner
    // lookup with a redundant observed state) + prepend
    let historicLive = "call-A2-0"
    window = try decode(turnRaw("K0")) + window
    try compare("prepend-with-historic-live",
                live: [rememberedLive, try liveTool(historicLive)],
                running: ["call-LIVE-T", historicLive])

    // 8. streaming deltas after all prepends (the steady update path with
    // the incremental caches in place)
    for tick in 0..<3 {
        if let index = window.lastIndex(where: { $0.id == "a-live2" }) {
            window[index] = try decode([["id": "a-live2", "role": "assistant", "created_at": "7",
                                         "content": [["type": "thinking", "thinking": "思考中……\(tick)"]]]])[0]
        }
        try compare("streaming-delta-\(tick)",
                    live: [rememberedLive, try liveTool(historicLive)],
                    running: ["call-LIVE-T", historicLive])
    }

    // 9. POISONING phase (fresh warm model): routes that permanently reject
    // the chunk path for the session — both models must agree everywhere.
    let warm2 = ConversationPresentationModel(key: "s2")
    var window2 = try decode(baseRaw)
    var step2 = 0
    func compare2(_ label: String) throws {
        step2 += 1
        let input = ConversationPresentationModel.Input(messages: window2, live: [], running: [],
                                                        isRunning: true, online: true, epoch: "bench",
                                                        language: "zh")
        let fresh2 = ConversationPresentationModel(key: "s2")
        let w = warm2.update(input)
        let f = fresh2.update(input)
        precondition(w.rows == f.rows, "poison step \(step2) (\(label)): rows diverged")
        precondition(w.navigation == f.navigation, "poison step \(step2) (\(label)): navigation diverged")
        precondition(w.presented(activity: [:], foldsProcess: true, isRunning: true)
                     == f.presented(activity: [:], foldsProcess: true, isRunning: true),
                     "poison step \(step2) (\(label)): presentation diverged")
    }
    try compare2("baseline")
    // a prepended page whose tool identity duplicates one already in the window
    var dupRaw = turnRaw("D0")
    dupRaw[1]["content"] = [["type": "text", "text": "重复调用。"],
                            ["type": "tool_use", "tool_call_id": "call-A1-0",
                             "tool_name": "Read", "input": ["file_path": "/repo/A1-0.swift"]]]
    window2 = try decode(dupRaw) + window2
    try compare2("prepend-duplicate-tool-identity")
    // duplicate MESSAGE ids inside one prepended page
    window2 = try decode(turnRaw("J0") + turnRaw("J0")) + window2
    try compare2("prepend-page-with-duplicate-message-ids")
    // a live tool anchored to the CURRENT prompt whose call sits in the
    // prefix: separates() rejects the split projection (whole-window route)
    let anchoredLive = "call-A3-0"
    window2 = try decode(turnRaw("L0")) + window2
    let input3 = ConversationPresentationModel.Input(messages: window2,
                                                     live: [try liveTool(anchoredLive)],
                                                     running: [anchoredLive],
                                                     isRunning: true, online: true, epoch: "bench",
                                                     language: "zh")
    let w3 = warm2.update(input3)
    let f3 = ConversationPresentationModel(key: "s2").update(input3)
    precondition(w3.rows == f3.rows && w3.navigation == f3.navigation,
                 "poison step (anchored-live): diverged")

    print("PASS: prepend incremental indexes — warm-vs-fresh differential equality over 9 scenario groups with narrative-overlay comparisons (pure prepends, page-split partial turn, the merge that consumes the cached leading turn, remembered live tool whose observedByTurn placement reads owner+base, interior edit rebuild, turn-boundary growth, connection flips, language reset, trailing streaming deltas) plus the poisoning phase (duplicate tool identity, duplicate page message ids, anchored-live separates rejection) against the full-rebuild reference")
}
