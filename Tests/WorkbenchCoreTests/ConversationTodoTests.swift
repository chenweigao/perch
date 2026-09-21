import Foundation
import WorkbenchCore

func checkConversationTodos() throws {
    func messages(_ json: String) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: Data(json.utf8))
    }
    let write = try messages("""
    [{"id":"a","role":"assistant","created_at":"1","content":[{"type":"tool_use","tool_call_id":"todo1","tool_name":"TodoList","input":{"todos":[{"title":"定位中文输入问题","status":"done"},{"title":"验收输入体验","status":"in_progress"},{"title":"提交修复","status":"pending"}]}}]}]
    """)
    let success = try messages("""
    [{"id":"r","role":"tool","created_at":"2","content":[{"type":"tool_result","tool_call_id":"todo1","output":"Todo list updated.","is_error":false}]}]
    """)
    precondition(ConversationTodo.current(in: write).isEmpty, "Do not publish an unexecuted plan")
    let current = ConversationTodo.current(in: write + success)
    precondition(current.map(\.title) == ["定位中文输入问题", "验收输入体验", "提交修复"])
    precondition(current.map(\.status) == [.done, .inProgress, .pending])
    let query = try messages("""
    [{"id":"q","role":"assistant","created_at":"3","content":[{"type":"tool_use","tool_call_id":"query","tool_name":"TodoList","input":{}}]},
     {"id":"qr","role":"tool","created_at":"4","content":[{"type":"tool_result","tool_call_id":"query","output":"existing list","is_error":false}]}]
    """)
    precondition(ConversationTodo.current(in: write + success + query) == current, "Read mode does not clear the plan")
    let clear = try messages("""
    [{"id":"c","role":"assistant","created_at":"5","content":[{"type":"tool_use","tool_call_id":"clear","tool_name":"TodoList","input":{"todos":[]}}]},
     {"id":"cr","role":"tool","created_at":"6","content":[{"type":"tool_result","tool_call_id":"clear","output":"Todo list cleared.","is_error":false}]}]
    """)
    precondition(ConversationTodo.current(in: write + success + clear).isEmpty)
    let failure = try messages("""
    [{"id":"c","role":"assistant","created_at":"5","content":[{"type":"tool_use","tool_call_id":"clear","tool_name":"TodoList","input":{"todos":[]}}]},
     {"id":"cr","role":"tool","created_at":"6","content":[{"type":"tool_result","tool_call_id":"clear","output":"failed","is_error":true}]}]
    """)
    precondition(ConversationTodo.current(in: write + success + failure) == current)
    precondition(ConversationTodo.floating(in: [], isRunning: true).isEmpty)
    precondition(ConversationTodo.floating(in: write + success, isRunning: false) == current,
                 "An unfinished plan remains visible while the turn is paused or ended")
    let completedWrite = try messages("""
    [{"id":"done","role":"assistant","created_at":"1","content":[{"type":"tool_use","tool_call_id":"todo1","tool_name":"TodoList","input":{"todos":[{"title":"已验证","status":"done"}]}}]}]
    """)
    precondition(ConversationTodo.floating(in: completedWrite + success, isRunning: true).count == 1,
                 "A complete plan stays visible until the running turn ends")
    precondition(ConversationTodo.floating(in: completedWrite + success, isRunning: false).isEmpty)
    precondition(ConversationTodo.current(in: completedWrite + success).count == 1,
                 "Hiding the floating plan must not erase its historical record")
    let nextUser = try messages("""
    [{"id":"next","role":"user","created_at":"7","content":[{"type":"text","text":"开始新的任务"}]}]
    """)
    precondition(ConversationTodo.floating(in: write + success + nextUser, isRunning: true).isEmpty,
                 "A new user turn must not inherit an old plan")
    precondition(ConversationTodo.floating(in: nextUser + write + success, isRunning: true) == current)
    let reminder = try messages("""
    [{"id":"reminder","role":"user","created_at":"7","content":[{"type":"text","text":"<system-reminder>runtime context</system-reminder>"}]}]
    """)
    precondition(ConversationTodo.floating(in: write + success + reminder, isRunning: true) == current,
                 "Injected runtime context is not a new user turn")
    precondition(ConversationTodo.floating(in: write + success + clear, isRunning: true).isEmpty)
    print("PASS: TodoList writes, queries, failure, turn boundaries and floating-list lifecycle")
}
