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
    precondition(running.map(\.presentation) == [.message, .progress, .activity, .progress, .activity])
    precondition(running.flatMap(\.messages).flatMap(\.content) == progress.flatMap(\.content),
                 "Tool summaries must remain between the progress messages that surround them")
    let reorderedTools = ConversationTimelineEntry.make([progress[0], progress[2], progress[1]], isRunning: true)
    precondition(running.filter(\.activity).map(\.id) == reorderedTools.filter(\.activity).map(\.id).reversed(),
                 "Each tool retains its own identity when source order changes")
    let noSummary = ConversationTimelineEntry.make(progress)
    precondition(noSummary.last(where: { !$0.activity })?.presentation == .record && noSummary.last(where: { !$0.activity })?.messages.map(\.id) == ["b"])
    precondition(noSummary.last(where: { !$0.activity })?.messages.flatMap(\.content).allSatisfy { $0.type == "text" } == true)
    let final = try messages("""
    [{"id":"final","role":"assistant","created_at":"4","content":[{"type":"text","text":"已经修复"}]}]
    """)
    let done = ConversationTimelineEntry.make(progress + final)
    precondition(done.last?.presentation == .message && done.last?.messages.first?.id == "final")
    precondition(done.filter(\.activity).count == 2)
    precondition(done.filter(\.activity).map(\.id) == running.filter(\.activity).map(\.id))
    let thoughts = try messages("""
    [{"id":"t","role":"assistant","created_at":"1","content":[{"type":"thinking","thinking":"正在分析中文问题"}]},
     {"id":"x","role":"assistant","created_at":"2","content":[{"type":"tool_use","tool_call_id":"z","tool_name":"read"}]}]
    """)
    precondition(ConversationTimelineEntry.make(thoughts, isRunning: true).first?.presentation == .activity)
    precondition(ConversationTimelineEntry.make(thoughts).first?.presentation == .activity)
    precondition(ConversationTimelineEntry.make([thoughts[1]]).last?.presentation == .emptyOutput)
    let multipleTurns = ConversationTimelineEntry.make(progress + [progress[0]] + thoughts, isRunning: true)
    precondition(multipleTurns.contains { $0.presentation == .record }, "Earlier no-summary turns retain their commentary")
    precondition(multipleTurns.last?.presentation == .activity)

    // Successive reasoning/progress phases remain chronological and independently readable.
    let mixed = ConversationTimelineEntry.make(progress + thoughts, isRunning: true)
    precondition(mixed.last?.messages.contains { $0.id == "t" } == true, "Completed thoughts join the surrounding activity stage")
    precondition(mixed.filter { $0.presentation == .progress }.flatMap(\.messages).map(\.id) == ["a", "b"])
    precondition(mixed.flatMap(\.messages).flatMap(\.content) == (progress + thoughts).flatMap(\.content), "Grouping preserves every part in source order")
    precondition(Set(mixed.map(\.id)).count == mixed.count, "Channels from one message need distinct SwiftUI identities")
    let both = try messages("""
    [{"id":"both","role":"assistant","created_at":"4","content":[{"type":"thinking","thinking":"继续分析"},{"type":"text","text":"阶段概要"},{"type":"tool_use","tool_call_id":"r","tool_name":"read"}]}]
    """)
    let separated = ConversationTimelineEntry.make(both, isRunning: true)
    precondition(separated.map(\.presentation) == [.thinkingDetails, .progress, .activity])
    precondition(separated.flatMap(\.messages).flatMap(\.content).count == 3, "Partition each part exactly once")
    let firstThought = ConversationTimelineEntry.make([thoughts[0]], isRunning: true).last!
    precondition(firstThought.presentation == .thinkingPreview)
    let nextPhase = ConversationTimelineEntry.make(thoughts + both, isRunning: true)
    let preserved = nextPhase.first { $0.id == firstThought.id }!
    precondition(preserved.presentation == .activity && Array(preserved.messages.prefix(1)) == firstThought.messages,
                 "Completed thought retains its identity and content when a new phase begins")
    let updated = ConversationTimelineEntry.make(both + thoughts + final, isRunning: true)
    let readable = updated.filter { !$0.activity }
    precondition(readable.map { $0.messages[0].id } == ["both", "both", "final"])
    precondition(readable.map(\.presentation) == [.thinkingDetails, .progress, .progress])
    precondition(updated.contains { $0 == separated.first(where: { $0.presentation == .progress })! }, "A later overview cannot replace the earlier overview")
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
    let navigationProjection = ConversationProjection()
    let summaries = navigationProjection.update(progress + context + final, isRunning: false).navigation
    precondition(summaries.count == 1 && summaries[0].id == done[0].id)
    precondition(summaries[0].prompt == "检查" && summaries[0].reply == "已经修复")
    precondition(navigationProjection.update(thoughts, isRunning: true).navigation.isEmpty,
                 "Partial history without a user turn must not create a false navigation stop")
    let pendingSummary = navigationProjection.update([progress[0]] + thoughts, isRunning: true).navigation
    precondition(pendingSummary.count == 1 && pendingSummary[0].reply.isEmpty,
                 "Preview must not expose thinking or tool output as an answer")
    let attachment = try messages("""
    [{"id":"file-user","role":"user","created_at":"6","content":[{"type":"file","name":"notes.txt"}]}]
    """)
    precondition(navigationProjection.update(attachment, isRunning: false).navigation[0].prompt == "notes.txt")
    let olderAndCurrent = navigationProjection.update(attachment + progress + final, isRunning: false).navigation
    precondition(olderAndCurrent.last == summaries.first, "Prepending history must preserve turn identity and preview")
    let changedSummary = navigationProjection.update(progress + both, isRunning: true).navigation
    precondition(changedSummary[0].id == summaries[0].id && changedSummary[0].reply == "阶段概要")
    let revisedSummary = navigationProjection.update(progress + final, isRunning: false).navigation
    precondition(revisedSummary == summaries, "Streaming completion must refresh the reply excerpt")
    precondition(ConversationTimelineEntry.make(context).allSatisfy(\.activity), "Runtime context alone is not a completed agent response")
    precondition(context[0].content[0].skillContextSplit == nil && context[0].content[0].visibleText == nil)
    let withContext = ConversationTimelineEntry.make(progress + context, isRunning: true)
    precondition(withContext.last?.activity == true && withContext.last?.messages.last?.id == "context")
    // kimi-code prefixes skill activations with one summary line. The line stays as
    // the user bubble (folding the whole part would merge the reply into the prior
    // turn); only the loaded body collapses.
    let activation = try messages(#"""
    [{"id":"skill","role":"user","created_at":"3","content":[{"type":"text","text":"User activated the skill \"config\". Follow the loaded skill instructions.\n\n<skill-loaded name=\"config\" trigger=\"user-slash\">private instructions</skill-loaded>"}]}]
    """#)
    let activationPart = activation[0].content[0]
    precondition(!activationPart.isRuntimeContext)
    precondition(activationPart.skillContextSplit?.prefix == "User activated the skill \"config\". Follow the loaded skill instructions.")
    precondition(activationPart.skillContextSplit?.context == "<skill-loaded name=\"config\" trigger=\"user-slash\">private instructions</skill-loaded>")
    precondition(activationPart.visibleText == activationPart.skillContextSplit?.prefix)
    precondition(ConversationTimelineEntry.make(activation).map(\.presentation) == [.message],
                 "A prefixed skill activation stays a user message instead of joining the process stage")
    let activationSummary = ConversationProjection().update(activation + final, isRunning: false).navigation
    precondition(activationSummary[0].prompt == "User activated the skill \"config\". Follow the loaded skill instructions."
                 && activationSummary[0].reply == "已经修复",
                 "Navigation excerpts show the invocation line, never the folded skill body")
    let bundled = try messages(#"""
    [{"id":"bundle","role":"user","created_at":"4","content":[{"type":"text","text":"User activated the skill \"a\". Follow the loaded skill instructions.\n\n<skill-loaded name=\"a\">body-a</skill-loaded>"},{"type":"text","text":"真正的问题"}]}]
    """#)
    precondition(ConversationTimelineEntry.make(bundled).map(\.presentation) == [.message])
    precondition(bundled[0].content.map { $0.visibleText ?? "" } == ["User activated the skill \"a\". Follow the loaded skill instructions.", "真正的问题"])
    let prose = try messages(#"""
    [{"id":"prose","role":"user","created_at":"5","content":[{"type":"text","text":"第一行说明\n第二行说明\n<skill-loaded name=\"x\">body</skill-loaded>"}]}]
    """#)
    precondition(prose[0].content[0].skillContextSplit == nil, "Only a single summary line may fold; multi-line prose stays literal")
    // Attachment metadata arrives as a standalone `<system>…</system>` text part
    // next to the typed prompt and the image. It folds as runtime context while
    // the prompt, turn boundary, excerpts and naming stay anchored on the typed text.
    let imageNote = try messages(#"""
    [{"id":"attach","role":"user","created_at":"6","content":[{"type":"text","text":"配置的 codex，一直没响应，是什么情况"},{"type":"text","text":"<system>Image compressed to fit model limits: original 2062x1640 image/png (996 KB) -> sent 2000x1591 image/png (1.0 MB). The uncompressed original is saved at \"/tmp/original.png\".</system>"},{"type":"image","name":"pasted-image.png","source":{"file_id":"f_123"}}]}]
    """#)
    precondition(imageNote[0].isUserPrompt)
    precondition(!imageNote[0].content[0].isRuntimeContext && imageNote[0].content[1].isRuntimeContext)
    precondition(imageNote[0].content[0].visibleText == "配置的 codex，一直没响应，是什么情况"
                 && imageNote[0].content[1].visibleText == nil)
    precondition(ConversationTimelineEntry.make(imageNote).map(\.presentation) == [.message],
                 "An attachment note must not split its prompt into process rows")
    let noteNavigation = ConversationProjection().update(imageNote + final, isRunning: false).navigation
    precondition(noteNavigation[0].prompt == "配置的 codex，一直没响应，是什么情况",
                 "Navigation excerpts show the typed prompt, never the attachment metadata")
    precondition(SessionNaming.excerpt(from: imageNote) == "配置的 codex，一直没响应，是什么情况",
                 "Session naming reads the typed prompt, never the attachment metadata")
    let noteOnly = try messages("""
    [{"id":"note","role":"user","created_at":"8","content":[{"type":"text","text":"<system>harness note</system>"}]}]
    """)
    precondition(!noteOnly[0].isUserPrompt)
    precondition(ConversationTimelineEntry.make(noteOnly).allSatisfy(\.activity),
                 "A message carrying only a system note is process output, not a user prompt")
    let inlineNote = try messages("""
    [{"id":"inline","role":"user","created_at":"9","content":[{"type":"text","text":"看下 <system>这段</system> 是什么"}]}]
    """)
    precondition(!inlineNote[0].content[0].isRuntimeContext,
                 "Only a whole-part system block folds; inline mentions stay literal")
    // Compaction summaries arrive as user-role messages but are harness artifacts:
    // they keep their own collapsed row and never anchor turns, navigation or tools.
    let compaction = try messages("""
    [{"id":"compact","role":"user","created_at":"7","content":[{"type":"text","text":"当前任务：继续优化"}],"metadata":{"origin":{"kind":"compaction_summary"}}}]
    """)
    precondition(compaction[0].isCompactionSummary)
    precondition(!compaction[0].isUserPrompt)
    precondition(progress[0].isUserPrompt && !progress[0].isCompactionSummary)
    precondition(ConversationTimelineEntry.make(compaction).map(\.presentation) == [.message],
                 "A compaction summary keeps its own row instead of joining the process stage")
    precondition(ConversationTimelineEntry.make(progress + compaction + final).contains { $0.presentation == .message && $0.messages[0].id == "compact" },
                 "A mid-conversation compaction keeps its chronological row")
    let compactedNavigation = ConversationProjection().update(progress + compaction + final, isRunning: false).navigation
    precondition(compactedNavigation.count == 1 && compactedNavigation[0].prompt == "检查",
                 "Compaction summaries never start a navigation stop or supply its excerpt")
    precondition(SessionNaming.excerpt(from: compaction) == nil, "Compaction summaries are not user-typed titles")
    precondition(ToolVisibilityProjection.runningIDs(in: progress + compaction, busy: true) == ["x", "y"],
                 "Tool windows anchor on the real prompt, not the compaction summary")
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

func checkCompactionSummaryDisplay() {
    let wrapped = """
    The conversation so far has been compacted to free up context. What follows is your own working summary of this task.

    ## 交接摘要（2026-09-23，渲染打磨）

    ### 当前状态
    全部请求已闭环。

    ## Context Recovery
    Everything before this note is still on disk in this agent's event log:
      /tmp/example/wire.jsonl
    """
    expectEqual(CompactionSummaryDisplay.humanText(wrapped),
                "## 交接摘要（2026-09-23，渲染打磨）\n\n### 当前状态\n全部请求已闭环。")
    expectEqual(CompactionSummaryDisplay.humanText("## 交接摘要\n正文"), "## 交接摘要\n正文")
    let orphanPreamble = "The conversation so far has been compacted to free up context. 只有一段正文。"
    expectEqual(CompactionSummaryDisplay.humanText(orphanPreamble), orphanPreamble)
    expectEqual(CompactionSummaryDisplay.humanText("## 摘要\nA\n\n## Context Recovery\n仅 agent 使用"),
                "## 摘要\nA")
    let scaffoldOnly = "The conversation so far has been compacted.\n\n## Context Recovery\n仅脚手架"
    expectEqual(CompactionSummaryDisplay.humanText(scaffoldOnly), scaffoldOnly)
    let preamble = "The conversation so far has been compacted to free up context. What follows is your own working summary of this task."
    let prose = "先保留这段没有标题的正文。\n\n## 后续工作\n继续验证。"
    expectEqual(CompactionSummaryDisplay.humanText(preamble + "\n\n" + prose), prose)
    expectEqual(CompactionSummaryDisplay.humanText(preamble + "\n\n只有普通正文。"), "只有普通正文。")
    let recoveryPlan = "## 摘要\n正文\n\n## Context Recovery Plan\n保留恢复计划。\n\n## Context Recovery Status\n保留当前状态。"
    expectEqual(CompactionSummaryDisplay.humanText(recoveryPlan), recoveryPlan)
    expectEqual(CompactionSummaryDisplay.humanText(recoveryPlan + "\n\n## Context Recovery\n仅 agent 使用"), recoveryPlan)
    print("PASS: compaction summary display strips harness scaffolding")
}
