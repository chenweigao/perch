import Foundation

/// A compaction summary message wraps the agent's handoff notes in harness
/// scaffolding: an English preamble addressed to the model and a trailing
/// "Context Recovery" section with wire-log pointers. People reading the
/// transcript only need the notes themselves.
public enum CompactionSummaryDisplay {
    public static func humanText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let preamble = preambles.first { trimmed.hasPrefix($0) }
        let body = preamble.map { String(trimmed.dropFirst($0.count)) } ?? trimmed
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let recovery = lines.firstIndex(of: recoveryHeading) {
            lines.removeSubrange(recovery...)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? trimmed : text
    }
    private static let preambles = [
        "The conversation so far has been compacted to free up context. What follows is your own working summary of this task.",
        "The conversation so far has been compacted."
    ]
    private static let recoveryHeading = "## Context Recovery"
}
