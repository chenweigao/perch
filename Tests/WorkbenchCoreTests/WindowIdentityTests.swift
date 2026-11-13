import Foundation
import WorkbenchCore

/// A reused projection and a reused find-bar cache both rest on "the earlier
/// messages of this window did not change", and they are compared as the bytes an
/// unchanged copy carries. That comparison must stay exactly the value comparison
/// it replaces: an in-place edit of the same length, a changed timestamp or a
/// changed metadata value ends the reuse, while messages rebuilt from the same
/// wire data keep it. Every snapshot equals a complete recomputation and every
/// find result equals a complete search.
func checkWindowIdentityReuse() throws {
    typealias Model = ConversationPresentationModel
    let prose = String(repeating: "这一轮的说明包含 English identifiers 与中文混排，长到不会内联进字符串。", count: 4)
    func window(output: String, text: String, stamp: String, metadata: [String: Any]?) -> [[String: Any]] {
        var answer: [String: Any] = ["id": "f0", "role": "assistant", "created_at": "000004",
                                     "content": [["type": "text", "text": text]]]
        if let metadata { answer["metadata"] = metadata }
        return [
            ["id": "u0", "role": "user", "created_at": "000001",
             "content": [["type": "text", "text": "第 0 轮：请检查实现。"]]],
            ["id": "a0", "role": "assistant", "created_at": "000002", "content": [
                ["type": "thinking", "thinking": "先读取文件再决定"],
                ["type": "tool_use", "tool_call_id": "read-0", "tool_name": "Read",
                 "input": ["file_path": "/fixture/Sources/File0.swift"]]]],
            ["id": "r0", "role": "tool", "created_at": stamp, "content": [
                ["type": "tool_result", "tool_call_id": "read-0", "output": output, "is_error": false]]],
            answer,
            ["id": "u1", "role": "user", "created_at": "000005",
             "content": [["type": "text", "text": "第 1 轮：继续。"]]],
        ]
    }
    let baseOutput = "读取结果 ALPHA 的第一版，行数与字节数都要保持不变。"
    let baseText = "第 0 轮完成：\(prose)"
    let baseStamp = "000003"
    func decoded(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func tail(_ tokens: Int) throws -> [KimiMessage] {
        try decoded([["id": "live:1", "role": "assistant", "created_at": "",
                      "content": [["type": "thinking", "thinking": String(repeating: "推理 ", count: tokens)]]]])
    }
    // One decoded window per variant, so the unchanged messages of a step are the
    // bytes a copy of that window carries; a rebuilt window decodes them again.
    let base = try decoded(window(output: baseOutput, text: baseText, stamp: baseStamp, metadata: nil))
    let editedOutput = try decoded(window(output: "读取结果 BETAS 的第一版，行数与字节数都要保持不变。",
                                          text: baseText, stamp: baseStamp, metadata: nil))
    let editedText = try decoded(window(output: baseOutput,
                                        text: baseText.replacingOccurrences(of: "完成", with: "结束"),
                                        stamp: baseStamp, metadata: nil))
    let editedStamp = try decoded(window(output: baseOutput, text: baseText, stamp: "000009", metadata: nil))
    let metadataRaw = window(output: baseOutput, text: baseText, stamp: baseStamp,
                             metadata: ["annotations": ["state": "kept"]])
    let editedMetadata = try decoded(metadataRaw)
    // Equal by value, different payloads: what a snapshot refresh hands over.
    let rebuilt = try decoded(metadataRaw)
    let older = try decoded([["id": "u-old", "role": "user", "created_at": "000000",
                              "content": [["type": "text", "text": "更早的一轮"]]]])
    precondition(baseOutput.utf8.count == "读取结果 BETAS 的第一版，行数与字节数都要保持不变。".utf8.count
                 && base.count == editedOutput.count && base.count == rebuilt.count,
                 "The in-place edits keep the window shape and the byte length")
    precondition(rebuilt == editedMetadata, "A window rebuilt from the same wire data is equal by value")
    precondition([editedOutput, editedText, editedStamp, editedMetadata].allSatisfy { $0 != base },
                 "Each in-place edit changes the window's value")

    struct Step {
        let name: String
        let messages: [KimiMessage]
        let reuses: Bool
    }
    let steps: [Step] = try [
        Step(name: "first window", messages: base + tail(1), reuses: false),
        Step(name: "token", messages: base + tail(2), reuses: true),
        Step(name: "earlier output edited in place", messages: editedOutput + tail(3), reuses: false),
        Step(name: "token after the output edit", messages: editedOutput + tail(4), reuses: true),
        Step(name: "earlier text edited in place", messages: editedText + tail(5), reuses: false),
        Step(name: "earlier timestamp edited in place", messages: editedStamp + tail(6), reuses: false),
        Step(name: "earlier metadata edited in place", messages: editedMetadata + tail(7), reuses: false),
        Step(name: "token after the metadata edit", messages: editedMetadata + tail(8), reuses: true),
        Step(name: "window rebuilt from the same wire data", messages: rebuilt + tail(9), reuses: true),
        Step(name: "token after the rebuild", messages: rebuilt + tail(10), reuses: true),
        Step(name: "older page prepended", messages: older + rebuilt + tail(11), reuses: false),
        Step(name: "token after the page", messages: older + rebuilt + tail(12), reuses: true),
    ]

    var metrics: ConversationPresentationUpdateMetrics?
    let model = Model(key: "host:kimi:window", metricsHandler: { metrics = $0 })
    let search = ConversationSearch()
    var reused = 0
    for step in steps {
        let input = Model.Input(messages: step.messages, isRunning: true, epoch: "one", language: "zh",
                                summariesEnabled: true, includeToolOutput: true)
        metrics = nil
        let snapshot = model.update(input)
        // A fresh model holds nothing to reuse, so it is the complete recomputation.
        let oracle = Model(key: "host:kimi:window")
        let reference = oracle.update(input)
        precondition(snapshot.rows == reference.rows, "\(step.name): rows must equal a complete recomputation")
        precondition(snapshot.navigation == reference.navigation && snapshot.narrative == reference.narrative,
                     "\(step.name): navigation and narrative must equal a complete recomputation")
        precondition(snapshot.batch == reference.batch, "\(step.name): summary batch must equal a complete recomputation")
        precondition(model.retainedPayloadCost == oracle.retainedPayloadCost, "\(step.name): payload admission cost")
        precondition(metrics?.reusedHistory == step.reuses, "\(step.name): history reuse must be \(step.reuses)")
        if metrics?.reusedHistory == true { reused += 1 }
        func found(_ query: String, _ note: String) {
            precondition(search.hits(in: step.messages, query: query, running: true)
                         == ConversationSearch().hits(in: step.messages, query: query, running: true),
                         "\(step.name): \(note) find results for \(query) must equal a complete search")
        }
        // The previous step left this query cached, so these hits can only come
        // from the cached earlier window while the window comparison allows it.
        found("ALPHA", "cached")
        for query in ["BETAS", "第 1 轮", "File0.swift", "ALPHA"] { found(query, "complete") }
        let presented = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
        let folded = reference.presented(activity: [:], foldsProcess: true, isRunning: true)
        precondition(presented.rows == folded.rows && presented.foldParents == folded.foldParents,
                     "\(step.name): presented rows and fold must equal a complete recomputation")
    }
    precondition(reused == steps.filter(\.reuses).count, "Every reusable step must reuse the earlier turns")
    print("PASS: window identity reuse ends at any earlier in-place edit, survives a rebuilt window and matches complete recomputation")
}
