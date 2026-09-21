import Foundation
import WorkbenchCore

func checkSessionManagement() throws {
    let host = UUID()
    let kimi = SessionReference(hostID: host, terminalID: "conversation", kind: .kimi)
    let terminal = SessionReference(hostID: host, terminalID: "terminal")
    var workspace = LocalWorkspace()
    workspace.groups = [WorkItemGroup(name: "工作", goal: "", nextStep: "保留", sessions: [kimi, terminal])]
    workspace.pinned = [SavedTerminal(session: kimi, title: "Kimi"), SavedTerminal(session: terminal, title: "Terminal")]
    workspace.selectedTerminalID = kimi.id
    workspace.destination = .session
    workspace.lastSessionByGroup[workspace.groups[0].id.uuidString] = kimi.id
    workspace.toggleStar(kimi); workspace.toggleStar(terminal); workspace.toggleStar(kimi)
    precondition(workspace.starred == [terminal])
    workspace.archivedTerminals.insert(terminal)
    workspace.rename(kimi, title: "  我的会话  ")
    let sameIDOtherHost = SessionReference(hostID: UUID(), terminalID: kimi.terminalID, kind: .kimi)
    precondition(workspace.displayTitle("服务端标题", for: kimi) == "我的会话")
    precondition(workspace.displayTitle("原名", for: sameIDOtherHost) == "原名")
    let encoded = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(LocalWorkspace.self, from: encoded)
    precondition(decoded == workspace)
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    legacy.removeValue(forKey: "sessionTitles")
    let migrated = try JSONDecoder().decode(LocalWorkspace.self, from: JSONSerialization.data(withJSONObject: legacy))
    precondition(migrated.sessionTitles.isEmpty && migrated.groups == workspace.groups)
    var restored = decoded
    restored.rename(kimi, title: " ")
    precondition(restored.displayTitle("服务端标题", for: kimi) == "服务端标题")
    workspace.removeSession(kimi)
    precondition(workspace.sessionTitles[kimi.id] == nil)
    precondition(workspace.groups[0].sessions == [terminal] && workspace.groups[0].nextStep == "保留")
    precondition(workspace.pinned.map(\.session) == [terminal] && workspace.selectedTerminalID == nil)
    precondition(workspace.lastSessionByGroup.isEmpty && workspace.archivedTerminals.contains(terminal))
    // Ordered async writes cannot overwrite the final flushed scene during shutdown.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("awb-management-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("workspace.json")
    let writer = WorkspaceWriter(url: url)
    for n in 0..<20 {
        var intermediate = workspace; intermediate.groups[0].nextStep = "\(n)"
        writer.save(intermediate) { error in precondition(error == nil) }
    }
    try writer.flush(workspace)
    let final = try WorkspaceFile.load(from: url)
    precondition(final == workspace)

    func conversation(_ id: String, archived: Bool = false) throws -> KimiConversation {
        let json = """
        {"as_of_seq":5,"epoch":"e1","session":{"id":"\(id)","title":"Cache","updated_at":"v1","busy":false,"archived":\(archived),"metadata":{"cwd":"/tmp"},"agent_config":{"model":"test"}},"messages":{"items":[],"has_more":false},"pending_approvals":[],"pending_questions":[]}
        """
        return KimiConversation(try KimiWire.decoder().decode(KimiSnapshot.self, from: Data(json.utf8)))
    }
    var cache = KimiConversationCache(capacity: 2)
    cache.store(try conversation("a")); cache.store(try conversation("b"))
    precondition(cache.take("a")?.lastSeq == 5)
    cache.store(try conversation("c"))
    precondition(cache.take("b") == nil && cache.take("a") != nil)
    cache.remove("a"); precondition(cache.take("a") == nil)
    let archived = try conversation("archived", archived: true)
    precondition(archived.snapshot.session.archived == true)
    print("PASS: favorites, local archive persistence, deletion reference cleanup, ordered background saves, bounded recent conversation cache")
}
