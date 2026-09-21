import Foundation
import WorkbenchCore

func checkUnifiedWorkspace() throws {
    let host = UUID()
    let terminal = SessionReference(hostID: host, terminalID: "same")
    let kimi = SessionReference(hostID: host, terminalID: "same", kind: .kimi)
    precondition(terminal != kimi && terminal.id != kimi.id)
    // The previous release wrote references without kind and kept terminal IDs in the saved selection.
    let old = """
    {"groups":[{"id":"\(UUID())","name":"已有任务","goal":"保留目标","nextStep":"保留下一步","sessions":[{"hostID":"\(host)","terminalID":"same"}]}],"pinned":[{"session":{"hostID":"\(host)","terminalID":"same"},"title":"已有终端"}],"selectedTerminalID":"\(terminal.id)","reviewedRevisions":{"\(terminal.id)":8}}
    """
    var workspace = try JSONDecoder().decode(LocalWorkspace.self, from: Data(old.utf8))
    precondition(workspace.pinned[0].session == terminal)
    precondition(workspace.groups[0].sessions == [terminal])
    precondition(workspace.reviewedRevisions[terminal.id] == 8 && workspace.destination == .session)
    precondition(workspace.reviewedKimiUpdates.isEmpty)
    workspace.groups[0].sessions.append(kimi)
    workspace.pinned.append(SavedTerminal(session: kimi, title: "对话"))
    workspace.selectedTerminalID = kimi.id
    workspace.lastSessionByGroup[workspace.groups[0].id.uuidString] = kimi.id
    let encoded = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(LocalWorkspace.self, from: encoded)
    precondition(decoded == workspace)
    var tabs = TerminalTabs()
    workspace.pinned.forEach { tabs.open($0.session.id, pinned: true) }
    tabs.select(workspace.selectedTerminalID!)
    precondition(tabs.ids == [terminal.id, kimi.id] && tabs.selectedID == kimi.id)
    tabs.open("preview")
    tabs.open("another-preview")
    precondition(tabs.ids == [terminal.id, kimi.id, "another-preview"])
    tabs.close(kimi.id)
    precondition(tabs.ids.contains(terminal.id))

    func session(_ reason: String? = "completed", busy: Bool = false, pending: String = "none", updated: String = "v1") throws -> KimiSession {
        var value: [String: Any] = ["id":"same", "title":"Test", "updated_at":updated, "busy":busy,
            "pending_interaction":pending, "metadata":["cwd":"/tmp"], "agent_config":["model":"test/model"]]
        if let reason { value["last_turn_reason"] = reason }
        return try KimiWire.decoder().decode(KimiSession.self, from: JSONSerialization.data(withJSONObject: value))
    }
    let completed = try session()
    precondition(workspace.kimiSection(completed, on: host) == .review)
    workspace.markReviewed(completed, on: host)
    precondition(workspace.kimiSection(completed, on: host) == .other)
    let cases: [(KimiSession, WorkQueueSection)] = [
        (try session(updated: "v2"), .review),
        (try session("failed"), .attention),
        (try session("cancelled"), .other),
        (try session(nil), .other),
        (try session("future_reason"), .other),
        (try session(busy: true), .running),
        (try session(busy: true, pending: "approval"), .attention),
        (try session(busy: true, pending: "question"), .attention)
    ]
    for (session, expected) in cases { precondition(workspace.kimiSection(session, on: host) == expected) }
    precondition(workspace.kimiSection(completed, on: UUID()) == .review)
    let pending = try session(busy: true, pending: "approval", updated: "v3")
    workspace.markReviewed(pending, on: host)
    precondition(workspace.reviewedKimiUpdates[kimi.id] == "v1", "reading a result cannot dismiss an approval")
    print("PASS: legacy workspace migration, mixed provider identity, ordered scene restoration, group resume, Kimi queue semantics and review version")
}
