import Foundation

/// The server queue contains messages that have not appeared in history yet.
/// Local submissions use the same id until the authoritative user message arrives.
public struct KimiPrompt: Decodable, Identifiable, Equatable, Sendable {
    public let promptId: String
    public var userMessageId: String?
    public var status: String
    public var content: [JSONValue]
    public var error: String?
    public var id: String { promptId }
    public var text: String {
        content.compactMap { $0["text"].string ?? $0["name"].string }.joined(separator: "\n")
    }
    public var label: String {
        if let error { return error }
        switch status {
        case "sending": return "Sending"
        case "queued", "blocked": return "Queued for next turn"
        case "steering": return "Steering requested"
        case "steered": return "Accepted · waiting for context"
        case "running": return "Running"
        default: return "Send unconfirmed"
        }
    }
    public init(id: String, content: [JSONValue]) {
        promptId = id; status = "sending"; self.content = content
    }
    public static func reconcile(local: [Self], remote: [Self], messages: [KimiMessage]) -> [Self] {
        let visible = Set(messages.map(\.id))
        var merged = local
        for prompt in remote {
            if let index = merged.firstIndex(where: { $0.id == prompt.id }) {
                // A receipt settles send uncertainty. Only an unresolved steer
                // warning remains relevant while this accepted message is queued.
                let waiting = ["queued", "blocked"]
                let error = waiting.contains(merged[index].status) && waiting.contains(prompt.status) ? merged[index].error : nil
                merged[index] = prompt
                if let error { merged[index].error = error }
            } else { merged.append(prompt) }
        }
        return merged.filter { !visible.contains($0.userMessageId ?? $0.id) }
    }
}

public struct KimiPromptQueue: Decodable {
    public let active: KimiPrompt?
    public let queued: [KimiPrompt]
}
