import Foundation

/// An immutable copy of the selected call and its loaded turn. Never reads Git.
/// Later calls editing the same path cannot replace the selected step's input.
public struct ConversationEditRecord: Equatable {
    public let step: VisibleTool
    public let turn: [VisibleTool]
    public let hasTurn: Bool

    public init(step: VisibleTool, messages: [KimiMessage], messageID: String? = nil) {
        self.step = step
        guard let index = messages.firstIndex(where: { (messageID == nil || $0.id == messageID) && $0.content.contains { $0.toolCallId == step.id && $0.type == "tool_use" } }) else {
            turn = [step]; hasTurn = false; return
        }
        let start = messages[...index].lastIndex(where: \.isUserPrompt) ?? 0
        let end = messages.indices.dropFirst(index + 1).first { messages[$0].isUserPrompt } ?? messages.count
        let source = Array(messages[start..<end])
        let projection = ToolVisibilityProjection().update(source, sessionID: "edit-record")
        var seen: Set<String> = []
        turn = source.flatMap(\.content).compactMap { part in
            guard part.type == "tool_use", let id = part.toolCallId,
                  seen.insert(id).inserted, let tool = projection.tools[id], ToolPresentation.isEdit(tool.name) else { return nil }
            return id == step.id ? step : tool
        }
        hasTurn = messages[start].isUserPrompt
    }

    public static func stat(_ tool: VisibleTool) -> SessionEditStat? {
        let part = KimiPart(type: "tool_use", text: nil, thinking: nil, toolCallId: tool.id,
                            toolName: tool.name, input: tool.input, output: nil, isError: nil,
                            source: nil, fileId: nil, name: nil)
        let message = KimiMessage(id: tool.id, role: "assistant", content: [part], createdAt: "", metadata: nil)
        return SessionEditStats.derive(from: [message])?.total ?? ToolInlineDiff.derive(from: tool, maxLines: 0)?.stat
    }

    /// Successful call churn, intentionally different from the workspace's net diff.
    public var appliedTotal: SessionEditStat {
        turn.filter { $0.status == .succeeded }.compactMap(Self.stat).reduce(.init(additions: 0, deletions: 0)) {
            .init(additions: $0.additions + $1.additions, deletions: $0.deletions + $1.deletions)
        }
    }
}
