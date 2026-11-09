import Foundation

/// Folding is based on the turn's available output, never on an assumed final summary.
public struct ConversationTimelineEntry: Identifiable, Equatable {
    public enum Presentation: Equatable { case message, activity, commentary, progress, thinkingPreview, thinkingDetails, record, thinkingRecord, emptyOutput, processFold }
    public private(set) var messages: [KimiMessage]
    public private(set) var presentation: Presentation
    public var activity: Bool { presentation == .activity }
    public var isProcess: Bool { [.activity, .thinkingPreview, .thinkingDetails, .thinkingRecord].contains(presentation) }
    public var isExploration: Bool {
        activity && processPhase == .exploring
    }
    public var processPhase: ActivityNarrativePhase? {
        let phases = messages.flatMap(\.content).compactMap { ToolPresentation.processPhase($0) }
        guard let first = phases.first else { return nil }
        return phases.allSatisfy { $0 == first } ? first : .mixed
    }
    /// Stable within a stage as new records append; tool IDs also route find hits.
    public var processPartIDs: [String] {
        messages.enumerated().map { index, message in
            message.content.first?.toolCallId.map { "tool:" + $0 } ?? "part:\(message.id):\(index)"
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
            var groupPhase: ActivityNarrativePhase?
            var canGroup = false
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
                let nextPhase = ToolPresentation.processPhase(part)
                let process = (thinking(part) && part.source?["kind"].string != "activity_summary") || nextPhase != nil
                // A phase follows the work, not the model's think/tool alternation.
                // Prose, edits and validation are boundaries. Unknown shell work
                // can share exploration's stage, but gives the whole stage a
                // neutral execution label rather than fragmenting it by syntax.
                if process, canGroup, index > 0,
                   nextPhase == nil || groupPhase == nil || nextPhase == groupPhase
                    || (nextPhase != .validating && groupPhase != .validating) {
                    entries[entries.count - 1].messages.append(phase.message)
                    if nextPhase != nil || groupPhase != nil {
                        entries[entries.count - 1].presentation = .activity
                    } else {
                        entries[entries.count - 1].presentation = presentation
                    }
                    if let nextPhase { groupPhase = groupPhase == nil || groupPhase == nextPhase ? nextPhase : .mixed }
                } else {
                    entries.append(Self(messages: [phase.message], presentation: presentation, partOffset: phase.offset))
                    groupPhase = nextPhase
                }
                canGroup = process
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
/// Folding is uniform: every non-live process row folds, whatever it carries —
/// failed tools, pending approvals and edit receipts included. Their outcomes
/// are history; the fold header's counts are the only residue.
public enum ConversationProcessFold {
    /// Presentation shape only: whether a row can fold into a process group.
    public static func foldable(_ row: ConversationPresentationModel.Row) -> Bool {
        switch row.entry.presentation {
        case .activity, .commentary, .progress, .thinkingPreview, .thinkingDetails, .record, .thinkingRecord:
            return true
        case .message, .emptyOutput, .processFold:
            return false
        }
    }

    private static func isUserPrompt(_ row: ConversationPresentationModel.Row) -> Bool {
        row.entry.presentation == .message && row.entry.messages.first?.isUserPrompt == true
    }

    public static func fold(rows: [ConversationPresentationModel.Row], isRunning: Bool) -> [ConversationPresentationModel.Row] {
        let lastPrompt = rows.lastIndex(where: isUserPrompt)
        var result: [ConversationPresentationModel.Row] = []
        var pending: [ConversationPresentationModel.Row] = []
        var pendingLive = false
        func flush() {
            guard !pending.isEmpty else { return }
            let entry = ConversationTimelineEntry.processFold(firstEntry: pending[0].entry)
            result.append(ConversationPresentationModel.Row(entry: entry, tools: [:], activity: nil, foldedRows: pending, live: pendingLive))
            pending = []
            pendingLive = false
        }
        for (index, row) in rows.enumerated() {
            // Live rows fold too: the running turn's process rides one auto-opened
            // disclosure (PI's TurnProcess), marked live so it settles in place.
            // The forming answer (progress/commentary) stays outside — it is what
            // the turn produces, not part of what it did.
            let live = isRunning && lastPrompt != nil && index > lastPrompt!
            // The forming answer and the narrative's visible anchor stay outside
            // the live disclosure: they are what the turn shows, not its process.
            let visibleContent = row.entry.presentation == .progress || row.entry.presentation == .commentary
                || row.activity?.isAnchor == true
            let foldableNow = foldable(row) && !(live && visibleContent)
            if foldableNow {
                if pendingLive && !live { flush() }
                pendingLive = pendingLive || live
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
