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
/// fold shapes. The matrix walks the paths the incremental fast route must
/// match exactly: pure full-turn prepends, page-split partial turns, the
/// MERGE of a partial leading turn by the next page (the case that consumes
/// one cached turn), duplicate tool identities across page and window (the
/// whole-window rejection path), interior edits forcing rebuilds, turn
/// boundary growth interleaved with prepends, live tools anchored into a
/// consumed turn, connection-state flips, language resets and duplicate
/// message ids inside a page. A wrong base shift, a missing consumed-entry
/// removal, or a wrong last-wins order in the incremental dictionary shows
/// up here as a divergence from the fresh model.
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

    var baseRaw = (0..<5).flatMap { turnRaw("A\($0)") }
    // The trailing live turn (no final answer yet).
    baseRaw.append(["id": "u-live", "role": "user", "created_at": "4",
                    "content": [["type": "text", "text": "当前轮：正在进行。"]]])
    baseRaw.append(["id": "a-live", "role": "assistant", "created_at": "5",
                    "content": [["type": "thinking", "thinking": "推进中……"]]])

    let pageFull = (0..<3).flatMap { turnRaw("B\($0)") }        // three whole older turns
    let pageC = (0..<2).flatMap { turnRaw("C\($0)", tools: 3) } // will be split across two pages
    let splitAt = pageC.count / 2                               // a page boundary inside turn C0

    let warm = ConversationPresentationModel(key: "s")
    var window = try decode(baseRaw)
    var step = 0
    func compare(_ label: String, live: [KimiLiveTool] = [], running: Set<String> = [],
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
        let overlayIDs = [w.rows.first?.entry.id, w.rows.dropFirst(2).first?.entry.id].compactMap { $0 }
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

    // 3. a page whose tool identity duplicates one already in the window:
    // both models must take the same (whole-window) rejection route
    var dupRaw = turnRaw("D0")
    dupRaw[1]["content"] = [["type": "text", "text": "重复调用。"],
                            ["type": "tool_use", "tool_call_id": "call-A1-0",
                             "tool_name": "Read", "input": ["file_path": "/repo/A1-0.swift"]]]
    window = try decode(dupRaw) + window
    try compare("prepend-duplicate-tool-identity")

    // 4. interior edit (same id, changed text) then another prepend:
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

    // 5. tail growth (turn boundary) interleaved with a prepend
    window += try decode([["id": "u-live2", "role": "user", "created_at": "6",
                           "content": [["type": "text", "text": "新一轮：继续。"]]],
                          ["id": "a-live2", "role": "assistant", "created_at": "7",
                           "content": [["type": "thinking", "thinking": "思考中……"]]]])
    try compare("turn-boundary-growth")
    window = try decode(turnRaw("F0", tools: 1)) + window
    try compare("prepend-after-boundary")

    // 6. live tool anchored into the turn a merge will consume
    let liveID = "call-F0-0"
    window = try decode((0..<2).flatMap { turnRaw("G\($0)") }) + window
    try compare("prepend-with-live-tool", live: [try liveTool(liveID)], running: [liveID])

    // 7. connection flip + prepend (chunk reuse breaks; caches must reset consistently)
    try compare("offline", live: [try liveTool(liveID)], running: [liveID], online: false)
    window = try decode(turnRaw("H0")) + window
    try compare("prepend-offline", live: [try liveTool(liveID)], running: [liveID], online: false)
    try compare("back-online", live: [try liveTool(liveID)], running: [liveID], online: true)

    // 8. language change (discardPrefix) then prepend
    try compare("language-en", language: "en")
    window = try decode(turnRaw("I0")) + window
    try compare("prepend-after-language-change", language: "en")

    // 9. duplicate MESSAGE ids inside one prepended page
    let dupPage = turnRaw("J0") + turnRaw("J0")
    window = try decode(dupPage) + window
    try compare("prepend-page-with-duplicate-message-ids")

    // 10. a live tool whose call is RECORDED in window history: its owner
    // lookup (owner[id] + relative base) drives observedByTurn and the
    // chunk's observed state — a wrong base shift misplaces the tool row.
    let historicLive = "call-A2-0"
    try compare("live-tool-in-history", live: [try liveTool(historicLive)], running: [historicLive])
    window = try decode(turnRaw("K0")) + window
    try compare("prepend-with-historic-live", live: [try liveTool(historicLive)], running: [historicLive])

    // 11. streaming deltas after all prepends (the steady update path with
    // the incremental caches in place)
    for tick in 0..<3 {
        if let index = window.lastIndex(where: { $0.id == "a-live2" }) {
            window[index] = try decode([["id": "a-live2", "role": "assistant", "created_at": "7",
                                         "content": [["type": "thinking", "thinking": "思考中……\(tick)"]]]])[0]
        }
        try compare("streaming-delta-\(tick)")
    }

    print("PASS: prepend incremental indexes — warm-vs-fresh differential equality over 11 scenario groups with narrative-overlay comparisons (pure prepends, page-split partial turn, the merge that consumes the cached leading turn, duplicate tool identity rejection, interior edit rebuild, turn-boundary growth, live tool anchored into a consumed turn, connection flips, language reset, duplicate page ids, a live tool recorded in history, trailing streaming deltas) comparing rows, navigation, narrative key, both fold shapes and overlay presentations per step")
}
