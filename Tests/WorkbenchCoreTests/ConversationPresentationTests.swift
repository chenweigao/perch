import Foundation
import WorkbenchCore

func checkConversationPresentation() throws {
    func messages(_ json: String) throws -> [KimiMessage] { try KimiWire.decoder().decode([KimiMessage].self, from: Data(json.utf8)) }
    let progress = try messages("""
    [{"id":"u","role":"user","created_at":"1","content":[{"type":"text","text":"检查"}]},
     {"id":"a","role":"assistant","created_at":"2","content":[{"type":"text","text":"找到问题了"},{"type":"tool_use","tool_call_id":"x","tool_name":"bash"}]},
     {"id":"b","role":"assistant","created_at":"3","content":[{"type":"text","text":"修复已写入"},{"type":"tool_use","tool_call_id":"y","tool_name":"write"}]}]
    """)
    let running = ConversationTimelineEntry.make(progress, isRunning: true)
    precondition(running.last?.presentation == .progress && running.last?.messages.first?.id == "b")
    let reorderedTools = ConversationTimelineEntry.make([progress[0], progress[2], progress[1]], isRunning: true)
    precondition(running.first(where: \.activity)?.id == reorderedTools.first(where: \.activity)?.id,
                 "Activity identity belongs to the user turn, independent of live/persisted tool order")
    let noSummary = ConversationTimelineEntry.make(progress)
    precondition(noSummary.last?.presentation == .record && noSummary.last?.messages.map(\.id) == ["b"])
    precondition(noSummary.last?.messages.flatMap(\.content).allSatisfy { $0.type == "text" } == true)
    let final = try messages("""
    [{"id":"final","role":"assistant","created_at":"4","content":[{"type":"text","text":"已经修复"}]}]
    """)
    let done = ConversationTimelineEntry.make(progress + final)
    precondition(done.last?.presentation == .message && done.last?.messages.first?.id == "final")
    precondition(done.filter(\.activity).count == 1)
    let thoughts = try messages("""
    [{"id":"t","role":"assistant","created_at":"1","content":[{"type":"thinking","thinking":"正在分析中文问题"}]},
     {"id":"x","role":"assistant","created_at":"2","content":[{"type":"tool_use","tool_call_id":"z","tool_name":"read"}]}]
    """)
    precondition(ConversationTimelineEntry.make(thoughts, isRunning: true).last?.presentation == .thinkingPreview)
    precondition(ConversationTimelineEntry.make(thoughts).last?.presentation == .thinkingRecord)
    precondition(ConversationTimelineEntry.make([thoughts[1]]).last?.presentation == .emptyOutput)
    let multipleTurns = ConversationTimelineEntry.make(progress + [progress[0]] + thoughts, isRunning: true)
    precondition(multipleTurns.contains { $0.presentation == .record }, "Earlier no-summary turns retain their commentary")
    precondition(multipleTurns.last?.presentation == .thinkingPreview)

    // Successive reasoning/progress phases remain chronological and independently readable.
    let mixed = ConversationTimelineEntry.make(progress + thoughts, isRunning: true)
    precondition(mixed.last?.presentation == .thinkingPreview && mixed.last?.messages[0].id == "t")
    precondition(mixed.filter { $0.presentation == .progress }.flatMap(\.messages).map(\.id) == ["a", "b"])
    precondition(mixed.filter(\.activity).flatMap(\.messages).flatMap(\.content).allSatisfy { $0.type == "tool_use" })
    precondition(Set(mixed.map(\.id)).count == mixed.count, "Channels from one message need distinct SwiftUI identities")
    let both = try messages("""
    [{"id":"both","role":"assistant","created_at":"4","content":[{"type":"thinking","thinking":"继续分析"},{"type":"text","text":"阶段概要"},{"type":"tool_use","tool_call_id":"r","tool_name":"read"}]}]
    """)
    let separated = ConversationTimelineEntry.make(both, isRunning: true)
    precondition(separated.map(\.presentation) == [.activity, .thinkingDetails, .progress])
    precondition(separated.flatMap(\.messages).flatMap(\.content).count == 3, "Partition each part exactly once")
    let firstThought = ConversationTimelineEntry.make(thoughts, isRunning: true).last!
    let nextPhase = ConversationTimelineEntry.make(thoughts + both, isRunning: true)
    let preserved = nextPhase.first { $0.id == firstThought.id }!
    precondition(preserved.presentation == .thinkingDetails && preserved.messages == firstThought.messages,
                 "Completed thought retains its identity and content when a new phase begins")
    let updated = ConversationTimelineEntry.make(both + thoughts + final, isRunning: true)
    let readable = updated.filter { !$0.activity }
    precondition(readable.map { $0.messages[0].id } == ["both", "both", "t", "final"])
    precondition(readable.map(\.presentation) == [.thinkingDetails, .progress, .thinkingDetails, .progress])
    precondition(updated.contains { $0 == separated.last! }, "A later overview cannot replace the earlier overview")
    let interleaved = try messages("""
    [{"id":"stream","role":"assistant","created_at":"5","content":[{"type":"thinking","thinking":"第一阶段思考"},{"type":"text","text":"第一阶段概要"},{"type":"thinking","thinking":"第二阶段思考"},{"type":"text","text":"第二阶段概要"}]}]
    """)
    let phases = ConversationTimelineEntry.make(interleaved, isRunning: true)
    precondition(phases.map(\.presentation) == [.thinkingDetails, .progress, .thinkingDetails, .progress])
    precondition(Set(phases.map(\.id)).count == 4, "Repeated channels within one message need unique identities")
    precondition(phases.flatMap(\.messages).flatMap(\.content) == interleaved[0].content)
    let completedPhases = ConversationTimelineEntry.make(interleaved)
    precondition(completedPhases.map(\.id) == phases.map(\.id), "Completion must not recreate transcript rows")

    let context = try messages("""
    [{"id":"context","role":"user","created_at":"2","content":[{"type":"text","text":"<skill-loaded name='config'>runtime reference</skill-loaded>"}]}]
    """)
    precondition(context[0].content[0].isRuntimeContext)
    precondition(ConversationTimelineEntry.make(context).allSatisfy(\.activity), "Runtime context alone is not a completed agent response")
    let withContext = ConversationTimelineEntry.make(progress + context, isRunning: true)
    precondition(withContext.last?.presentation == .progress && withContext.last?.messages.first?.id == "b")
    // Cached presentation is exactly the uncached policy across live edits, completion,
    // pagination and a switch to a different conversation (no ID/count-only invalidation).
    let projection = ConversationProjection()
    let revised = try messages("""
    [{"id":"both","role":"assistant","created_at":"4","content":[{"type":"thinking","thinking":"更新后的思考"},{"type":"text","text":"概要已经改变"},{"type":"tool_use","tool_call_id":"r","tool_name":"read"}]},
     {"id":"result","role":"tool","created_at":"5","content":[{"type":"tool_result","tool_call_id":"r","output":"读取结果"}]}]
    """)
    for (input, busy) in [(progress, true), (progress, true), (progress + both, true),
                          (progress + revised, true), (progress + revised, false),
                          (progress + revised + final, false), (context + progress + final, false),
                          (thoughts, true), (thoughts, false), ([], false)] {
        let cached = projection.update(input, isRunning: busy)
        precondition(cached.entries == ConversationTimelineEntry.make(input, isRunning: busy), "Cached rendering must preserve all output channels")
        let expected = input.flatMap(\.content).filter { $0.type == "tool_result" }
            .reduce(into: [String: KimiPart]()) { if let id = $1.toolCallId { $0[id] = $1 } }
        precondition(cached.results == expected, "Tool-result edits and deletions must invalidate the cache")
    }
    let catalog = ModelCatalog.options([
        .object(["provider": .string("demo-a-proxy"), "model": .string("demo-a/claude-example"), "display_name": .string("Claude Example")]),
        .object(["provider": .string("demo-c"), "model": .string("demo-c/claude-example"), "display_name": .string("Claude Example")]),
        .object(["provider": .string("demo-b"), "model": .string("demo-b/kimi-example"), "capabilities": .array([.string("image_in")])])
    ])
    let groups = ModelCatalog.groups(catalog)
    precondition(groups.map(\.id) == ["demo-a-proxy", "demo-b", "demo-c"])
    precondition(ModelCatalog.groups(catalog, matching: "CLAUDE").count == 2)
    precondition(ModelCatalog.groups(catalog, matching: "demo-a-proxy").first?.models.first?.id == "demo-a/claude-example")
    precondition(ModelCatalog.groups(catalog, matching: "missing").isEmpty)
    print("PASS: live progress, missing summaries, thinking-only output, tool-only notice and provider model groups")
}
