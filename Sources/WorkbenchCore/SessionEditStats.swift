import Foundation

/// One file's added/removed line tally from edit-class tool calls.
public struct SessionEditStat: Equatable, Sendable {
    public var additions: Int
    public var deletions: Int
    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }
}

/// Added/removed line tally derived from the session's own edit-class tool
/// calls — ported from ccgui's edit-line-stats.ts. Session-sourced instead of
/// git-sourced: gitignored targets, non-repo workspaces and files committed
/// mid-session stay counted. Repeated edits of one path accumulate: the
/// session's total churn, not the last call's. The tool names are the ones
/// Perch's runtimes actually emit (see ConversationActivity's title mapping).
public enum SessionEditStats {
    /// Whole-session tally; nil when no edit resolved a file, so the caller
    /// hides the stats instead of showing zeros.
    public static func derive(from messages: [KimiMessage]) -> (perFile: [String: SessionEditStat], total: SessionEditStat)? {
        var perFile: [String: SessionEditStat] = [:]
        for message in messages {
            for part in message.content where part.type == "tool_use" {
                guard let id = part.toolCallId, let tool = part.toolName, let input = part.input,
                      let resolved = resolve(id: id, tool: tool, input: input),
                      let path = resolved.path else { continue }
                var accumulated = perFile[path] ?? SessionEditStat(additions: 0, deletions: 0)
                accumulated.additions += resolved.stat.additions
                accumulated.deletions += resolved.stat.deletions
                perFile[path] = accumulated
            }
        }
        guard !perFile.isEmpty else { return nil }
        let total = perFile.values.reduce(SessionEditStat(additions: 0, deletions: 0)) {
            SessionEditStat(additions: $0.additions + $1.additions, deletions: $0.deletions + $1.deletions)
        }
        return (perFile, total)
    }

    /// Edit arguments never change once the call is recorded; the session walk
    /// re-derives per update, so memoize successes by tool call. Misses fail
    /// fast on the tool-name switch and are not cached. Bounded FIFO.
    private static var memo: [String: (stat: SessionEditStat, path: String?)] = [:]
    private static var memoOrder: [String] = []

    private static func resolve(id: String, tool: String, input: JSONValue) -> (stat: SessionEditStat, path: String?)? {
        if let hit = memo[id] { return hit }
        guard let computed = compute(tool: tool, input: input) else { return nil }
        memo[id] = computed
        memoOrder.append(id)
        if memoOrder.count > 2048 {
            memo.removeValue(forKey: memoOrder.removeFirst())
        }
        return computed
    }

    private static func compute(tool: String, input: JSONValue) -> (stat: SessionEditStat, path: String?)? {
        // Tool-call paths may be absolute; URL-ish values are never files.
        let path = input["file_path"].string ?? input["filePath"].string ?? input["path"].string
        if let path, path.contains("://") { return nil }
        switch tool.lowercased() {
        case "edit", "edit_file":
            guard let stat = lineDiff(old: input["old_string"].string ?? input["oldString"].string,
                                      new: input["new_string"].string ?? input["newString"].string) else { return nil }
            return (stat, path)
        case "write", "write_file":
            guard let content = input["content"].string else { return nil }
            return (SessionEditStat(additions: lineCount(content), deletions: 0), path)
        case "apply_patch":
            guard let patch = input["patch"].string ?? input["diff"].string else { return nil }
            var stat = SessionEditStat(additions: 0, deletions: 0)
            for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                // +++/--- name the file, not an edit.
                if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
                if line.hasPrefix("+") { stat.additions += 1 }
                else if line.hasPrefix("-") { stat.deletions += 1 }
            }
            return (stat, path)
        default:
            return nil
        }
    }

    /// A trailing newline ends the last line rather than starting another —
    /// but keep parity with ccgui's JS split, which counts it.
    private static func lineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Old/new diff counting only the changed middle: common prefix and suffix
    /// lines are context, not edits.
    private static func lineDiff(old: String?, new: String?) -> SessionEditStat? {
        guard old != nil || new != nil else { return nil }
        let oldLines = old.map { $0.split(separator: "\n", omittingEmptySubsequences: false) } ?? []
        let newLines = new.map { $0.split(separator: "\n", omittingEmptySubsequences: false) } ?? []
        if old != nil && (new == nil || new!.isEmpty) {
            return SessionEditStat(additions: 0, deletions: oldLines.count)
        }
        if new != nil && (old == nil || old!.isEmpty) {
            return SessionEditStat(additions: newLines.count, deletions: 0)
        }
        var start = 0
        while start < oldLines.count && start < newLines.count && oldLines[start] == newLines[start] { start += 1 }
        var oldEnd = oldLines.count
        var newEnd = newLines.count
        while oldEnd > start && newEnd > start && oldLines[oldEnd - 1] == newLines[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        return SessionEditStat(additions: newEnd - start, deletions: oldEnd - start)
    }
}
