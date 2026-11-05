import Foundation

/// Labels describe observed tool calls, never their inferred outcome.
public enum ToolPresentation {
    public static func isExploration(_ name: String) -> Bool {
        ["read", "read_file", "readfile", "grep", "search", "glob", "find_files"].contains(name.lowercased())
    }

    /// Calls that start a subagent: Claude's Agent tool (named Task in older
    /// releases) and Codex's collab spawn, which the bridge names agent/spawnAgent.
    public static func isSubagentCall(name: String) -> Bool {
        ["agent", "task", "agent/spawnagent"].contains(name.lowercased())
    }

    public static func action(_ name: String) -> String {
        if isSubagentCall(name: name) { return L("子 Agent") }
        switch name.lowercased() {
        case "read", "read_file", "readfile": return L("读取")
        case "grep", "search": return L("搜索")
        case "glob", "find_files": return L("查找文件")
        case "edit", "edit_file", "editfile", "apply_patch", "filechange": return L("编辑")
        case "write", "write_file", "writefile": return L("写入")
        default: return name
        }
    }

    public static func path(_ tool: VisibleTool) -> String? {
        if let direct = tool.input?["file_path"].string ?? tool.input?["filePath"].string ?? tool.input?["path"].string,
           !direct.isEmpty {
            return direct
        }
        if let first = tool.input?["changes"].array.first {
            return first["move_path"].string ?? first["path"].string
        }
        return nil
    }

    public static func target(_ tool: VisibleTool) -> String {
        if let path = path(tool), !path.isEmpty {
            let base = (path as NSString).lastPathComponent
            let changeCount = tool.input?["changes"].array.count ?? 0
            return changeCount > 1 ? "\(base) (+\(changeCount - 1))" : base
        }
        return tool.input?["description"].string ?? tool.input?["pattern"].string
            ?? tool.input?["command"].string ?? tool.name
    }

    public static func directory(_ tool: VisibleTool) -> String? {
        guard let path = path(tool), path.contains("/") else { return nil }
        return (path as NSString).deletingLastPathComponent
    }

    /// Compact display only. The full command remains in the tooltip and input.
    public static func compactTarget(_ tool: VisibleTool) -> String {
        if let command = ShellActivity.command(tool) {
            if let description = tool.input?["description"].string, !description.isEmpty {
                return description
            }
            return ShellActivity.parse(command)?.compactTarget ?? L("准备命令环境")
        }
        return target(tool)
    }

    public static func recentTargets(_ tools: [VisibleTool]) -> String {
        var seen = Set<String>(), labels: [String] = []
        for tool in tools.reversed() where !tool.staysVisible {
            let label = compactTarget(tool)
            if seen.insert(label).inserted { labels.append(label) }
            if labels.count == 2 { break }
        }
        return labels.reversed().joined(separator: " · ")
    }

    /// Other tool kinds join summaries without exposing shell arguments or edits.
    public static func summaryTarget(_ tool: VisibleTool) -> String {
        if let path = path(tool) { return (path as NSString).lastPathComponent }
        if isExploration(tool.name), let pattern = tool.input?["pattern"].string { return pattern }
        return tool.name
    }

    /// Natural-language bucket summary for exploration stages (Oh My Pi / ZCode style):
    /// counts unique files read, content searches, and file globs instead of a flat call count.
    public static func explorationBucketSummary(_ tools: [VisibleTool]) -> String {
        var readFiles = Set<String>()
        var readCount = 0
        var searchCount = 0
        var globCount = 0
        for tool in tools {
            switch tool.name.lowercased() {
            case "read", "read_file", "readfile":
                readCount += 1
                if let p = path(tool), !p.isEmpty { readFiles.insert(p) }
            case "grep", "search":
                searchCount += 1
            case "glob", "find_files":
                globCount += 1
            default:
                break
            }
        }
        var parts: [String] = []
        let files = max(readFiles.count, readCount > 0 ? 1 : 0)
        if files > 0 {
            parts.append(L("读了 \(files) 个文件"))
        }
        if searchCount > 0 {
            parts.append(L("搜索 \(searchCount) 次"))
        }
        if globCount > 0 {
            parts.append(L("查找 \(globCount) 次"))
        }
        if parts.isEmpty {
            return L("读取与搜索 · \(tools.count) 次调用")
        }
        return L("探索") + " · " + parts.joined(separator: " · ")
    }

    /// Extracts a compact line-range selector (e.g. `:1–100` or `:240+`) for Read calls.
    public static func readRange(_ tool: VisibleTool) -> String? {
        guard ["read", "read_file", "readfile"].contains(tool.name.lowercased()),
              let input = tool.input else { return nil }
        let offset = input["line_offset"].int ?? input["offset"].int ?? input["start_line"].int
        let limit = input["n_lines"].int ?? input["limit"].int
        if let offset, offset > 0 {
            if let limit, limit > 0 {
                return "\(offset)–\(offset + limit - 1)"
            }
            return "\(offset)+"
        }
        if let offset, offset < 0 {
            return L("末尾 \(-offset) 行")
        }
        if let limit, limit > 0 {
            return "1–\(limit)"
        }
        return nil
    }

    /// Formats merged line-range selectors on the same file: `:1–100, 101–250, …, 800–900`.
    public static func formatMergedReadRanges(_ ranges: [String]) -> String {
        var unique: [String] = []
        for r in ranges where !r.isEmpty && !unique.contains(r) {
            unique.append(r)
        }
        guard !unique.isEmpty else { return "" }
        if unique.count <= 3 {
            return ":" + unique.joined(separator: ", ")
        }
        return ":\(unique[0]), \(unique[1]), …, \(unique[unique.count - 1])"
    }

    /// Strips outer `/bin/bash -lc "..."` and leading `cd <dir> &&` boilerplate from shell commands.
    public static func cleanShellCommand(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.range(of: #"^(?:/usr/bin/env\s+)?(?:/bin/)?(?:zsh|bash|sh)\s+-(?:l?c)\s+"#, options: .regularExpression) {
            var inner = String(text[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (inner.hasPrefix("\"") && inner.hasSuffix("\"")) || (inner.hasPrefix("'") && inner.hasSuffix("'")) {
                inner = String(inner.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text = inner
        }
        if let cdMatch = text.range(of: #"^cd\s+(?:"[^"]+"|'[^']+'|\S+)\s*&&\s*"#, options: .regularExpression) {
            text = String(text[cdMatch.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Zed-style 10-second elapsed threshold: tools finishing under 10s stay quiet;
    /// slow tools (>= 10s) report a compact duration badge (`14s`, `1m 20s`).
    /// Never calls `.display` on structured `.object` outputs so collapsed tool cards
    /// never pay JSON serialization cost.
    public static func slowDurationLabel(_ tool: VisibleTool) -> String? {
        guard tool.status != .running else { return nil }
        var seconds: Double?
        if let ms = tool.output?["duration_ms"].int ?? tool.output?["elapsed_ms"].int {
            seconds = Double(ms) / 1000.0
        } else if let sec = tool.output?["duration_seconds"].int ?? tool.output?["elapsed_seconds"].int {
            seconds = Double(sec)
        } else if case .string(let text)? = tool.output, text.hasPrefix("Wall time:") { // l10n-ignore
            let firstLine = text.prefix(64)
            if let range = firstLine.range(of: #"Wall time:\s*([0-9]+(?:\.[0-9]+)?)\s*seconds"#, options: .regularExpression) { // l10n-ignore
                let numStr = firstLine[range].replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)
                seconds = Double(numStr)
            }
        }
        guard let seconds, seconds >= 10 else { return nil }
        let rounded = Int(seconds.rounded())
        if rounded < 60 {
            return "\(rounded)s"
        }
        let mins = rounded / 60
        let rem = rounded % 60
        return rem > 0 ? "\(mins)m \(rem)s" : "\(mins)m"
    }
}

public struct ToolInlineDiff: Equatable, Sendable {
    public enum LineKind: Equatable, Sendable {
        case context, removed, added, header
    }
    public struct Line: Equatable, Sendable {
        public let kind: LineKind
        public let text: String
        public init(kind: LineKind, text: String) {
            self.kind = kind
            self.text = text
        }
    }
    public let path: String
    public let stat: SessionEditStat
    public let lines: [Line]
    public let truncatedCount: Int

    public static func derive(from tool: VisibleTool, maxLines: Int = 28) -> Self? {
        guard let input = tool.input else { return nil }
        let name = tool.name.lowercased()
        let rawPath = ToolPresentation.path(tool) ?? ""
        switch name {
        case "edit", "edit_file", "editfile":
            guard let old = input["old_string"].string ?? input["oldString"].string,
                  let new = input["new_string"].string ?? input["newString"].string else { return nil }
            let oldLines = old.components(separatedBy: "\n")
            let newLines = new.components(separatedBy: "\n")
            var prefix = 0
            while prefix < oldLines.count && prefix < newLines.count && oldLines[prefix] == newLines[prefix] {
                prefix += 1
            }
            var oldSuffix = oldLines.count
            var newSuffix = newLines.count
            while oldSuffix > prefix && newSuffix > prefix && oldLines[oldSuffix - 1] == newLines[newSuffix - 1] {
                oldSuffix -= 1
                newSuffix -= 1
            }
            var all: [Line] = []
            let contextBefore = max(0, prefix - 2)
            for idx in contextBefore..<prefix {
                all.append(Line(kind: .context, text: "  " + oldLines[idx]))
            }
            for idx in prefix..<oldSuffix {
                all.append(Line(kind: .removed, text: "− " + oldLines[idx]))
            }
            for idx in prefix..<newSuffix {
                all.append(Line(kind: .added, text: "+ " + newLines[idx]))
            }
            let contextAfter = min(newLines.count, newSuffix + 2)
            for idx in newSuffix..<contextAfter {
                all.append(Line(kind: .context, text: "  " + newLines[idx]))
            }
            let stat = SessionEditStat(additions: max(0, newSuffix - prefix), deletions: max(0, oldSuffix - prefix))
            let clipped = Array(all.prefix(maxLines))
            return Self(path: rawPath, stat: stat, lines: clipped, truncatedCount: max(0, all.count - clipped.count))
        case "write", "write_file", "writefile":
            guard let content = input["content"].string, !content.isEmpty else { return nil }
            let newLines = content.components(separatedBy: "\n")
            let all = newLines.map { Line(kind: .added, text: "+ " + $0) }
            let clipped = Array(all.prefix(maxLines))
            return Self(path: rawPath, stat: SessionEditStat(additions: newLines.count, deletions: 0),
                        lines: clipped, truncatedCount: max(0, all.count - clipped.count))
        case "apply_patch", "filechange":
            let patchText: String?
            if let direct = input["patch"].string ?? input["diff"].string {
                patchText = direct
            } else if !input["changes"].array.isEmpty {
                patchText = input["changes"].array.compactMap { change -> String? in
                    guard let p = change["path"].string, let d = change["diff"].string else { return nil }
                    return "--- \(p)\n\(d)"
                }.joined(separator: "\n")
            } else {
                patchText = nil
            }
            guard let patchText, !patchText.isEmpty else { return nil }
            var all: [Line] = []
            var adds = 0, dels = 0
            for raw in patchText.components(separatedBy: "\n") {
                if raw.hasPrefix("+++ ") || raw.hasPrefix("--- ") || raw.hasPrefix("@@") {
                    all.append(Line(kind: .header, text: raw))
                } else if raw.hasPrefix("+") {
                    adds += 1
                    all.append(Line(kind: .added, text: "+ " + String(raw.dropFirst())))
                } else if raw.hasPrefix("-") {
                    dels += 1
                    all.append(Line(kind: .removed, text: "− " + String(raw.dropFirst())))
                } else {
                    all.append(Line(kind: .context, text: "  " + raw))
                }
            }
            let clipped = Array(all.prefix(maxLines))
            return Self(path: rawPath, stat: SessionEditStat(additions: adds, deletions: dels),
                        lines: clipped, truncatedCount: max(0, all.count - clipped.count))
        default:
            return nil
        }
    }
}
