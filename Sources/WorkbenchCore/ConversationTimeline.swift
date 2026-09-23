import Foundation

/// Folding is based on the turn's available output, never on an assumed final summary.
public struct ConversationTimelineEntry: Identifiable, Equatable {
    public enum Presentation: Equatable { case message, activity, commentary, progress, thinkingPreview, thinkingDetails, record, thinkingRecord, emptyOutput }
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
