import Foundation
import WorkbenchCore

func checkNativeAgents() throws {
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
    precondition(running.count == 6 && running[2].activity && running[4].presentation == .progress && running[5].activity, "Latest commentary must remain visible while running")
    let done = ConversationTimelineEntry.make(messages)
    precondition(done.count == 8 && done[2].activity && done.last?.presentation == .message)
    precondition(done[3].messages.contains { $0.id == "n" }, "Runtime notifications must not split a user turn")
    precondition(done.last?.messages[0].content.count == 1 && done.last?.messages[0].content[0].text == "最终结果")
    precondition(done.first { $0.presentation == .thinkingDetails }?.messages[0].content[0].type == "thinking")
    let host = UUID()
    let refs = [SessionKind.kimi, .omp, .qoder, .dsh, .terminal].map { SessionReference(hostID: host, terminalID: "same", kind: $0) }
    precondition(Set(refs.map(\.id)).count == 5)
    var workspace = LocalWorkspace(); refs.forEach { workspace.toggleStar($0) }
    let restored = try JSONDecoder().decode(LocalWorkspace.self, from: JSONEncoder().encode(workspace))
    precondition(restored.starred == refs)
    print("PASS: chronological tool summaries, visible final answer, native provider identity and persistence")
}
