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
        tally(messages[...], into: &perFile)
        return summary(perFile)
    }

    /// Per-file tallies only add up, so any split of the messages sums to the same result.
    static func tally(_ messages: ArraySlice<KimiMessage>, into perFile: inout [String: SessionEditStat]) {
        for message in messages {
            for part in message.content where part.type == "tool_use" {
                guard let tool = part.toolName, let input = part.input else { continue }
                let edits: [(stat: SessionEditStat, path: String?)]
                if tool.lowercased() == "apply_patch", !input["changes"].array.isEmpty {
                    // Codex fileChange is normalized by native-agent-service.py to
                    // one changes array, with a path and unified diff per file.
                    edits = input["changes"].array.compactMap { change in
                        guard let path = change["path"].string, !path.contains("://"),
                              let diff = change["diff"].string else { return nil }
                        return (patchStat(diff), path)
                    }
                } else {
                    edits = compute(tool: tool, input: input).map { [$0] } ?? []
                }
                for edit in edits {
                    guard let path = edit.path else { continue }
                    var accumulated = perFile[path] ?? SessionEditStat(additions: 0, deletions: 0)
                    accumulated.additions += edit.stat.additions
                    accumulated.deletions += edit.stat.deletions
                    perFile[path] = accumulated
                }
            }
        }
    }

    static func summary(_ perFile: [String: SessionEditStat]) -> (perFile: [String: SessionEditStat], total: SessionEditStat)? {
        guard !perFile.isEmpty else { return nil }
        let total = perFile.values.reduce(SessionEditStat(additions: 0, deletions: 0)) {
            SessionEditStat(additions: $0.additions + $1.additions, deletions: $0.deletions + $1.deletions)
        }
        return (perFile, total)
    }

    // Derive from this snapshot only. Tool IDs are not globally unique and
    // providers can publish revised inputs under the same ID.
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
            return (patchStat(patch), path)
        default:
            return nil
        }
    }

    private static func patchStat(_ patch: String) -> SessionEditStat {
        var stat = SessionEditStat(additions: 0, deletions: 0)
        for line in lines(patch) {
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") { continue }
            if line.hasPrefix("+") { stat.additions += 1 }
            else if line.hasPrefix("-") { stat.deletions += 1 }
        }
        return stat
    }

    /// The status bar derives the latest turn on every update and the whole
    /// loaded window after paging or a history change. Splitting by Character grapheme-breaks every edit
    /// payload; these UTF-8 scans produce the same lines without that cost.
    /// `String.split(separator: "\n")` compares Characters, and CR LF is a single
    /// Character, so only an LF that does not follow a CR separates lines. Such an
    /// LF is always a grapheme boundary on both sides, so each returned substring
    /// is exactly the Character-split line and line comparisons keep canonical
    /// equivalence.
    private static func lines(_ text: String) -> [Substring] {
        var result: [Substring] = []
        let utf8 = text.utf8
        var start = utf8.startIndex
        var index = start
        var previous: UInt8 = 0
        while index != utf8.endIndex {
            let byte = utf8[index]
            if byte == 0x0A && previous != 0x0D {
                result.append(text[start..<index])
                start = utf8.index(after: index)
            }
            previous = byte
            utf8.formIndex(after: &index)
        }
        result.append(text[start...])
        return result
    }

    /// A trailing newline ends the last line rather than starting another —
    /// but keep parity with ccgui's JS split, which counts it.
    private static func lineCount(_ text: String) -> Int {
        var count = 1
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A && previous != 0x0D { count += 1 }
            previous = byte
        }
        return count
    }

    /// Old/new diff counting only the changed middle: common prefix and suffix
    /// lines are context, not edits.
    private static func lineDiff(old: String?, new: String?) -> SessionEditStat? {
        guard old != nil || new != nil else { return nil }
        let oldLines = old.map(lines) ?? []
        let newLines = new.map(lines) ?? []
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

/// The activity bar derives the whole-session tally on every update of the
/// loaded window. Messages before the latest user prompt only change on paging,
/// a new prompt or history replacement; their tally is kept and the latest turn
/// is added. A page of older messages or a newly completed turn only adds its own.
public final class SessionEditStatsCache {
    private var source: ArraySlice<KimiMessage> = []
    private var earlier: [String: SessionEditStat] = [:]
    public init() {}

    public func derive(from messages: [KimiMessage]) -> (perFile: [String: SessionEditStat], total: SessionEditStat)? {
        let split = messages.lastIndex(where: \.isUserPrompt) ?? 0
        if source.count != split || !messages[..<split].elementsEqual(source) {
            let older = split - source.count
            if older >= 0, messages[older..<split].elementsEqual(source) {
                SessionEditStats.tally(messages[..<older], into: &earlier)
            } else if older >= 0, messages[..<source.count].elementsEqual(source) {
                SessionEditStats.tally(messages[source.count..<split], into: &earlier)
            } else {
                earlier = [:]
                SessionEditStats.tally(messages[..<split], into: &earlier)
            }
            source = messages[..<split]
        }
        var perFile = earlier
        SessionEditStats.tally(messages[split...], into: &perFile)
        return SessionEditStats.summary(perFile)
    }
}
