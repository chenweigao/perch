import Foundation
import WorkbenchCore

func checkToolVisibility() throws {
    func messages(_ json: String) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: Data(json.utf8))
    }
    let user = try messages(#"[{"id":"u","role":"user","created_at":"1","content":[{"type":"text","text":"检查代码"}]}]"#)
    let call = try messages(#"[{"id":"a","role":"assistant","created_at":"2","content":[{"type":"text","text":"正文必须一直保留"},{"type":"tool_use","tool_call_id":"t","tool_name":"read","input":{"path":"a.swift"}},{"type":"thinking","thinking":"思考可以折叠"}]}]"#)
    let duplicate = try messages(#"[{"id":"duplicate","role":"assistant","created_at":"3","content":[{"type":"tool_use","tool_call_id":"t","tool_name":"read","input":{"path":"a.swift"}}]}]"#)
    let result = try messages(#"[{"id":"r","role":"tool","created_at":"4","content":[{"type":"tool_result","tool_call_id":"t","output":"完整结果\n第二行","is_error":false}]}]"#)
    let failed = try messages(#"[{"id":"r","role":"tool","created_at":"4","content":[{"type":"tool_result","tool_call_id":"t","output":"permission denied","is_error":true}]}]"#)
    let unspecified = try messages(#"[{"id":"r","role":"tool","created_at":"4","content":[{"type":"tool_result","tool_call_id":"t","output":"returned without status"}]}]"#)
    let live = try KimiWire.decoder().decode([KimiLiveTool].self, from: Data(#"[{"tool_call_id":"t","name":"read","args":{"path":"a.swift"},"last_progress":"读取第 1 行"}]"#.utf8))
    let p = ToolVisibilityProjection()
    func ids(_ value: ToolVisibilityProjection.Snapshot) -> [String] {
        value.messages.flatMap(\.content).filter { $0.type == "tool_use" }.compactMap(\.toolCallId)
    }
    func activityID(_ value: ToolVisibilityProjection.Snapshot) -> String? {
        ConversationTimelineEntry.make(value.messages, isRunning: true).first(where: \.activity)?.id
    }
    let start = p.update(user, sessionID: "kimi", live: live)
    precondition(ids(start) == ["t"] && start.tools["t"]?.status == .running)
    precondition(start.tools["t"]?.output == nil && start.tools["t"]?.progress == .string("读取第 1 行"), "Progress is not a result")
    let gap = p.update(user, sessionID: "kimi")
    precondition(ids(gap) == ["t"] && gap.tools["t"]?.status == .missingResult, "Live handoff gap must not erase a call or imply success")
    let overlap = p.update(user + call + duplicate, sessionID: "kimi", live: live)
    precondition(ids(overlap) == ["t"] && overlap.tools["t"]?.staysVisible == true, "One ID, one tool even across live and duplicate history")
    let ended = p.update(user + call + duplicate, sessionID: "kimi")
    precondition(ended.tools["t"]?.status == .missingResult && ended.tools["t"]?.staysVisible == true)
    let done = p.update(user + call + duplicate + result, sessionID: "kimi", live: live)
    precondition(ids(done) == ["t"] && done.tools["t"]?.status == .succeeded && done.tools["t"]?.staysVisible == false, "Result wins over stale live-running evidence")
    precondition(done.tools["t"]?.output == .string("完整结果\n第二行"))
    precondition([gap, overlap, ended, done].allSatisfy { activityID($0) == activityID(start) }, "One tool row survives handoff")
    let completedRows = ConversationTimelineEntry.make(done.messages)
    precondition(completedRows.flatMap(\.messages).flatMap(\.content).map(\.type) == ["text", "text", "tool_use", "thinking"],
                 "A completed, deduplicated call stays between its surrounding text and thoughts")
    precondition(completedRows.first(where: \.activity)?.id == activityID(start))
    let body = completedRows.filter { !$0.activity }.flatMap(\.messages).flatMap(\.content)
    precondition(body.contains { $0.text == "正文必须一直保留" })
    let process = completedRows.filter(\.activity).flatMap(\.messages).flatMap(\.content)
    precondition(process.contains { $0.thinking == "思考可以折叠" },
                 "Completed thoughts remain available inside the folded process stage")
    let failure = p.update(user + call + failed, sessionID: "kimi", running: ["t"])
    precondition(failure.tools["t"]?.status == .failed && failure.tools["t"]?.staysVisible == true)
    let unknownSuccess = p.update(user + call + unspecified, sessionID: "kimi")
    precondition(unknownSuccess.tools["t"]?.status == .returned, "A result without success evidence must not get a success mark")
    let offline = p.update(user + call, sessionID: "kimi", live: live, running: ["t"], online: false)
    precondition(offline.tools["t"]?.status == .disconnected)
    let offlineDone = p.update(user + call + result, sessionID: "kimi", online: false)
    precondition(offlineDone.tools["t"]?.status == .succeeded, "Disconnection does not erase a recorded outcome")
    let orphan = p.update(user + result + result, sessionID: "other")
    precondition(ids(orphan) == ["t"] && orphan.tools["t"]?.hasCall == false && orphan.tools["t"]?.staysVisible == true)
    precondition(orphan.tools["t"]?.output == .string("完整结果\n第二行"), "Unmatched result stays available")
    let matched = p.update(user + call + result, sessionID: "other")
    precondition(ids(matched) == ["t"] && matched.tools["t"]?.hasCall == true && activityID(matched) == activityID(orphan))
    let newUser = try messages(#"[{"id":"u2","role":"user","created_at":"5","content":[{"type":"text","text":"下一轮"}]}]"#)
    precondition(ToolVisibilityProjection.runningIDs(in: user + call, busy: true) == ["t"])
    precondition(ToolVisibilityProjection.runningIDs(in: user + call + newUser, busy: true).isEmpty, "Old missing results are not running just because the next turn is busy")
    precondition(ToolVisibilityProjection.runningIDs(in: user + call + result, busy: true).isEmpty)
    let late = p.update(user + call + newUser + result, sessionID: "other")
    precondition(ids(late) == ["t"] && late.tools["t"]?.output == done.tools["t"]?.output)
    let retained = ToolVisibilityProjection()
    _ = retained.update(user, sessionID: "s", live: live)
    let nextTurn = retained.update(user + newUser, sessionID: "s")
    precondition(nextTurn.messages.firstIndex { $0.id == "tool-live:t" }! < nextTurn.messages.firstIndex { $0.id == "u2" }!, "Unresolved live evidence belongs to its original turn")
    precondition(retained.update([], sessionID: "new-session").tools.isEmpty, "Never leak live tools across sessions")
    let noID = try messages(#"[{"id":"no-id","role":"tool","created_at":"1","content":[{"type":"tool_result","output":"unmatched","is_error":true}]}]"#)
    let unidentified = p.update(noID, sessionID: "other")
    precondition(unidentified.tools.count == 1 && unidentified.tools.values.first?.status == .failed)
    let approved = VisibleTool(id: "approval", name: "Shell", input: nil, status: .awaitingApproval)
    precondition(approved.staysVisible)
    // Same presentation contract for every native adapter, without invoking any.
    for provider in ["omp", "qoder", "dsh", "codex"] {
        let value = p.update(user + call, sessionID: provider,
                             running: ToolVisibilityProjection.runningIDs(in: user + call, busy: true))
        precondition(ids(value) == ["t"] && value.tools["t"]?.status == .running)
    }
    print("PASS: tool visibility handoff, deduplication, late/orphan results, failure, approval, disconnection and native turn scope")
}
