import Foundation
import WorkbenchCore

func checkReadingLifecycle() throws {
    let source = """
    [{"id":"u","role":"user","created_at":"1","content":[{"type":"text","text":"fix"}]},
     {"id":"progress","role":"assistant","created_at":"2","content":[{"type":"text","text":"Checking the implementation"}]},
     {"id":"summary","role":"assistant","created_at":"3","content":[{"type":"thinking","thinking":"PRIVATE_REASONING_NOT_A_SUMMARY","source":{"kind":"activity_summary","summaryParts":["Inspecting the tab state.","Checking first open."],"state":"streaming"}}]},
     {"id":"read","role":"assistant","created_at":"4","content":[{"type":"tool_use","tool_call_id":"r","tool_name":"read","input":{"path":"a.swift"}}]},
     {"id":"read-result","role":"tool","created_at":"5","content":[{"type":"tool_result","tool_call_id":"r","output":"ok","is_error":false}]},
     {"id":"edit","role":"assistant","created_at":"6","content":[{"type":"tool_use","tool_call_id":"e","tool_name":"edit","input":{"path":"a.swift","old_string":"old","new_string":"new"}}]},
     {"id":"edit-result","role":"tool","created_at":"7","content":[{"type":"tool_result","tool_call_id":"e","output":"ok","is_error":false}]},
     {"id":"check","role":"assistant","created_at":"8","content":[{"type":"tool_use","tool_call_id":"check","tool_name":"bash","input":{"command":"swift test"}}]},
     {"id":"check-result","role":"tool","created_at":"9","content":[{"type":"tool_result","tool_call_id":"check","output":"failed","is_error":true}]},
     {"id":"final","role":"assistant","created_at":"10","content":[{"type":"text","text":"Fixed; tests need attention."}]}]
    """
    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: Data(source.utf8))
    let bareGoal = VisibleTool(id: "goal", name: "CreateGoal", input: .object([:]), status: .succeeded)
    let bareTodo = VisibleTool(id: "todo", name: "TodoList", input: nil, status: .running)
    precondition(ToolPresentation.rowSummary(bareGoal).isEmpty && ToolPresentation.rowSummary(bareTodo).isEmpty,
                 "Bare tools must not repeat their title in the detail slot")
    precondition(ToolPresentation.recentTargets([bareGoal, bareTodo]).isEmpty)
    let shell = VisibleTool(id: "shell-summary", name: "bash", input: .object(["command": .string("cd /repo && swift test --filter Reading")]), status: .running)
    let path = VisibleTool(id: "path-summary", name: "read", input: .object(["path": .string("/repo/Sources/a.swift")]), status: .succeeded)
    precondition(ToolPresentation.rowSummary(shell) == "cd /repo && swift test --filter Reading"
                 && ToolPresentation.rowSummary(path) == "/repo/Sources/a.swift",
                 "The detail slot must preserve the observed command or path")
    precondition(ConversationThinkingSummary.latest(in: Array(messages.prefix(3))) == "Inspecting the tab state. Checking first open.")
    let privatePart = try KimiWire.decoder().decode([KimiMessage].self, from: Data("""
    [{"id":"private","role":"assistant","created_at":"11","content":[{"type":"thinking","thinking":"PRIVATE_REASONING_NOT_A_SUMMARY"}]}]
    """.utf8))
    precondition(ConversationThinkingSummary.latest(in: privatePart) == nil)
    precondition(ConversationThinkingSummary.latest(in: messages + privatePart) == nil, "Private reasoning cannot masquerade as the latest public preview")
    let model = ConversationPresentationModel(key: "lifecycle-core")
    let thinking = model.update(.init(messages: Array(messages.prefix(3)), isRunning: true, language: "en"))
    let thinkingRows = thinking.presented(activity: [:], foldsProcess: true, isRunning: true)
    precondition(thinkingRows.rows.filter { $0.entry.presentation == .processFold && $0.live }.count == 1,
                 "Thinking and intermediate text share one live turn disclosure")
    let withTool = model.update(.init(messages: Array(messages.prefix(5)), isRunning: true, language: "en"))
    let withToolRows = withTool.presented(activity: [:], foldsProcess: true, isRunning: true)
    precondition(withToolRows.rows.contains { $0.entry.presentation == .processFold && $0.live },
                 "Once a tool starts, the running turn rides one live process disclosure")
    let keptSummary = withTool.presented(activity: [:], foldsProcess: true, isRunning: true,
        preservingEntries: ["thinking:summary:0"])
    precondition(keptSummary.rows.contains { $0.entry.id == "thinking:summary:0" }
                 || keptSummary.rows.first(where: { $0.live })?.foldedRows?.contains { $0.entry.id == "thinking:summary:0" } == true,
                 "An opened summary source stays visible (retained top-level or inside the live disclosure)")
    let live = model.update(.init(messages: Array(messages.dropLast()), isRunning: true, language: "en"))
    precondition(live.presented(activity: [:], foldsProcess: true, isRunning: true).rows.contains { $0.entry.presentation == .processFold && $0.live },
                 "The running turn's process folds into a live disclosure")
    let finished = model.update(.init(messages: messages, language: "en"))
    let done = finished.presented(activity: [:], foldsProcess: true, isRunning: false)
    precondition(!done.rows.contains(where: \.live), "A completed turn must settle every process head")
    precondition(done.rows.contains { $0.entry.presentation == .processFold })
    precondition(!done.rows.contains { $0.entry.id == "activity:tool:e" }, "Edit receipts fold with the rest of the process")
    precondition(!done.rows.contains { $0.tools["check"]?.status == .failed }, "A failed tool folds with the rest of the process")
    precondition(!done.rows.contains { $0.entry.presentation == .progress })
    let retained = done.retainingProcessEntries(["activity:tool:r"])
    precondition(retained.rows.contains { $0.entry.id == "activity:tool:r" })
    precondition(retained.foldParents["activity:tool:r"] == nil)
    func flattened(_ rows: [ConversationPresentationModel.Row]) -> [ConversationPresentationModel.Row] {
        rows.flatMap { $0.foldedRows ?? [$0] }
    }
    precondition(flattened(retained.rows) == flattened(done.rows), "Keeping an opened step cannot reorder or drop process")
    for status in [VisibleTool.Status.awaitingApproval, .missingResult, .disconnected, .running, .failed] {
        let rows = finished.rows.map { row in
            guard let tool = row.tools["r"] else { return row }
            return ConversationPresentationModel.Row(entry: row.entry, tools: ["r": .init(id: "r", name: tool.name, input: tool.input, status: status)], activity: row.activity)
        }
        precondition(!ConversationProcessFold.fold(rows: rows, isRunning: false).contains { $0.tools["r"]?.status == status },
                     "Every tool outcome folds: \(status)")
    }
    let interrupted = model.update(.init(messages: Array(messages.dropLast()), language: "en"))
    precondition(interrupted.presented(activity: [:], foldsProcess: true, isRunning: false).rows.contains { $0.entry.presentation == .processFold }, "An unfinished turn folds its process like any other")
    let continuation = try KimiWire.decoder().decode([KimiMessage].self, from: Data("""
    [{"id":"u-next","role":"user","created_at":"11","content":[{"type":"text","text":"continue"}]},
     {"id":"next-read","role":"assistant","created_at":"12","content":[{"type":"tool_use","tool_call_id":"next-r","tool_name":"read","input":{"path":"b.swift"}}]},
     {"id":"next-progress","role":"assistant","created_at":"13","content":[{"type":"text","text":"Now checking the next file"}]},
     {"id":"next-check","role":"assistant","created_at":"14","content":[{"type":"tool_use","tool_call_id":"next-c","tool_name":"bash","input":{"command":"swift test"}}]},
     {"id":"next-answer","role":"assistant","created_at":"15","content":[{"type":"text","text":"Streaming reply"}]}]
    """.utf8))
    let next = model.update(.init(messages: messages + continuation, running: ["next-c"], isRunning: true, language: "en"))
    let nextRows = next.presented(activity: [:], foldsProcess: true, isRunning: true)
    let active = nextRows.rows.filter(\.live)
    precondition(active.count == 1, "Progress between tools must not split a live turn into multiple heads")
    precondition(active[0].foldedRows?.contains { $0.entry.messages.first?.id == "next-progress" } == true)
    precondition(nextRows.rows.last?.entry.messages.first?.id == "next-answer", "The trailing reply remains outside the process")
    precondition(nextRows.rows.contains { !$0.live && $0.entry.presentation == .processFold }, "Advancing the turn settles its earlier head")
    let openChild = nextRows.retainingProcessEntries(["activity:tool:next-r"])
    precondition(openChild.rows.filter(\.live).count == 1, "A reader-opened child cannot split the live turn")
    let allDone = model.update(.init(messages: messages + continuation, language: "en"))
        .presented(activity: [:], foldsProcess: true, isRunning: false)
    precondition(!allDone.rows.contains(where: \.live), "The next completion also settles in place")
    print("PASS: live public summaries, completed process folding, manual expansion, uniform folding of edits and failures")
}
