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
    precondition(ConversationThinkingSummary.latest(in: Array(messages.prefix(3))) == "Inspecting the tab state. Checking first open.")
    let privatePart = try KimiWire.decoder().decode([KimiMessage].self, from: Data("""
    [{"id":"private","role":"assistant","created_at":"11","content":[{"type":"thinking","thinking":"PRIVATE_REASONING_NOT_A_SUMMARY"}]}]
    """.utf8))
    precondition(ConversationThinkingSummary.latest(in: privatePart) == nil)
    precondition(ConversationThinkingSummary.latest(in: messages + privatePart) == nil, "Private reasoning cannot masquerade as the latest public preview")
    let model = ConversationPresentationModel(key: "lifecycle-core")
    let thinking = model.update(.init(messages: Array(messages.prefix(3)), isRunning: true, language: "en"))
    let thinkingRows = thinking.presented(activity: [:], foldsProcess: true, isRunning: true)
    precondition(thinkingRows.rows.contains { $0.entry.presentation == .thinkingPreview }, "A public summary before the first tool needs a visible live host")
    let withTool = model.update(.init(messages: Array(messages.prefix(5)), isRunning: true, language: "en"))
    let keptSummary = withTool.presented(activity: [:], foldsProcess: true, isRunning: true,
        preservingEntries: ["thinking:summary:0"])
    precondition(keptSummary.rows.contains { $0.entry.id == "thinking:summary:0" },
                 "An opened summary source must not disappear when its first tool arrives")
    let live = model.update(.init(messages: Array(messages.dropLast()), isRunning: true, language: "en"))
    precondition(!live.presented(activity: [:], foldsProcess: true, isRunning: true).rows.contains { $0.entry.presentation == .processFold })
    let finished = model.update(.init(messages: messages, language: "en"))
    let done = finished.presented(activity: [:], foldsProcess: true, isRunning: false)
    precondition(done.rows.contains { $0.entry.presentation == .processFold })
    precondition(done.rows.contains { $0.entry.id == "activity:tool:e" }, "Edit receipts remain independently visible")
    precondition(done.rows.contains { $0.tools["check"]?.status == .failed }, "A final answer cannot resolve a failed operation by implication")
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
        precondition(ConversationProcessFold.fold(rows: rows, isRunning: false, preservesSteps: true).contains { $0.tools["r"]?.status == status })
    }
    let interrupted = model.update(.init(messages: Array(messages.dropLast()), language: "en"))
    precondition(!interrupted.presented(activity: [:], foldsProcess: true, isRunning: false).rows.contains { $0.entry.presentation == .processFold }, "No final answer is not a completed turn")
    print("PASS: live public summaries, completed process folding, preserved edits/issues/manual expansion, interrupted-turn evidence")
}
