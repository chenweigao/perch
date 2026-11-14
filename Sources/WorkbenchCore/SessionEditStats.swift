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
    /// Tally of the given messages (the status line and the process fold pass
    /// one turn); nil when no edit resolved a file, so the caller hides the
    /// stats instead of showing zeros.
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
                    // one changes array, with a path and unified diff or raw body per file.
                    edits = input["changes"].array.compactMap { change in
                        guard let path = change["path"].string, !path.contains("://"),
                              let diff = change["diff"].string else { return nil }
                        let kind = change["kind"]["type"].string ?? change["kind"].string
                        return (changeStat(kind: kind, diff: diff), path)
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
        let name = tool.lowercased()
        // Unknown/read-only tools never produce a stat. Do not resolve or
        // search their paths just to discard them in the payload switch.
        switch name {
        case "edit", "edit_file", "write", "write_file", "apply_patch": break
        default: return nil
        }
        // Tool-call paths may be absolute; URL-ish values are never files.
        let path = input["file_path"].string ?? input["filePath"].string ?? input["path"].string
        if let path, path.contains("://") { return nil }
        switch name {
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

    private static func changeStat(kind: String?, diff: String) -> SessionEditStat {
        switch kind?.lowercased() {
        case "add", "create":
            let diffLines = lines(diff)
            let isPatch = diffLines.contains { $0.hasPrefix("@@") || $0.hasPrefix("+++ ") || $0.hasPrefix("--- ") }
                || (!diffLines.isEmpty && diffLines.allSatisfy { $0.isEmpty || $0.hasPrefix("+") })
            return isPatch ? patchStat(diff) : SessionEditStat(additions: lineCount(diff), deletions: 0)
        case "delete", "remove":
            let diffLines = lines(diff)
            let isPatch = diffLines.contains { $0.hasPrefix("@@") || $0.hasPrefix("+++ ") || $0.hasPrefix("--- ") }
                || (!diffLines.isEmpty && diffLines.allSatisfy { $0.isEmpty || $0.hasPrefix("-") })
            return isPatch ? patchStat(diff) : SessionEditStat(additions: 0, deletions: lineCount(diff))
        default:
            return patchStat(diff)
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
        let utf8 = text.utf8
        // Scan integer byte offsets when storage is contiguous. Only LF line
        // boundaries need String.Index values; keep the substrings backed by
        // the original text so comparisons still use canonical equivalence.
        if let result = utf8.withContiguousStorageIfAvailable({ bytes -> [Substring] in
            var result: [Substring] = []
            var start = utf8.startIndex
            for offset in bytes.indices where bytes[offset] == 0x0A && (offset == 0 || bytes[offset - 1] != 0x0D) {
                let index = utf8.index(utf8.startIndex, offsetBy: offset)
                result.append(text[start..<index])
                start = utf8.index(after: index)
            }
            result.append(text[start...])
            return result
        }) { return result }
        // Foreign/non-contiguous storage retains the original UTF8View walk.
        var result: [Substring] = []
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
    ///
    /// A separator is exactly an LF whose previous byte is not a CR, so the
    /// count is (all LF bytes) − (adjacent CR-LF pairs). Both terms scan as
    /// 8-byte words: the has-zero trick marks every byte equal to the pattern
    /// with a 0x80 bit, popcount totals them, and a CR mask shifted one byte
    /// up (plus the cross-word carry flag) marks exactly the LF-after-CR pairs.
    /// The scalar predicate it replaces re-reads `bytes[offset - 1]` per byte
    /// and never vectorizes.
    private static func lineCount(_ text: String) -> Int {
        if let count = text.utf8.withContiguousStorageIfAvailable({ bytes -> Int in
            let n = bytes.count
            guard let base = bytes.baseAddress else { return 1 }
            let lfPattern: UInt64 = 0x0A0A0A0A0A0A0A0A
            let crPattern: UInt64 = 0x0D0D0D0D0D0D0D0D
            var lf = 0
            var crlf = 0
            var i = 0
            var prevByteIsCR = false
            while i + 8 <= n {
                let word = UnsafeRawPointer(base).loadUnaligned(fromByteOffset: i, as: UInt64.self)
                let lfBits = hasByteEqualTo(word, lfPattern)
                let crBits = hasByteEqualTo(word, crPattern)
                lf += lfBits.nonzeroBitCount
                // Little-endian: the CR of byte k-1 carries bit 8(k-1)+7, so a
                // one-byte left shift aligns it under byte k's LF bit.
                crlf += (lfBits & (crBits << 8)).nonzeroBitCount
                // The pair spanning the word boundary: this word's byte 0 is an
                // LF and the previous word ended with a CR.
                if prevByteIsCR && (lfBits & 0x80) != 0 { crlf += 1 }
                prevByteIsCR = (crBits & 0x8000000000000000) != 0
                i += 8
            }
            while i < n {
                if bytes[i] == 0x0A {
                    lf += 1
                    if i > 0, bytes[i - 1] == 0x0D { crlf += 1 }
                }
                i += 1
            }
            return 1 + lf - crlf
        }) { return count }
        var count = 1
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A && previous != 0x0D { count += 1 }
            previous = byte
        }
        return count
    }

    /// Sets the high bit of every byte of `word` that equals the corresponding
    /// byte of the repeated pattern `c` (classic SWAR has-zero test on v ^ c).
    @inline(__always)
    private static func hasByteEqualTo(_ word: UInt64, _ c: UInt64) -> UInt64 {
        let x = word ^ c
        return (x &- 0x0101010101010101) & ~x & 0x8080808080808080
    }

    /// These ranges end only at LF separators (except CRLF) or the buffer
    /// bounds. Converting them back into the original text therefore preserves
    /// scalar boundaries and canonical Substring comparisons.
    private static func firstLine(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Range<Int> {
        var end = start
        while end < bytes.count {
            if bytes[end] == 0x0A && (end == 0 || bytes[end - 1] != 0x0D) { break }
            end += 1
        }
        return start..<end
    }

    private static func lastLine(_ bytes: UnsafeBufferPointer<UInt8>, before end: Int) -> Range<Int> {
        var start = end
        while start > 0 {
            start -= 1
            if bytes[start] == 0x0A && (start == 0 || bytes[start - 1] != 0x0D) {
                return (start + 1)..<end
            }
        }
        return 0..<end
    }

    private static func substring(_ text: String, bytes range: Range<Int>) -> Substring {
        let utf8 = text.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        let end = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
        return text[start..<end]
    }

    /// Old/new diff counting only the changed middle: common prefix and suffix
    /// lines are context, not edits. Borrowed buffers never leave these closures;
    /// only line offsets and the final counts escape, not pointer-backed storage.
    private static func lineDiff(old: String?, new: String?) -> SessionEditStat? {
        // Keep historical nil/empty counts before the equality fast path:
        // two empty strings count as one deletion, not a zero-change edit.
        if let old, new == nil || new!.isEmpty {
            return SessionEditStat(additions: 0, deletions: lineCount(old))
        }
        if let new, old == nil || old!.isEmpty {
            return SessionEditStat(additions: lineCount(new), deletions: 0)
        }
        guard let old, let new else { return nil }
        // For short edits, probing first/last lines costs more than creating
        // the small arrays. Keep that working set on the original algorithm.
        if old.utf8.count <= 1024 && new.utf8.count <= 1024 { return fullLineDiff(old, new) }
        let bounded = old.utf8.withContiguousStorageIfAvailable { a in
            new.utf8.withContiguousStorageIfAvailable { b -> SessionEditStat in
                // Only a different first AND last line proves that there is
                // no shared prefix/suffix to remove. Common-context edits
                // retain the original algorithm rather than rescanning lazily.
                let firstOld = firstLine(a, from: 0), firstNew = firstLine(b, from: 0)
                let firstMatches = substring(old, bytes: firstOld) == substring(new, bytes: firstNew)
                // No separator in either input: the first line is also the
                // last, so this one canonical comparison determines the tally.
                if firstOld.upperBound == a.count && firstNew.upperBound == b.count {
                    return firstMatches ? SessionEditStat(additions: 0, deletions: 0)
                        : SessionEditStat(additions: 1, deletions: 1)
                }
                if !firstMatches,
                   substring(old, bytes: lastLine(a, before: a.count)) != substring(new, bytes: lastLine(b, before: b.count)) {
                    return SessionEditStat(additions: lineCount(new), deletions: lineCount(old))
                }
                return fullLineDiff(old, new)
            }
        }
        if let result = bounded ?? nil { return result }
        return fullLineDiff(old, new)
    }

    /// Original nonempty-string algorithm, used for common context and foreign
    /// storage. All comparisons remain canonical, including NFC/NFD no-ops.
    private static func fullLineDiff(_ old: String, _ new: String) -> SessionEditStat {
        let oldLines = lines(old), newLines = lines(new)
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

/// Matches a turn's edited files to Git working-tree entries, so the changes
/// page can mark which of the working tree's changes this turn made.
public enum TurnEditPaths {
    /// Repository-relative paths of `edits` that lie inside `root`. Tools name
    /// files absolute or relative to the session's `directory`; `~` paths can't
    /// be resolved without the remote home and are left out.
    public static func relative(_ edits: some Sequence<String>, directory: String, root: String) -> Set<String> {
        let base = (root as NSString).standardizingPath
        var paths = Set<String>()
        for edit in edits where !edit.isEmpty && !edit.hasPrefix("~") {
            let absolute = edit.hasPrefix("/") ? edit : (directory as NSString).appendingPathComponent(edit)
            let path = (absolute as NSString).standardizingPath
            guard path.hasPrefix(base + "/") else { continue }
            paths.insert(String(path.dropFirst(base.count + 1)))
        }
        return paths
    }
}
