import Foundation

/// A summary of the current user turn, using the same result precedence as the transcript.
public struct ConversationActivity {
    public let tools: [VisibleTool]
    public let todos: [ConversationTodo]
    /// This turn's edit churn from its own edit-class tool calls, the figure the
    /// transcript's process fold shows; nil when nothing resolved, so nothing
    /// shows zeros.
    public let edits: (perFile: [String: SessionEditStat], total: SessionEditStat)?
    /// Changes whenever the turn shows progress: a new or longer message, a
    /// tool starting, reporting or finishing, a plan step. Stable within a
    /// process only; the status line times a suspected stall from its last change.
    public let progressSignature: Int
    /// Text and thinking the agent wrote this turn, in UTF-16 units: a number
    /// that only grows while output arrives, so the status line can show it.
    public let outputCharacters: Int
    public let title: String
    public let operationDescription: String?
    public let symbol: String
    public let needsAttention: Bool
    /// A stop was requested and nothing outranks it (a lost connection or a pending decision).
    public let isStopping: Bool
    public let animates: Bool
    public let isVisible: Bool
    public var activeTools: [VisibleTool] { tools.filter { $0.status == .running } }
    public var attentionTools: [VisibleTool] { tools.filter { $0.staysVisible && $0.status != .running } }
    public var completedSteps: Int { todos.filter { $0.status == .done }.count }
    /// The plan item in progress: the most specific name for what the turn does.
    public var currentStep: String? {
        guard let title = todos.first(where: { $0.status == .inProgress })?.title
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    public init(messages: [KimiMessage], isRunning: Bool, liveTools: [KimiLiveTool] = [],
                running: Set<String> = [], online: Bool = true, isThinking: Bool = false,
                isResponding: Bool = false, pendingCount: Int = 0, isStopping: Bool = false) {
        let start = messages.lastIndex { $0.isUserPrompt } ?? 0
        let current = Array(messages.dropFirst(start))
        let projection = ToolVisibilityProjection().update(current, sessionID: "activity", live: liveTools,
                                                          running: running, online: online)
        tools = projection.messages.flatMap(\.content).filter { $0.type == "tool_use" }
            .compactMap { projection.tools[$0.toolCallId ?? ""] }
        todos = ConversationTodo.floating(in: current, isRunning: isRunning)
        edits = SessionEditStats.derive(from: current)
        var progress = Hasher()
        progress.combine(current.count)
        if let last = current.last {
            progress.combine(last.id)
            progress.combine(last.content.count)
            if let part = last.content.last {
                progress.combine(part.text?.utf16.count ?? 0)
                progress.combine(part.thinking?.utf16.count ?? 0)
            }
        }
        for tool in tools {
            progress.combine(tool.id)
            progress.combine(tool.status)
            if tool.status == .running { progress.combine(tool.progress?.display.utf16.count ?? -1) }
        }
        progressSignature = progress.finalize()
        var written = 0
        for message in current where message.role == "assistant" {
            for part in message.content {
                if part.type == "text" { written += part.text?.utf16.count ?? 0 }
                else if part.type == "thinking" { written += part.thinking?.utf16.count ?? 0 }
            }
        }
        outputCharacters = written
        let active = tools.filter { $0.status == .running }
        let description = active.first?.input?["description"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        operationDescription = online && isRunning && pendingCount == 0 && !isStopping && description?.isEmpty == false
            ? description : nil
        let uncertain = tools.contains { $0.staysVisible && $0.status != .running }
        needsAttention = !online || pendingCount > 0 || uncertain
        self.isStopping = online && pendingCount == 0 && isStopping
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
        status(of: tool, exitCode: tool.exitCodeReport)
    }
    /// The tool card's words, shared by the task panel's tool rows. The card resolves
    /// the exit code once per body evaluation and passes it in.
    public static func status(of tool: VisibleTool, exitCode: Int?) -> String {
        let state: String
        switch tool.status {
        case .running: state = L("Running")
        case .succeeded: state = L("Completed")
        case .returned: state = L("Returned")
        case .failed:
            if let exitCode { state = L("Exit code \(exitCode)") } else { state = L("Failed") }
        case .missingResult: state = L("Result not received")
        case .disconnected: state = L("Disconnected · Status unknown")
        case .awaitingApproval: state = L("Needs approval")
        }
        return tool.hasCall ? state : L("\(state) · Call record missing")
    }
}
