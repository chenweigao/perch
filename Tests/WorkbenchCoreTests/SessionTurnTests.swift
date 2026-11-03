import Foundation
import WorkbenchCore

func checkSessionTurn() throws {
    func kimi(pending: String? = "none", busy: Bool = false, reason: String? = nil, updated: String = "2026-11-02T10:00:00Z") -> KimiSession {
        var raw: [String: Any] = ["id": "k", "title": "Kimi", "updated_at": updated, "busy": busy,
                                  "metadata": ["cwd": "/tmp"], "agent_config": ["model": "test/model"]]
        if let pending { raw["pending_interaction"] = pending }
        if let reason { raw["last_turn_reason"] = reason }
        // Fixture JSON: a decoding failure is a broken test, not a case to handle.
        return try! KimiWire.decoder().decode(KimiSession.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func native(busy: Bool = false, pending: Int = 0, completed: Int = 0, error: String? = nil, cancelled: Bool = false) -> NativeAgentSession {
        var raw: [String: Any] = ["id": "n", "provider": "claude", "title": "Native", "cwd": "/tmp", "busy": busy, "archived": false,
                                  "updated": 1, "completed": completed, "pending": pending, "model": "m", "cancelled": cancelled]
        if let error { raw["error"] = error }
        return try! NativeAgentWire.decode(NativeAgentSession.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    // The Kimi server reports "none" when nothing is pending; only a named interaction waits.
    precondition(SessionTurn(kimi: kimi()).state == .idle, "\"none\" is not a pending interaction")
    precondition(SessionTurn(kimi: kimi(pending: nil)).state == .idle)
    for interaction in ["approval", "question", "plan_review"] {
        precondition(SessionTurn(kimi: kimi(pending: interaction, busy: true)).state == .waiting, interaction)
    }
    precondition(SessionTurn(kimi: kimi(busy: true)).state == .running)
    precondition(SessionTurn(kimi: kimi(reason: "failed")).state == .failed)
    precondition(SessionTurn(kimi: kimi(reason: "cancelled")).state == .idle)
    let completed = SessionTurn(kimi: kimi(reason: "completed"))
    precondition(completed.state == .finished && completed.completion == "2026-11-02T10:00:00Z")
    precondition(completed.section(reviewed: nil) == .review && completed.section(reviewed: "2026-11-02T10:00:00Z") == .other)
    precondition(SessionTurn(kimi: kimi(pending: "approval", busy: true)).section(reviewed: nil) == .attention)
    precondition(SessionTurn(kimi: kimi(reason: "failed")).section(reviewed: nil) == .attention)
    precondition(kimi(pending: "plan_review").status == "等你处理", "An unnamed pending kind still reads as waiting")

    // Native rows: the reader's decision, then progress, then a failure, then a result.
    precondition(SessionTurn(native: native(busy: true, pending: 1, error: "x")).state == .waiting)
    precondition(SessionTurn(native: native(busy: true, error: "x")).state == .running)
    precondition(SessionTurn(native: native(completed: 3, error: "x")).state == .failed)
    let nativeDone = SessionTurn(native: native(completed: 3, cancelled: true))
    precondition(nativeDone.state == .finished && nativeDone.completion == "3" && nativeDone.section(reviewed: "2") == .review)
    precondition(SessionTurn(native: native()).section(reviewed: nil) == .other)

    // The workspace's sections are the same function.
    var workspace = LocalWorkspace()
    let host = UUID()
    let row = native(completed: 3)
    precondition(workspace.nativeSection(row, on: host) == .review)
    workspace.reviewedKimiUpdates[SessionReference(hostID: host, terminalID: "n", kind: .claude).id] = "3"
    precondition(workspace.nativeSection(row, on: host) == .other)
    precondition(workspace.kimiSection(kimi(reason: "completed"), on: host) == .review)

    // Snapshots: the selected session's listed requests count as pending.
    let snapshot = try NativeAgentWire.decode(NativeAgentSnapshot.self, from: Data(#"""
    {"id":"n","provider":"claude","title":"Native","cwd":"/tmp","busy":true,"revision":4,"completed":2,"model":"m","messages":[],
     "interactions":[{"id":"i","title":"Run swift test"}]}
    """#.utf8))
    precondition(SessionTurn(native: snapshot) == SessionTurn(running: true, pending: true, completion: "2"))
    let session = String(data: try JSONSerialization.data(withJSONObject: [
        "id": "k", "title": "Kimi", "updated_at": "u", "busy": true, "pending_interaction": "none",
        "metadata": ["cwd": "/tmp"], "agent_config": ["model": "test/model"]]), encoding: .utf8)!
    let kimiSnapshot = try KimiWire.decoder().decode(KimiSnapshot.self, from: Data("""
    {"as_of_seq":1,"epoch":"e","session":\(session),"messages":{"items":[],"has_more":false},
     "pending_approvals":[{"approval_id":"a","tool_name":"Shell","action":"run","tool_input_display":{},"agent_id":"main"}],"pending_questions":[]}
    """.utf8))
    precondition(SessionTurn(kimi: kimiSnapshot).state == .waiting, "A listed approval waits even before the row says so")

    // Notifications compare the same facts: an approval after "none" calls the reader.
    var events = TaskEventTracker()
    precondition(events.observe(SessionTurn(kimi: kimi(busy: true)), id: "k", online: true) == nil)
    precondition(events.observe(SessionTurn(kimi: kimi(pending: "approval", busy: true)), id: "k", online: true) == .needsInput)
    precondition(events.observe(SessionTurn(kimi: kimi(reason: "completed")), id: "k", online: true) == .completed)
    print("PASS: session turn facts for Kimi and native rows and snapshots, shared precedence, sections and notification edges")
}
