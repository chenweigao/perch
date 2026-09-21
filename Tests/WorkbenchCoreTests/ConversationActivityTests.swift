import Foundation
import WorkbenchCore

func checkConversationActivity() throws {
    func messages(_ json: String) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: Data(json.utf8))
    }
    let user = try messages(#"[{"id":"u","role":"user","created_at":"","content":[{"type":"text","text":"Inspect files"}]}]"#)
    let call = try messages(#"[{"id":"a","role":"assistant","created_at":"","content":[{"type":"tool_use","tool_call_id":"t","tool_name":"Read","input":{"path":"Sample.swift"}}]}]"#)
    let live = try KimiWire.decoder().decode([KimiLiveTool].self, from: Data(#"[{"tool_call_id":"t","name":"Read","args":{"path":"Sample.swift"},"last_progress":"Read 20 lines"}]"#.utf8))
    let result = try messages(#"[{"id":"r","role":"tool","created_at":"","content":[{"type":"tool_result","tool_call_id":"t","is_error":false,"output":"Done"}]}]"#)
    let active = ConversationActivity(messages: user + call + call, isRunning: true, liveTools: live, isThinking: true)
    precondition(active.title == "Reading files…" && active.activeTools.count == 1 && active.tools.count == 1)
    precondition(active.tools[0].progress?.string == "Read 20 lines")
    let completed = ConversationActivity(messages: user + call + result, isRunning: true, liveTools: live)
    precondition(completed.activeTools.isEmpty && completed.tools[0].status == .succeeded, "Results beat stale live events")
    let offline = ConversationActivity(messages: user + call, isRunning: true, liveTools: live, online: false, pendingCount: 1)
    precondition(offline.title == "Connection lost" && !offline.animates && offline.activeTools.isEmpty)
    precondition(offline.tools[0].status == .disconnected)
    let pending = ConversationActivity(messages: user + call, isRunning: true, liveTools: live, pendingCount: 1)
    precondition(pending.title == "Needs your input" && !pending.animates)
    precondition(ConversationActivity(messages: user, isRunning: true, isStopping: true).title == "Stopping…")
    let next = try messages(#"[{"id":"u2","role":"user","created_at":"","content":[{"type":"text","text":"Next"}]}]"#)
    let nextTurn = ConversationActivity(messages: user + call + next, isRunning: true)
    precondition(nextTurn.tools.isEmpty, "Previous turn tools must not appear as current activity")
    let missing = ConversationActivity(messages: user + call, isRunning: false)
    precondition(missing.isVisible && missing.needsAttention && missing.title == "Review tool results")
    let idle = ConversationActivity(messages: user + call + result, isRunning: false)
    precondition(!idle.isVisible)
    let failedResult = try messages(#"[{"id":"r","role":"tool","created_at":"","content":[{"type":"tool_result","tool_call_id":"t","is_error":true,"output":"Failed"}]}]"#)
    precondition(ConversationActivity(messages: user + call + failedResult, isRunning: false).needsAttention)
    print("Conversation activity: live/history dedup, result precedence, disconnect, approval, stop and turn isolation passed")
}
