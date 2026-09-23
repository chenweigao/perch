import Foundation

/// A compaction summary message wraps the agent's handoff notes in harness
/// scaffolding: an English preamble addressed to the model and a trailing
/// "Context Recovery" section with wire-log pointers. People reading the
/// transcript only need the notes themselves.
public enum CompactionSummaryDisplay {
    public static func humanText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if trimmed.hasPrefix(preamblePrefix), let first = lines.firstIndex(where: { $0.hasPrefix("## ") }) {
            lines.removeFirst(first)
        }
        if let recovery = lines.firstIndex(where: { $0.hasPrefix(recoveryPrefix) }) {
            lines.removeSubrange(recovery...)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? trimmed : text
    }
    private static let preamblePrefix = "The conversation so far has been compacted"
    private static let recoveryPrefix = "## Context Recovery"
}
