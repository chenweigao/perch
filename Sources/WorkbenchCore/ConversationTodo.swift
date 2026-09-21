import Foundation

/// The installed Kimi TodoList tool replaces the list only after a successful result.
public struct ConversationTodo: Identifiable, Equatable {
    public enum Status: String { case pending, inProgress = "in_progress", done }
    public let id: Int
    public let title: String
    public let status: Status

    /// The floating list belongs to the latest user turn, not the whole session.
    public static func floating(in messages: [KimiMessage], isRunning: Bool) -> [Self] {
        let start = messages.lastIndex { $0.role == "user" && !$0.content.allSatisfy(\.isRuntimeContext) } ?? messages.startIndex
        let items = current(in: Array(messages[start...]))
        return isRunning || items.contains(where: { $0.status != .done }) ? items : []
    }

    public static func current(in messages: [KimiMessage]) -> [Self] {
        let results = messages.flatMap(\.content).filter { $0.type == "tool_result" }
            .reduce(into: [String: KimiPart]()) { if let id = $1.toolCallId { $0[id] = $1 } }
        var current: [Self] = []
        for part in messages.flatMap(\.content) where part.type == "tool_use" && part.toolName == "TodoList" {
            guard let id = part.toolCallId, let result = results[id], result.isError != true,
                  let input = part.input, case .array(let values) = input["todos"] else { continue }
            let items = values.enumerated().compactMap { index, value -> Self? in
                guard let title = value["title"].string, let raw = value["status"].string,
                      let status = Status(rawValue: raw) else { return nil }
                return Self(id: index, title: title, status: status)
            }
            if items.count == values.count { current = items }
        }
        return current
    }
}
