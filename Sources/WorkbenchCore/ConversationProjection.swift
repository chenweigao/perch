import Foundation

/// Per-transcript memoization. A streaming tail cannot invalidate completed turns.
/// Compare complete values, including tool results, so history replacement and same-ID
/// edits take exactly the same path as newly received messages.
public final class ConversationProjection {
    public struct Snapshot {
        public let entries: [ConversationTimelineEntry]
        public let results: [String: KimiPart]
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
                turn = Turn(messages: group, running: running, snapshot: Snapshot(
                    entries: ConversationTimelineEntry.make(group, isRunning: running), results: turnResults))
            }
            next[id] = turn
            entries.append(contentsOf: turn.snapshot.entries)
            results.merge(turn.snapshot.results) { _, latest in latest }
        }
        turns = next
        return Snapshot(entries: entries, results: results)
    }
}
