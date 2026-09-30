import Foundation
import WorkbenchCore

func checkConversationPresentationModel() throws {
    typealias Model = ConversationPresentationModel
    func messages(_ reply: String = "结果", output: String = "ok") throws -> [KimiMessage] {
        let raw: [[String: Any]] = [
            ["id": "u", "role": "user", "created_at": "1", "content": [["type": "text", "text": "检查文件"]]],
            ["id": "a", "role": "assistant", "created_at": "2", "content": [["type": "tool_use", "tool_call_id": "t", "tool_name": "Read", "input": ["path": "a.swift"]]]],
            ["id": "r", "role": "tool", "created_at": "3", "content": [["type": "tool_result", "tool_call_id": "t", "output": output]]],
            ["id": "reply", "role": "assistant", "created_at": "4", "content": [["type": "text", "text": reply]]]]
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    let initial = try messages()
    let model = Model(key: "host:native:a")
    let referenceTools = ToolVisibilityProjection(), referenceTurns = ConversationProjection()
    let older = try KimiWire.decoder().decode([KimiMessage].self, from: Data(#"[{"id":"old","role":"user","created_at":"0","content":[{"type":"text","text":"较早记录"}]}]"#.utf8))
    for input in [Model.Input(messages: initial, language: "zh"),
                  Model.Input(messages: try messages("修订正文", output: "changed"), language: "zh"),
                  Model.Input(messages: initial, isRunning: true, online: false, language: "zh", summariesEnabled: true),
                  Model.Input(messages: older + initial, language: "zh", summariesEnabled: true, includeToolOutput: true),
                  Model.Input(messages: Array(initial.prefix(2)), running: ["t"], isRunning: true, language: "zh"),
                  Model.Input(messages: [], language: "zh")] {
        let visible = referenceTools.update(input.messages, sessionID: model.key, live: input.live, running: input.running, online: input.online)
        let timeline = referenceTurns.update(visible.messages, isRunning: input.isRunning)
        let narrative = ActivityNarrativeProjection.make(entries: timeline.entries, tools: visible.tools, isRunning: input.isRunning)
        let snapshot = model.update(input)
        precondition(snapshot.rows.map(\.entry) == timeline.entries && snapshot.navigation == timeline.navigation)
        precondition(snapshot.narrative == narrative)
        precondition(snapshot.batch == ActivitySummaryBatch.latest(in: timeline.entries, tools: visible.tools,
            isRunning: input.isRunning, enabled: input.summariesEnabled, includeToolOutput: input.includeToolOutput))
        for row in snapshot.rows {
            let ids = Set(row.entry.messages.flatMap(\.content).compactMap(\.toolCallId))
            precondition(row.tools == visible.tools.filter { ids.contains($0.key) })
            precondition(row.activity == narrative.rows[row.entry.id])
        }
        let count = model.preparationCount
        precondition(model.update(input) === snapshot && model.preparationCount == count, "Equal values must reuse the prepared snapshot")
    }
    let live = try KimiWire.decoder().decode([KimiLiveTool].self, from: Data(#"[{"tool_call_id":"live","name":"Bash","args":{"command":"test"},"last_progress":{"text":"running"}}]"#.utf8))
    let liveModel = Model(key: "host:kimi:a")
    _ = liveModel.update(.init(messages: [initial[0]], live: live, isRunning: true, epoch: "one", language: "zh"))
    let handoff = liveModel.update(.init(messages: [initial[0]], epoch: "one", language: "zh"))
    precondition(handoff.rows.contains { $0.tools["live"]?.status == .missingResult }, "Remember an unrecorded live tool at handoff")
    let localized = liveModel.update(.init(messages: [initial[0]], epoch: "one", language: "en"))
    precondition(localized !== handoff && localized.rows.contains { $0.tools["live"]?.status == .missingResult }, "Language changes must not erase live-only evidence")
    let restarted = liveModel.update(.init(messages: [initial[0]], epoch: "two", language: "en"))
    precondition(restarted.rows.allSatisfy { $0.tools["live"] == nil }, "New runtime epoch must not resurrect old live tools")

    let cache = ConversationPresentationCache(capacity: 2)
    let input = Model.Input(messages: initial, language: "zh")
    let a = ConversationPresentationHandle().update(key: "host-a:native:same", input: input, cache: cache)
    let b = ConversationPresentationHandle().update(key: "host-b:native:same", input: input, cache: cache)
    precondition(a !== b, "Host namespace must isolate equal session IDs")
    precondition(ConversationPresentationHandle().update(key: "host-a:native:same", input: input, cache: cache) === a,
                 "A remounted view must reuse its presentation")
    _ = ConversationPresentationHandle().update(key: "host-a:kimi:same", input: input, cache: cache)
    precondition(cache.count == 2)
    precondition(ConversationPresentationHandle().update(key: "host-b:native:same", input: input, cache: cache) !== b,
                 "Least recently used model must be evicted")
    let rowID = b.rows[0].entry.id
    for headline in ["摘要一", "更新后的摘要"] {
        let external = ActivityNarrativeRow(narrative: .init(turnID: "u", stageID: "external", phase: .exploring,
            headline: headline, source: .external, lifecycle: .final), isAnchor: false, stageClosed: false)
        let displayed = b.displayedRows { $0 == rowID ? external : nil }
        precondition(displayed.first { $0.entry.id == rowID }?.activity == external,
                     "External summary updates must overlay an unchanged cached snapshot")
        precondition(b.rows[0].activity != external, "Overlay must not mutate the cached fallback")
    }
    let revised = ConversationPresentationHandle().update(key: "host-b:native:same",
        input: .init(messages: try messages("同 ID 新正文"), language: "zh"), cache: cache)
    precondition(revised.navigation.last?.reply == "同 ID 新正文" && b.navigation.last?.reply == "结果")
    cache.remove(prefix: "host-b:")
    precondition(ConversationPresentationHandle().update(key: "host-b:native:same", input: input, cache: cache) !== revised)
    cache.removeAll(); precondition(cache.count == 0 && cache.retainedPayloadCost == 0)

    for bounded in [ConversationPresentationCache(maximumMessages: 1), ConversationPresentationCache(maximumPayloadCost: 64), ConversationPresentationCache(capacity: 0)] {
        let active = ConversationPresentationHandle()
        let first = active.update(key: "large", input: input, cache: bounded)
        precondition(bounded.count == 0 && active.update(key: "large", input: input, cache: bounded) === first,
                     "Non-admitted conversations still reuse their active view's model")
    }
    let payloadBound = ConversationPresentationCache(maximumPayloadCost: 4_000)
    _ = ConversationPresentationHandle().update(key: "tool-output",
        input: .init(messages: try messages(output: String(repeating: "x", count: 8_000)), language: "zh"), cache: payloadBound)
    precondition(payloadBound.count == 0, "Nested tool output must count toward admission cost")
    let growing = ConversationPresentationHandle()
    _ = growing.update(key: "growing", input: input, cache: payloadBound)
    precondition(payloadBound.count == 1)
    _ = growing.update(key: "growing", input: .init(messages: try messages(output: String(repeating: "x", count: 8_000)), language: "zh"), cache: payloadBound)
    precondition(payloadBound.count == 0, "Growth beyond budget must evict an already admitted active model")
    let progress = try KimiWire.decoder().decode([KimiLiveTool].self, from: JSONSerialization.data(withJSONObject: [
        ["tool_call_id": "large-live", "name": "Bash", "args": ["command": String(repeating: "x", count: 8_000)]]]))
    let active = ConversationPresentationHandle()
    _ = active.update(key: "live-budget", input: .init(messages: [initial[0]], live: progress, language: "zh"), cache: payloadBound)
    _ = active.update(key: "live-budget", input: .init(messages: [initial[0]], language: "zh"), cache: payloadBound)
    precondition(payloadBound.count == 0, "Remembered live tools must remain in the budget after the live list empties")
    weak var released: Model.Snapshot?
    do { released = ConversationPresentationHandle().update(key: "release", input: input, cache: cache) }
    precondition(released != nil)
    cache.removeAll(); precondition(released == nil, "Eviction must release prepared data once no view owns it")
    print("PASS: presentation parity, same-ID edits, pagination, epoch/language/live handoff, scoped LRU and oversized active state")
}
