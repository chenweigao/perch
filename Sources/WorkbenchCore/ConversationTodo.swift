import Foundation

/// The installed Kimi TodoList tool replaces the list only after a successful result.
public struct ConversationTodo: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case pending, inProgress = "in_progress", done }
    public let id: Int
    public let title: String
    public let status: Status

    /// The floating list belongs to the latest user turn, not the whole session.
    public static func floating(in messages: [KimiMessage], isRunning: Bool) -> [Self] {
        let start = messages.lastIndex { $0.isUserPrompt } ?? messages.startIndex
        let items = current(in: messages[start...])
        return isRunning || items.contains(where: { $0.status != .done }) ? items : []
    }

    public static func current(in messages: [KimiMessage]) -> [Self] { current(in: messages[...]) }

    /// Two walks over the borrowed turn: the result of each call, then the latest
    /// complete TodoList write. Materializing every part of the turn once per walk
    /// costs a copy of each part, which a long autonomous turn pays per update.
    private static func current(in messages: ArraySlice<KimiMessage>) -> [Self] {
        var results: [String: KimiPart] = [:]
        for message in messages {
            for part in message.content where part.type == "tool_result" {
                if let id = part.toolCallId { results[id] = part }
            }
        }
        var current: [Self] = []
        for message in messages {
            for part in message.content where part.type == "tool_use" && part.toolName == "TodoList" {
                guard let id = part.toolCallId, let result = results[id], result.isError != true,
                      let input = part.input, case .array(let values) = input["todos"] else { continue }
                let items = values.enumerated().compactMap { index, value -> Self? in
                    guard let title = value["title"].string, let raw = value["status"].string,
                          let status = Status(rawValue: raw) else { return nil }
                    return Self(id: index, title: title, status: status)
                }
                if items.count == values.count { current = items }
            }
        }
        return current
    }
}
