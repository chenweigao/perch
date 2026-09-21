import Foundation
import WorkbenchCore

func checkNativeAgents() throws {
    let unchanged = try NativeAgentWire.decode(NativeSnapshotResponse.self, from: Data(#"{"unchanged":true}"#.utf8))
    precondition(unchanged.snapshot == nil)
    let snapshot = try NativeAgentWire.decode(NativeSnapshotResponse.self, from: Data(#"{"id":"a","provider":"omp","title":"A","cwd":"/tmp","busy":false,"revision":2,"model":"m","messages":[{"id":"m","role":"assistant","created_at":"now","content":[{"type":"text","text":"中文"}]}],"interactions":[],"error":"runtime failed"}"#.utf8))
    precondition(snapshot.snapshot?.messages.first?.createdAt == "now" && snapshot.snapshot?.error == "runtime failed")
    let receipt = try NativeAgentWire.decode(NativeRequestReceipt.self, from: Data(#"{"id":"request","status":"failed","error":"rejected"}"#.utf8))
    precondition(receipt.status == "failed" && receipt.error == "rejected", "Receipt errors are payloads, not request errors")
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
    precondition(running.count == 4 && running[1].activity && running.last?.presentation == .progress, "Latest commentary must remain visible while running")
    let done = ConversationTimelineEntry.make(messages)
    precondition(done.count == 6 && done[1].activity && done.last?.presentation == .message)
    precondition(done[1].messages.contains { $0.id == "n" }, "Runtime notifications must not split a user turn")
    precondition(done.last?.messages[0].content.count == 1 && done.last?.messages[0].content[0].text == "最终结果")
    precondition(done.first { $0.presentation == .thinkingDetails }?.messages[0].content[0].type == "thinking")
    let host = UUID()
    let refs = [SessionKind.kimi, .omp, .qoder, .terminal].map { SessionReference(hostID: host, terminalID: "same", kind: $0) }
    precondition(Set(refs.map(\.id)).count == 4)
    var workspace = LocalWorkspace(); refs.forEach { workspace.toggleStar($0) }
    let restored = try JSONDecoder().decode(LocalWorkspace.self, from: JSONEncoder().encode(workspace))
    precondition(restored.starred == refs)
    print("PASS: per-turn activity grouping, visible final answer, native provider identity and persistence")
}
