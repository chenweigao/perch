import Foundation

/// Per-transcript memoization. A streaming tail cannot invalidate completed turns.
/// Compare complete values, including tool results, so history replacement and same-ID
/// edits take exactly the same path as newly received messages.
public final class ConversationProjection {
    public struct Snapshot {
        public let entries: [ConversationTimelineEntry]
        public let results: [String: KimiPart]
        public let navigation: [ConversationTurnSummary]
    }
    private struct Turn {
        let messages: [KimiMessage]
        let running: Bool
        let snapshot: Snapshot
    }
    private var turns: [String: Turn] = [:]
    public init() {}

    public func update(_ messages: [KimiMessage], isRunning: Bool) -> Snapshot {
        var groups: [[KimiMessage]] = []
        var group: [KimiMessage] = []
        for message in messages {
            if message.role == "user" && !message.content.allSatisfy(\.isRuntimeContext) && !group.isEmpty {
                groups.append(group); group = []
            }
            group.append(message)
        }
        if !group.isEmpty { groups.append(group) }
        var next: [String: Turn] = [:]
        var entries: [ConversationTimelineEntry] = []
        var results: [String: KimiPart] = [:]
        var navigation: [ConversationTurnSummary] = []
        for (index, group) in groups.enumerated() {
            let id = group[0].id
            let running = isRunning && index == groups.count - 1
            let turn: Turn
            if let prior = turns[id], prior.running == running, prior.messages == group {
                turn = prior
            } else {
                var turnResults: [String: KimiPart] = [:]
                for message in group {
                    for part in message.content where part.type == "tool_result" {
                        if let id = part.toolCallId { turnResults[id] = part }
                    }
                }
                let timeline = ConversationTimelineEntry.make(group, isRunning: running)
                let summary = ConversationTurnSummary.make(group, entries: timeline)
                turn = Turn(messages: group, running: running, snapshot: Snapshot(
                    entries: timeline, results: turnResults, navigation: summary.map { [$0] } ?? []))
            }
            next[id] = turn
            entries.append(contentsOf: turn.snapshot.entries)
            results.merge(turn.snapshot.results) { _, latest in latest }
            navigation.append(contentsOf: turn.snapshot.navigation)
        }
        turns = next
        return Snapshot(entries: entries, results: results, navigation: navigation)
    }
}

/// Plain, bounded excerpts computed with the existing per-turn cache. Hovering
/// never parses Markdown, mounts a transcript row, or reads from a provider.
public struct ConversationTurnSummary: Identifiable, Equatable {
    public let id: String
    public let prompt: String
    public let reply: String

    static func make(_ messages: [KimiMessage], entries: [ConversationTimelineEntry]) -> Self? {
        guard let user = messages.first, user.role == "user",
              !user.content.allSatisfy(\.isRuntimeContext), let entry = entries.first else { return nil }
        func excerpt(_ message: KimiMessage) -> String {
            var value = ""
            for part in message.content where part.type == "text" && !part.isRuntimeContext {
                value += " " + String((part.text ?? "").prefix(320 - value.count))
                if value.count >= 320 { break }
            }
            return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let prompt = excerpt(user)
        let answer = messages.last { $0.role == "assistant" && $0.content.contains { $0.type == "text" && !$0.isRuntimeContext && !($0.text ?? "").isEmpty } }
        return Self(id: entry.id,
                    prompt: prompt.isEmpty ? String(user.content.compactMap(\.name).joined(separator: ", ").prefix(320)) : prompt,
                    reply: answer.map(excerpt) ?? "")
    }
}
