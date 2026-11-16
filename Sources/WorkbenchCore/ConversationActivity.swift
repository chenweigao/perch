import Foundation

extension String {
    /// Round-28 screening candidate: UTF-16 unit count computed over the UTF-8
    /// bytes (SWAR, 8 bytes per word) instead of the stdlib `utf16.count` walk.
    /// Identity for well-formed UTF-8 (what String storage guarantees):
    /// units = #(non-continuation bytes) + #(four-byte leads) — every scalar
    /// contributes one unit, astral scalars (4-byte leads) a second.
    /// Round-25 probe evidence (archived): this beats stdlib ONLY on first
    /// counts of freshly materialized buffers (3.4-3.6x on fresh UTF8/
    /// JSONDecoder/CoW-appended shapes) and LOSES on cache-hot recounts
    /// (stdlib ~300x faster second-pass; ASCII fast path ~20x; CJK-mixed
    /// ~2.2x) — the Mac in-context screening decides whether the product's
    /// mixed shape nets a gain (queue item ②, round-10 lesson: Mac screening
    /// before committing the round). Pinned byte-exact against utf16.count by
    /// checkSwarUTF16Count (exhaustive scalar sweep + seeded fuzz).
    var utf16CountViaUTF8: Int {
        var contiguous = self
        return contiguous.withUTF8 { bytes -> Int in
            let n = bytes.count
            guard let base = bytes.baseAddress else { return 0 }
            let p = UnsafeRawPointer(base)
            var leads = 0, fourByte = 0, i = 0
            let m7 = 0x7F7F7F7F7F7F7F7F as UInt64
            while i + 8 <= n {
                let word = p.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                // continuation bytes: (b & 0xC0) == 0x80 — zero byte in masked
                let masked = (word & 0xC0C0C0C0C0C0C0C0) ^ 0x8080808080808080
                let contMarks = ~(((masked & m7) &+ m7) | masked | m7)
                // four-byte leads: high nibble == 0xF
                let hi = (word & 0xF0F0F0F0F0F0F0F0) ^ 0xF0F0F0F0F0F0F0F0
                let fMarks = ~(((hi & m7) &+ m7) | hi | m7)
                leads += 8 - contMarks.nonzeroBitCount
                fourByte += fMarks.nonzeroBitCount
                i += 8
            }
            while i < n {
                let b = bytes[i]
                if b & 0xC0 != 0x80 { leads += 1 }
                if b >= 0xF0 { fourByte += 1 }
                i += 1
            }
            return leads + fourByte
        }
    }
}

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
        // A window that is one long turn needs no copy of itself.
        let current = start == 0 ? messages : Array(messages.dropFirst(start))
        // The tools-only exit emits exactly what walking a fresh projection's
        // snapshot would — same order, same values — without materializing the
        // normalized messages, the snapshot, or part copies in its dictionaries
        // (pinned by checkActivityToolsMatchProjection against that walk).
        tools = ToolVisibilityProjection.visibleTools(in: current, live: liveTools,
                                                      running: running, online: online)
        todos = ConversationTodo.floating(in: current, isRunning: isRunning)
        edits = SessionEditStats.derive(from: current)
        var progress = Hasher()
        progress.combine(current.count)
        if let last = current.last {
            progress.combine(last.id)
            progress.combine(last.content.count)
            if let part = last.content.last {
                progress.combine(part.text?.utf16CountViaUTF8 ?? 0)
                progress.combine(part.thinking?.utf16CountViaUTF8 ?? 0)
            }
        }
        for tool in tools {
            progress.combine(tool.id)
            progress.combine(tool.status)
            if tool.status == .running { progress.combine(tool.progress?.display.utf16CountViaUTF8 ?? -1) }
        }
        progressSignature = progress.finalize()
        var written = 0
        for message in current where message.role == "assistant" {
            for part in message.content {
                if part.type == "text" { written += part.text?.utf16CountViaUTF8 ?? 0 }
                else if part.type == "thinking" { written += part.thinking?.utf16CountViaUTF8 ?? 0 }
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
