import Foundation

/// Folding is based on the turn's available output, never on an assumed final summary.
public struct ConversationTimelineEntry: Identifiable, Equatable {
    public enum Presentation: Equatable { case message, activity, commentary, progress, thinkingPreview, thinkingDetails, record, thinkingRecord, emptyOutput, processFold }
    public private(set) var messages: [KimiMessage]
    public private(set) var presentation: Presentation
    public var activity: Bool { presentation == .activity }
    public var isProcess: Bool { [.activity, .thinkingPreview, .thinkingDetails, .thinkingRecord].contains(presentation) }
    public var isExploration: Bool {
        activity && messages.allSatisfy { message in
            message.content.allSatisfy { $0.type == "tool_use" && ToolPresentation.isExploration($0.toolName ?? "") }
        }
    }
    private let partOffset: Int
    public var id: String {
        // A tool can start in live state, arrive as an orphan result, then gain its
        // persisted call. Its activity host must survive all three source IDs.
        if presentation == .activity, let first = messages.first?.content.first, let toolID = first.toolCallId {
            return "activity:tool:\(toolID)"
        }
        // Folded process groups carry only their first message; the dedicated
        // channel keeps their measurements apart from the rows they replace.
        if presentation == .processFold {
            return "process-fold:\(messages[0].id):\(partOffset)"
        }
        // A thought that later gains tools keeps its original reading anchor.
        if messages.first?.content.first?.type == "thinking" {
            return "thinking:\(messages[0].id):\(partOffset)"
        }
        let channel: String
        switch presentation {
        case .thinkingPreview, .thinkingDetails, .thinkingRecord: channel = "thinking"
        case .message, .progress, .record: channel = "text"
        default: channel = "\(presentation)"
        }
        return "\(channel):\(messages[0].id):\(partOffset)"
    }

    public static func make(_ messages: [KimiMessage], isRunning: Bool = false) -> [Self] {
        var entries: [Self] = [], turn: [KimiMessage] = []
        func visible(_ part: KimiPart) -> Bool {
            (part.type == "text" && !part.isRuntimeContext && !(part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                || ["image", "file", "video"].contains(part.type)
        }
        func thinking(_ part: KimiPart) -> Bool { part.type == "thinking" && !(part.thinking ?? "").isEmpty }
        func narrativeSource(_ part: KimiPart) -> Bool {
            part.type == "thinking" && part.source?["kind"].string == "activity_summary"
        }
        func flush(running: Bool) {
            guard !turn.isEmpty else { return }
            let answer = turn.lastIndex { $0.role == "assistant" && $0.content.contains(where: visible) && !$0.content.contains { $0.type == "tool_use" } }
            let final = answer.flatMap { index in turn[(index + 1)...].contains { $0.content.contains { $0.type == "tool_use" } } ? nil : index }
            // Preserve source order across thoughts, progress, tools and runtime context.
            var phases: [(message: KimiMessage, offset: Int)] = []
            for message in turn {
                for (offset, part) in message.content.enumerated() where visible(part) || thinking(part) || part.type == "tool_use" || part.isRuntimeContext {
                    phases.append((KimiMessage(id: message.id, role: message.role, content: [part], createdAt: message.createdAt, metadata: message.metadata), offset))
                }
            }
            let hasText = phases.contains { visible($0.message.content[0]) }
            let lastText = phases.lastIndex { visible($0.message.content[0]) }
            let process: [Presentation] = [.activity, .thinkingDetails, .thinkingRecord]
            for (index, phase) in phases.enumerated() {
                let presentation: Presentation
                let part = phase.message.content[0]
                if part.type == "tool_use" || part.isRuntimeContext {
                    presentation = .activity
                } else if thinking(part) {
                    presentation = running && index == phases.count - 1 ? .thinkingPreview
                        : !running && !hasText ? .thinkingRecord : .thinkingDetails
                } else if !running, let final, phase.message.id == turn[final].id {
                    presentation = .message
                } else {
                    presentation = !running && final == nil && index == lastText ? .record : .progress
                }
                // Process records share one bounded host between visible messages.
                // Keep provider narrative sources on their own row so presentation
                // can hand that stable anchor between the live bar and history.
                if process.contains(presentation), let previous = entries.last,
                   process.contains(previous.presentation), previous.messages.count < 24,
                   !narrativeSource(part),
                   !previous.messages.contains(where: { $0.content.contains(where: narrativeSource) }),
                   index > 0 {
                    entries[entries.count - 1].messages.append(phase.message)
                    if presentation == .activity { entries[entries.count - 1].presentation = .activity }
                } else {
                    entries.append(Self(messages: [phase.message], presentation: presentation, partOffset: phase.offset))
                }
            }
            if !hasText && !phases.contains(where: { thinking($0.message.content[0]) }) && !running && turn.contains(where: { $0.role == "assistant" }) {
                entries.append(Self(messages: [turn[0]], presentation: .emptyOutput, partOffset: 0))
            }
            turn = []
        }
        for message in messages where !message.content.isEmpty {
            if message.role == "tool" || message.content.allSatisfy({ $0.type == "tool_result" }) { continue }
            // Compaction summaries keep their own row but never open a turn.
            if message.isUserPrompt || message.isCompactionSummary {
                flush(running: false); entries.append(Self(messages: [message], presentation: .message, partOffset: 0))
            } else { turn.append(message) }
        }
        flush(running: isRunning)
        return entries
    }

    /// Preserve the first row's source offset: one message may contain multiple
    /// process groups separated by visible answers or narrative anchors.
    public static func processFold(firstEntry: Self) -> Self {
        Self(messages: [firstEntry.messages[0]], presentation: .processFold, partOffset: firstEntry.partOffset)
    }
}

/// History folds each completed turn's process (tools, thoughts, intermediate
/// text) behind one disclosure, leaving prompts and final answers visible.
/// The running turn keeps its live process. Expansion is view state; folded
/// rows stay fully intact and re-mount in place.
///
/// Folding is decided per turn: once a turn produced its final answer, every
/// process row folds — including failed tools, whose count the fold header
/// reports — because the agent has already absorbed the outcome. A turn that
/// ended without a final answer (interrupted, disconnected) keeps its failed
/// or unresolved tools visible: there the process itself is the diagnosis.
public enum ConversationProcessFold {
    /// Presentation shape only: whether a row can fold into a process group.
    /// Tool outcomes are weighed by `fold`, which knows the turn's completion.
    public static func foldable(_ row: ConversationPresentationModel.Row) -> Bool {
        switch row.entry.presentation {
        case .activity, .commentary, .progress, .thinkingPreview, .thinkingDetails, .record, .thinkingRecord:
            return true
        case .message, .emptyOutput, .processFold:
            return false
        }
    }

    /// Tools the record cannot account for in a row: still waiting on the user or
    /// missing their result. A returned error is an observed outcome the agent
    /// read and continued from, not an unresolved call.
    public static func unresolvedCount(_ row: ConversationPresentationModel.Row) -> Int {
        row.tools.values.filter { $0.staysVisible && $0.status != .running }.count
    }

    public static func unresolvedCount(_ rows: [ConversationPresentationModel.Row]) -> Int {
        rows.reduce(0) { $0 + unresolvedCount($1) }
    }

    private static func isUserPrompt(_ row: ConversationPresentationModel.Row) -> Bool {
        row.entry.presentation == .message && row.entry.messages.first?.isUserPrompt == true
    }

    /// A final assistant answer: the settled message row, or a compaction boundary
    /// (which ends the prior turn). A trailing record or empty output means the turn
    /// never concluded with an answer — there, failures stay visible.
    private static func completesTurn(_ row: ConversationPresentationModel.Row) -> Bool {
        row.entry.presentation == .message && !isUserPrompt(row)
    }

    public static func fold(rows: [ConversationPresentationModel.Row], isRunning: Bool) -> [ConversationPresentationModel.Row] {
        let lastPrompt = rows.lastIndex(where: isUserPrompt)
        // For each index, whether its turn (back to the preceding prompt) ended
        // with a final answer. Computed backwards: an answer covers the rows
        // between it and its prompt.
        var turnCompleted = [Bool](repeating: false, count: rows.count)
        var seenAnswer = false
        if !rows.isEmpty {
            for index in stride(from: rows.count - 1, through: 0, by: -1) {
                if completesTurn(rows[index]) { seenAnswer = true }
                turnCompleted[index] = seenAnswer
                if isUserPrompt(rows[index]) { seenAnswer = false }
            }
        }
        var result: [ConversationPresentationModel.Row] = []
        var pending: [ConversationPresentationModel.Row] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let entry = ConversationTimelineEntry.processFold(firstEntry: pending[0].entry)
            result.append(ConversationPresentationModel.Row(entry: entry, tools: [:], activity: nil, foldedRows: pending))
            pending = []
        }
        for (index, row) in rows.enumerated() {
            let live = isRunning && lastPrompt != nil && index > lastPrompt!
            // Completed turns fold every process row; in an interrupted turn a
            // failed or unresolved tool row remains visible on its own.
            let foldable = foldable(row) && (turnCompleted[index] || unresolvedCount(row) == 0)
            if foldable, !live {
                pending.append(row)
            } else {
                flush()
                result.append(row)
            }
        }
        flush()
        return result
    }
}

extension KimiConversation {
    /// Include volatile output in the same folding policy as persisted messages.
    public var displayMessages: [KimiMessage] {
        guard let live else { return messages }
        let start = messages.lastIndex { $0.isUserPrompt }.map { $0 + 1 } ?? 0
        let last = messages[start...].last { $0.role == "assistant" }
        var parts: [KimiPart] = []
        for (type, value) in [("thinking", live.thinkingText), ("text", live.assistantText)] where !value.isEmpty {
            if last?.content.contains(where: { type == "text" ? $0.text == value : $0.thinking == value }) == true { continue }
            parts.append(KimiPart(type: type, text: type == "text" ? value : nil, thinking: type == "thinking" ? value : nil,
                                  toolCallId: nil, toolName: nil, input: nil, output: nil, isError: nil, source: nil, fileId: nil, name: nil))
        }
        guard !parts.isEmpty else { return messages }
        return messages + [KimiMessage(id: "live:\(live.turnId)", role: "assistant", content: parts, createdAt: "", metadata: nil)]
    }
}
