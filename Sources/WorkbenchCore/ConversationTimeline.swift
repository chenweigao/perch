import Foundation

/// Folding is based on the turn's available output, never on an assumed final summary.
public struct ConversationTimelineEntry: Identifiable, Equatable {
    public enum Presentation: Equatable { case message, activity, commentary, progress, thinkingPreview, thinkingDetails, record, thinkingRecord, emptyOutput }
    public let messages: [KimiMessage]
    public let presentation: Presentation
    public var activity: Bool { presentation == .activity }
    private let partOffset: Int
    private var activityAnchor: String? = nil
    public var id: String {
        // A tool can start in live state, arrive as an orphan result, then gain its
        // persisted call. Its activity host must survive all three source IDs.
        if presentation == .activity, let activityAnchor { return "activity:turn:\(activityAnchor)" }
        if presentation == .activity, let toolID = messages.flatMap(\.content).compactMap(\.toolCallId).first {
            return "activity:tool:\(toolID)"
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
        var turnAnchor: String?
        func visible(_ part: KimiPart) -> Bool {
            (part.type == "text" && !part.isRuntimeContext && !(part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                || ["image", "file", "video"].contains(part.type)
        }
        func thinking(_ part: KimiPart) -> Bool { part.type == "thinking" && !(part.thinking ?? "").isEmpty }
        func flush(running: Bool) {
            guard !turn.isEmpty else { return }
            let answer = turn.lastIndex { $0.role == "assistant" && $0.content.contains(where: visible) && !$0.content.contains { $0.type == "tool_use" } }
            let final = answer.flatMap { index in turn[(index + 1)...].contains { $0.content.contains { $0.type == "tool_use" } } ? nil : index }
            let details = turn.compactMap { message -> KimiMessage? in
                let content = message.content.filter { $0.type == "tool_use" || $0.isRuntimeContext }
                return content.isEmpty ? nil : KimiMessage(id: message.id, role: message.role, content: content, createdAt: message.createdAt)
            }
            if !details.isEmpty { entries.append(Self(messages: details, presentation: .activity, partOffset: 0, activityAnchor: turnAnchor)) }

            // Preserve the source order of reasoning and public progress. A new step
            // appends a new row instead of replacing a turn-wide preview or overview.
            var phases: [(message: KimiMessage, offset: Int)] = []
            for message in turn {
                for (offset, part) in message.content.enumerated() where visible(part) || thinking(part) {
                    phases.append((KimiMessage(id: message.id, role: message.role, content: [part], createdAt: message.createdAt), offset))
                }
            }
            let hasText = phases.contains { visible($0.message.content[0]) }
            let lastText = phases.lastIndex { visible($0.message.content[0]) }
            for (index, phase) in phases.enumerated() {
                let presentation: Presentation
                if thinking(phase.message.content[0]) {
                    presentation = running && index == phases.count - 1 ? .thinkingPreview
                        : !running && !hasText ? .thinkingRecord : .thinkingDetails
                } else if !running, let final, phase.message.id == turn[final].id {
                    presentation = .message
                } else {
                    presentation = !running && final == nil && index == lastText ? .record : .progress
                }
                entries.append(Self(messages: [phase.message], presentation: presentation, partOffset: phase.offset))
            }
            if phases.isEmpty && !running && turn.contains(where: { $0.role == "assistant" }) {
                entries.append(Self(messages: [turn[0]], presentation: .emptyOutput, partOffset: 0))
            }
            turn = []
        }
        for message in messages where !message.content.isEmpty {
            if message.role == "tool" || message.content.allSatisfy({ $0.type == "tool_result" }) { continue }
            let user = message.role == "user" && !message.content.allSatisfy(\.isRuntimeContext)
            if user { flush(running: false); turnAnchor = message.id; entries.append(Self(messages: [message], presentation: .message, partOffset: 0)) }
            else { turn.append(message) }
        }
        flush(running: isRunning)
        return entries
    }
}

extension KimiConversation {
    /// Include volatile output in the same folding policy as persisted messages.
    public var displayMessages: [KimiMessage] {
        guard let live else { return messages }
        let start = messages.lastIndex { $0.role == "user" && !$0.content.allSatisfy(\.isRuntimeContext) }.map { $0 + 1 } ?? 0
        let last = messages[start...].last { $0.role == "assistant" }
        var parts: [KimiPart] = []
        for (type, value) in [("thinking", live.thinkingText), ("text", live.assistantText)] where !value.isEmpty {
            if last?.content.contains(where: { type == "text" ? $0.text == value : $0.thinking == value }) == true { continue }
            parts.append(KimiPart(type: type, text: type == "text" ? value : nil, thinking: type == "thinking" ? value : nil,
                                  toolCallId: nil, toolName: nil, input: nil, output: nil, isError: nil, source: nil, fileId: nil, name: nil))
        }
        guard !parts.isEmpty else { return messages }
        return messages + [KimiMessage(id: "live:\(live.turnId)", role: "assistant", content: parts, createdAt: "")]
    }
}
