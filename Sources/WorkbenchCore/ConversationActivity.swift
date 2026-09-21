import Foundation

/// A summary of the current user turn, using the same result precedence as the transcript.
public struct ConversationActivity {
    public let tools: [VisibleTool]
    public let todos: [ConversationTodo]
    public let title: String
    public let operationDescription: String?
    public let symbol: String
    public let needsAttention: Bool
    public let animates: Bool
    public let isVisible: Bool
    public var activeTools: [VisibleTool] { tools.filter { $0.status == .running } }
    public var attentionTools: [VisibleTool] { tools.filter { $0.staysVisible && $0.status != .running } }
    public var completedSteps: Int { todos.filter { $0.status == .done }.count }

    public init(messages: [KimiMessage], isRunning: Bool, liveTools: [KimiLiveTool] = [],
                running: Set<String> = [], online: Bool = true, isThinking: Bool = false,
                isResponding: Bool = false, pendingCount: Int = 0, isStopping: Bool = false) {
        let start = messages.lastIndex { $0.role == "user" && !$0.content.allSatisfy(\.isRuntimeContext) } ?? 0
        let current = Array(messages.dropFirst(start))
        let projection = ToolVisibilityProjection().update(current, sessionID: "activity", live: liveTools,
                                                          running: running, online: online)
        tools = projection.messages.flatMap(\.content).filter { $0.type == "tool_use" }
            .compactMap { projection.tools[$0.toolCallId ?? ""] }
        todos = ConversationTodo.floating(in: current, isRunning: isRunning)
        let active = tools.filter { $0.status == .running }
        let description = active.first?.input?["description"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        operationDescription = online && isRunning && pendingCount == 0 && !isStopping && description?.isEmpty == false
            ? description : nil
        let uncertain = tools.contains { $0.staysVisible && $0.status != .running }
        needsAttention = !online || pendingCount > 0 || uncertain
        animates = online && isRunning && pendingCount == 0 && !isStopping
        isVisible = !online || isRunning || pendingCount > 0 || !todos.isEmpty || uncertain
        if !online { title = "Connection lost"; symbol = "wifi.exclamationmark" }
        else if pendingCount > 0 { title = "Needs your input"; symbol = "hand.raised" }
        else if isStopping { title = "Stopping…"; symbol = "stop.circle" }
        else if isRunning, let tool = active.first {
            switch tool.name.lowercased() {
            case "read", "read_file", "readfile": title = "Reading files…"
            case "edit", "write", "edit_file", "write_file", "apply_patch": title = "Editing files…"
            case "bash", "shell", "exec_command": title = "Running command…"
            default: title = "Working…"
            }
            symbol = "terminal"
        } else if isRunning && isThinking { title = "Thinking…"; symbol = "brain" }
        else if isRunning && isResponding { title = "Writing response…"; symbol = "text.alignleft" }
        else if isRunning { title = "Working…"; symbol = "ellipsis" }
        else if uncertain { title = "Review tool results"; symbol = "exclamationmark.circle" }
        else { title = "Plan remaining"; symbol = "checklist" }
    }

    public static func summary(of tool: VisibleTool) -> String {
        tool.input?["description"].string
            ?? tool.input?["file_path"].string ?? tool.input?["path"].string ?? tool.name
    }
    public static func status(of tool: VisibleTool) -> String {
        switch tool.status {
        case .running: return "Running"
        case .succeeded: return "Completed"
        case .returned: return "Returned"
        case .failed: return "Failed"
        case .missingResult: return "Result missing"
        case .disconnected: return "Status unknown"
        case .awaitingApproval: return "Awaiting approval"
        }
    }
}
