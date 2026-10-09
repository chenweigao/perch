import Foundation
import WorkbenchCore

func checkNativeAgents() throws {
    try checkClaudeTurnBoundaries()
    let unchanged = try NativeAgentWire.decode(NativeSnapshotResponse.self, from: Data(#"{"unchanged":true}"#.utf8))
    precondition(unchanged.snapshot == nil)
    let snapshot = try NativeAgentWire.decode(NativeSnapshotResponse.self, from: Data(#"{"id":"a","provider":"omp","title":"A","cwd":"/tmp","busy":false,"revision":2,"completed":0,"model":"m","permission":{"selected":"write","options":["always-ask","write","yolo"],"scope":"new-session"},"messages":[{"id":"m","role":"assistant","created_at":"now","content":[{"type":"text","text":"中文"}]}],"interactions":[],"error":"runtime failed"}"#.utf8))
    precondition(snapshot.snapshot?.messages.first?.createdAt == "now" && snapshot.snapshot?.error == "runtime failed")
    precondition(snapshot.snapshot?.permission == PermissionCapability(selected: "write", options: ["always-ask", "write", "yolo"], scope: .newSession))
    let receipt = try NativeAgentWire.decode(NativeRequestReceipt.self, from: Data(#"{"id":"request","status":"failed","error":"rejected","runtimeTurnId":"runtime-turn"}"#.utf8))
    precondition(receipt.status == "failed" && receipt.error == "rejected" && receipt.activeTurnId == "runtime-turn", "Receipt errors and runtime turn IDs are payloads")
    let steerReceipt = try NativeAgentWire.decode(NativeRequestReceipt.self, from: Data(#"{"id":"steer","status":"consumed","mode":"steer","turnId":"steered-turn"}"#.utf8))
    precondition(steerReceipt.activeTurnId == "steered-turn" && steerReceipt.mode == "steer", "Steer receipts expose their actual mode and runtime turn")
    precondition(receipt.mode == nil, "A promoted prompt receipt has no steer mode")
    do {
        _ = try NativeAgentWire.decode(NativeSnapshotResponse.self, from: Data(#"{"error":"request failed"}"#.utf8))
        preconditionFailure("expected request error")
    } catch { precondition(error.localizedDescription == "request failed") }
    let raw = """
    [
      {"id":"u","role":"user","created_at":"1","content":[{"type":"text","text":"开始任务"}]},
      {"id":"a","role":"assistant","created_at":"2","content":[{"type":"text","text":"检查代码"},{"type":"tool_use","tool_call_id":"t","tool_name":"bash"}]},
      {"id":"t","role":"tool","created_at":"3","content":[{"type":"tool_result","tool_call_id":"t","output":"ok"}]},
      {"id":"n","role":"user","created_at":"3","content":[{"type":"text","text":"<notification id='task:done'>Background process completed</notification>"}]},
      {"id":"b","role":"assistant","created_at":"4","content":[{"type":"text","text":"继续验证"}]},
      {"id":"c","role":"assistant","created_at":"5","content":[{"type":"tool_use","tool_call_id":"t2","tool_name":"read"}]},
      {"id":"d","role":"assistant","created_at":"6","content":[{"type":"thinking","thinking":"分析"},{"type":"text","text":"最终结果"}]}
    ]
    """
    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: Data(raw.utf8))
    let running = ConversationTimelineEntry.make(Array(messages.dropLast()), isRunning: true)
    precondition(running.count == 5 && running[2].activity && running[3].presentation == .progress && running[4].activity, "Latest commentary must remain visible while running")
    let done = ConversationTimelineEntry.make(messages)
    precondition(done.count == 6 && done[2].activity && done.last?.presentation == .message)
    precondition(done[2].messages.contains { $0.id == "n" }, "Runtime notifications must not split a user turn")
    precondition(done.last?.messages[0].content.count == 1 && done.last?.messages[0].content[0].text == "最终结果")
    precondition(done[4].messages.last?.content.first?.type == "thinking")
    let host = UUID()
    let refs = [SessionKind.kimi, .omp, .qoder, .dsh, .codex, .claude, .terminal].map { SessionReference(hostID: host, terminalID: "same", kind: $0) }
    precondition(Set(refs.map(\.id)).count == 7)
    precondition(SessionKind.codex.label == "Codex")
    var workspace = LocalWorkspace(); refs.forEach { workspace.toggleStar($0) }
    let restored = try JSONDecoder().decode(LocalWorkspace.self, from: JSONEncoder().encode(workspace))
    precondition(restored.starred == refs)
    let codex = try NativeAgentWire.decode(NativeAgentSession.self, from: Data(#"{"id":"0199-thread","provider":"codex","title":"Codex","cwd":"/tmp","busy":false,"archived":false,"updated":0,"completed":0,"pending":0,"model":"gpt-6-astra","error":null}"#.utf8))
    precondition(codex.id == "0199-thread" && codex.provider == .codex)

    let expectedPermissions: [(SessionKind, [String], String, PermissionChangeScope)] = [
        (.kimi, ["manual", "yolo", "auto"], "manual", .nextMessage),
        (.omp, ["always-ask", "write", "yolo"], "always-ask", .newSession),
        (.qoder, ["default", "acceptEdits", "plan", "dontAsk", "auto", "bypassPermissions"], "default", .nextTurn),
        (.dsh, ["runtime-managed"], "runtime-managed", .runtimeManaged),
        (.codex, ["read-only", "workspace-ask", "workspace-auto", "full-access"], "workspace-ask", .newSession),
        (.claude, ["default", "acceptEdits", "plan", "bypassPermissions"], "default", .nextTurn)
    ]
    for (provider, modes, safeDefault, scope) in expectedPermissions {
        precondition(PermissionCatalog.options(for: provider).map(\.id) == modes)
        precondition(PermissionCatalog.safeDefault(for: provider) == safeDefault)
        precondition(PermissionCatalog.scope(for: provider) == scope)
    }
    let dshPermission = PermissionCatalog.capability(for: .dsh)
    precondition(dshPermission.selected == "runtime-managed" && dshPermission.options.isEmpty && !dshPermission.canSelect)
    precondition(PermissionCatalog.option("auto", for: .kimi)?.risk == .dangerous)
    precondition(PermissionCatalog.option("yolo", for: .omp)?.risk == .dangerous)
    precondition(PermissionCatalog.option("bypassPermissions", for: .qoder)?.risk == .dangerous)
    precondition(PermissionCatalog.option("bypassPermissions", for: .claude)?.risk == .dangerous)
    precondition(PermissionCatalog.option("full-access", for: .codex)?.risk == .dangerous)

    let suiteName = "PermissionDefaultsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("auto-review", forKey: "codex.defaultPermissionMode")
    precondition(PermissionDefaults.mode(for: .codex, defaults: defaults) == "workspace-ask")
    defaults.set("full-access", forKey: "codex.defaultPermissionMode")
    precondition(PermissionDefaults.mode(for: .codex, defaults: defaults) == "full-access")
    PermissionDefaults.set("auto", for: .kimi, defaults: defaults)
    precondition(PermissionDefaults.mode(for: .kimi, defaults: defaults) == "auto")
    PermissionDefaults.restoreSafeDefault(for: .kimi, defaults: defaults)
    precondition(PermissionDefaults.mode(for: .kimi, defaults: defaults) == "manual")
    print("PASS: chronological tool summaries, native identity, permission catalogs, wire decoding and default migration")
}

/// Claude uses user-role messages for tool results and injected skill text.
/// Those messages must stay with the actual prompt in pagination and navigation.
private func checkClaudeTurnBoundaries() throws {
    var raw: [[String: Any]] = []
    func append(_ id: String, _ role: String, _ content: [[String: Any]]) {
        raw.append(["id": id, "role": role, "created_at": "", "content": content])
    }
    for turn in 0..<4 {
        append("prompt-\(turn)", "user", [["type": "text", "text": "真实问题 \(turn)"]])
        for tool in 0..<26 {
            let id = "tool-\(turn)-\(tool)"
            append(id, "assistant", [["type": "tool_use", "tool_call_id": id, "tool_name": "Read", "input": ["path": "/fixture/file"]]])
            append("result-" + id, "user", [["type": "tool_result", "tool_call_id": id, "output": "done", "is_error": false]])
        }
        if turn == 1 {
            append("skill", "user", [["type": "text", "text": "Base directory for this skill: /fixture/skill\n\n" + String(repeating: "private instructions\n", count: 6000)]])
            append("synthetic", "user", [["type": "text", "text": "injected context", "source": ["kind": "runtime_context", "provider": "claude"]]])
        }
        append("reply-\(turn)", "assistant", [["type": "text", "text": "回答 \(turn)"]])
    }
    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    precondition(messages.filter(\.isUserPrompt).count == 4)
    let projection = ConversationProjection().update(messages, isRunning: false)
    precondition(projection.navigation.map(\.prompt) == (0..<4).map { "真实问题 \($0)" })
    precondition(projection.navigation.map(\.reply) == (0..<4).map { "回答 \($0)" })
    precondition(projection.results.count == 104)
    precondition(projection.entries.filter { $0.messages.contains { $0.id == "skill" || $0.id == "synthetic" } }.allSatisfy(\.activity))
    precondition(messages.first { $0.id == "skill" }?.content.first?.visibleText == nil)
    let activity = ConversationActivity(messages: messages, isRunning: false)
    precondition(activity.tools.count == 26 && activity.attentionTools.isEmpty,
                 "Tool results must not clear the current turn's activity history")
    print("PASS: Claude user-role tool results, skill context, four navigation turns and 104 linked results")
}
