import Foundation
import WorkbenchCore

/// Pins the split foldParents representation (shared earlier base + per-update
/// overlay) against the flat last-write-wins merge it replaces.
///
/// Method: differential byte-shape equality against a living reference — the
/// unchanged flat algorithm (displayedRows + ConversationProcessFold.fold +
/// reduce into a fresh dictionary) mirrored here, fed the identical inputs.
/// Value equality alone is not the contract: keys and values are compared as
/// sorted UTF-8 byte pairs, so a canonically-equal-but-differently-encoded
/// mutation cannot survive. An anti-blind counter requires the split path
/// (non-empty overlay) AND the flat fallback to have been exercised.
///
/// Type-level pins cover the overlay-wins collision rule (the flat merge's
/// last-write-wins order), shape-independent equality, and the heterogeneous
/// dictionary comparisons the existing presentation pins rely on.
func checkFoldParentsSplit() throws {
    func decode(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func turnRaw(_ tag: String, tools: Int) -> [[String: Any]] {
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
    /// The unchanged flat algorithm, mirrored: full fold + fresh-dictionary reduce.
    func reference(_ snapshot: ConversationPresentationModel.Snapshot, isRunning: Bool,
                   activity: [String: ActivityNarrativeRow] = [:])
        -> (rows: [ConversationPresentationModel.Row], parents: [String: String]) {
        let rows = ConversationProcessFold.fold(rows: snapshot.displayedRows { activity[$0] }, isRunning: isRunning)
        let parents = rows.reduce(into: [String: String]()) { map, row in
            for folded in row.foldedRows ?? [] { map[folded.entry.id] = row.entry.id }
        }
        return (rows, parents)
    }
    func byteShape(_ map: [String: String]) -> [[UInt8]] {
        map.sorted { $0.key < $1.key }.flatMap { [Array($0.key.utf8), Array($0.value.utf8)] }
    }

    // Type-level: overlay wins a collision (flat merge's last-write-wins),
    // equality ranges over the effective mapping regardless of split shape,
    // and heterogeneous dictionary comparison is symmetric.
    let shadow = FoldParents(base: ["k": "b", "only-base": "x"], overlay: ["k": "o", "only-over": "y"])
    precondition(shadow["k"] == "o", "overlay must win a key collision")
    precondition(shadow["only-base"] == "x" && shadow["only-over"] == "y")
    precondition(shadow.flattened == ["k": "o", "only-base": "x", "only-over": "y"])
    precondition(shadow == ["k": "o", "only-base": "x", "only-over": "y"], "heterogeneous == (lhs split)")
    precondition(["k": "o", "only-base": "x", "only-over": "y"] == shadow, "heterogeneous == (rhs split)")
    precondition(!(shadow == ["k": "b", "only-base": "x", "only-over": "y"]), "base value must not leak through overlay")
    precondition(shadow == FoldParents(base: ["k": "o", "only-base": "x", "only-over": "y"]),
                 "equality must be shape-independent")
    precondition(!shadow.isEmpty && FoldParents().isEmpty)
    precondition(Set(shadow.keys) == Set(["k", "only-base", "only-over"]))
    precondition(FoldParents(base: ["a": "1"]).flattened == ["a": "1"], "empty overlay flattens to base")

    // Differential sequence: streaming tail growth (the split hot path),
    // prepends, fold-shape flips and summary overlays, against a fresh model.
    var seed: UInt64 = 0x5EED_2026_1127
    func rand(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(bound))
    }
    let warm = ConversationPresentationModel(key: "split-pin")
    var window = try decode((0..<4).flatMap { turnRaw("A\($0)", tools: 2 + rand(3)) })
    var sawOverlay = 0, sawFlat = 0, steps = 0
    func compare(_ label: String, isRunning: Bool, activity: [String: ActivityNarrativeRow] = [:]) throws {
        steps += 1
        let input = ConversationPresentationModel.Input(messages: window, isRunning: isRunning,
                                                        epoch: "pin", language: "zh")
        let w = warm.update(input)
        let f = ConversationPresentationModel(key: "split-pin").update(input)
        let presented = w.presented(activity: activity, foldsProcess: true, isRunning: isRunning)
        let ref = reference(f, isRunning: isRunning, activity: activity)
        precondition(presented.rows == ref.rows, "step \(steps) (\(label)): rows diverged from flat reference")
        precondition(byteShape(presented.foldParents.flattened) == byteShape(ref.parents),
                     "step \(steps) (\(label)): foldParents byte shape diverged from flat reference")
        precondition(presented == f.presented(activity: activity, foldsProcess: true, isRunning: isRunning),
                     "step \(steps) (\(label)): warm/fresh presentation equality diverged")
        if !presented.foldParents.overlay.isEmpty { sawOverlay += 1 } else { sawFlat += 1 }
        // The non-fold shape must keep the identical effective mapping too.
        let plain = w.presented(activity: activity, foldsProcess: false, isRunning: isRunning)
        precondition(plain.foldParents.isEmpty, "step \(steps) (\(label)): no folds without folding")
    }

    // Streaming tail: replace the last assistant text in place (same count),
    // then append new messages (count growth) — both must stay byte-identical.
    for delta in 0..<12 {
        if delta % 2 == 0, var last = window.last {
            let grown = (try? decode([["id": last.id, "role": last.role, "created_at": last.createdAt,
                                       "content": [["type": "text", "text": "流式追加 \(delta)：增量文本。"]]]])) ?? []
            if let replacement = grown.first {
                last = replacement
                window[window.count - 1] = last
            }
        } else {
            window.append(contentsOf: try decode(turnRaw("S\(delta)", tools: 1 + rand(2))))
        }
        try compare("stream-\(delta)", isRunning: true)
    }
    // Prepends: older pages arriving in front of the window.
    for page in 0..<4 {
        let older = try decode((0..<2).flatMap { turnRaw("P\(page)-\($0)", tools: 1 + rand(3)) })
        window.insert(contentsOf: older, at: 0)
        try compare("prepend-\(page)", isRunning: true)
    }
    // Text-only latest turn: the split path with an EMPTY overlay — the flat
    // fallback shape a plain-text streaming delta produces every update.
    window.append(contentsOf: try decode([
        ["id": "u-text", "role": "user", "created_at": "1",
         "content": [["type": "text", "text": "纯文本轮：请总结。"]]],
        ["id": "a-text", "role": "assistant", "created_at": "2",
         "content": [["type": "text", "text": "总结：一切正常。"]]],
    ]))
    try compare("text-only-tail", isRunning: true)
    // Fold-shape flip and a summary overlay on a folded entry.
    try compare("no-fold", isRunning: false)
    if let anchorID = window.last(where: { $0.role == "assistant" })?.id {
        let overlay = [anchorID: ActivityNarrativeRow(narrative: .init(turnID: "u", stageID: "external-\(anchorID)",
                                                                       phase: .editing, headline: "外部摘要",
                                                                       source: .commentary, lifecycle: .streaming),
                                                      isAnchor: true, stageClosed: false)]
        try compare("overlay", isRunning: true, activity: overlay)
    }
    // retainingProcessEntries rebuilds flat; byte shape must still match.
    let presented = warm.update(.init(messages: window, isRunning: true, epoch: "pin", language: "zh"))
        .presented(activity: [:], foldsProcess: true, isRunning: true)
    if let foldRow = presented.rows.first(where: { !($0.foldedRows ?? []).isEmpty }) {
        let opened = Set((foldRow.foldedRows ?? []).prefix(1).map { $0.entry.id })
        let retained = presented.retainingProcessEntries(opened)
        let refParents = reference(warm.update(.init(messages: window, isRunning: true, epoch: "pin", language: "zh")),
                                   isRunning: true).parents
        let rowIDs = Set(retained.rows.map { $0.entry.id })
        for child in opened { precondition(retained.foldParents[child] == nil, "opened child leaves the fold map") }
        for (key, _) in refParents where !opened.contains(key) {
            guard let parent = retained.foldParents[key] else {
                preconditionFailure("unopened fold child lost its fold: \(key)")
            }
            // Lifting an opened child re-folds the remainder under a new fold
            // row id; the mapping must stay live, not keep the stale parent.
            precondition(rowIDs.contains(parent), "fold parent must be a live row: \(parent)")
        }
        precondition(retained.foldParents.overlay.isEmpty, "retaining rebuilds flat")
    }
    precondition(sawOverlay >= 8, "anti-blind: split path (non-empty overlay) under-exercised: \(sawOverlay)")
    precondition(sawFlat >= 1, "anti-blind: flat fallback never exercised")
    print("PASS: foldParents split differential byte-shape (\(steps) steps, overlay=\(sawOverlay), flat=\(sawFlat)), collision rule, shape-independent equality")
}
