import Foundation

public struct RemoteGitEntry: Equatable, Identifiable, Sendable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let worktreeStatus: Character
    public var id: String { path }
    public var untracked: Bool { indexStatus == "?" }
    public var hasStaged: Bool { !untracked && indexStatus != " " }
    public var hasUnstaged: Bool { !untracked && worktreeStatus != " " }
    public var label: String {
        if untracked { return "未跟踪" }
        func name(_ code: Character) -> String? {
            switch code {
            case "M": return "已修改"
            case "A": return "新增"
            case "D": return "已删除"
            case "R": return "重命名"
            case "C": return "复制"
            case "T": return "类型变更"
            case "U": return "冲突"
            default: return nil
            }
        }
        let staged = name(indexStatus).map { "暂存：\($0)" }
        let unstaged = name(worktreeStatus).map { "未暂存：\($0)" }
        return [staged, unstaged].compactMap { $0 }.joined(separator: " · ")
    }
}

public struct RemoteGitWorktree: Equatable, Identifiable, Sendable {
    public let path: String
    public let head: String
    public let branch: String?
    public let detached: Bool
    public let bare: Bool
    public let locked: Bool
    public let lockedReason: String?
    public let prunable: Bool
    public let prunableReason: String?
    public let current: Bool
    public var id: String { path }
    public var branchName: String? {
        guard let branch else { return nil }
        return branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
    }
    public var selectable: Bool { !bare && !prunable }
}

public enum RemoteGitStatus: Equatable, Sendable {
    case notARepository
    case clean(root: String, worktrees: [RemoteGitWorktree])
    case changes(root: String, worktrees: [RemoteGitWorktree], entries: [RemoteGitEntry])

    public var root: String? {
        switch self {
        case .notARepository: return nil
        case .clean(let root, _), .changes(let root, _, _): return root
        }
    }
    public var worktrees: [RemoteGitWorktree] {
        switch self {
        case .notARepository: return []
        case .clean(_, let worktrees), .changes(_, let worktrees, _): return worktrees
        }
    }
}

public enum RemoteGitDiff: Equatable, Sendable {
    case text(String, truncated: Bool)
    case binary
    case empty
    case untracked
    case notARepository
}

public enum RemoteGitDirectoryHints {
    public static func candidates(messages: [KimiMessage], liveTools: [KimiLiveTool] = [],
                                  sessionDirectory: String, limit: Int = 12) -> [String] {
        guard limit > 0 else { return [] }
        let inputs = messages.flatMap(\.content).filter { $0.type == "tool_use" }.compactMap(\.input)
            + liveTools.compactMap(\.args)
        let fallback = sessionDirectory.hasPrefix("/") && !sessionDirectory.contains("\0")
            ? (sessionDirectory as NSString).standardizingPath : nil
        let hintLimit = fallback == nil ? limit : max(0, limit - 1)
        var result: [String] = []
        var seen = Set<String>()
        func absolute(_ value: String, relativeTo base: String?) -> String? {
            guard !value.isEmpty, !value.contains("\0") else { return nil }
            if value.hasPrefix("/") { return (value as NSString).standardizingPath }
            guard let base, base.hasPrefix("/") else { return nil }
            return ((base as NSString).appendingPathComponent(value) as NSString).standardizingPath
        }
        func appendHint(_ value: String?) {
            guard let value, result.count < hintLimit, seen.insert(value).inserted else { return }
            result.append(value)
        }
        for input in inputs.reversed() where result.count < hintLimit {
            let rawDirectory = ["cwd", "workdir", "working_directory"].compactMap { input[$0].string }.first
            let directory = rawDirectory.flatMap { absolute($0, relativeTo: fallback) }
            appendHint(directory)
            for key in ["path", "file_path"] {
                guard let path = input[key].string,
                      let resolved = absolute(path, relativeTo: directory ?? fallback) else { continue }
                appendHint(resolved)
                appendHint((resolved as NSString).deletingLastPathComponent)
            }
        }
        if let fallback, seen.insert(fallback).inserted { result.append(fallback) }
        return result
    }
}

/// Read-only Git inspection on the session's SSH host. Every invocation is a fixed
/// script with directories and paths passed as positional parameters, so nothing a
/// user types is ever parsed as shell syntax.
public enum RemoteGitCommand {
    public static let diffLimit = 262_144

    /// Paired with GIT_OPTIONAL_LOCKS=0 to avoid configured helpers and index refreshes.
    private static let safety = "--no-pager -c core.pager=cat -c core.fsmonitor=false -c diff.external= -c diff.noprefix=false"

    private static let guardScript = """
    export GIT_OPTIONAL_LOCKS=0
    cd -- "$1" 2>/dev/null || { printf 'kind=notrepo\\n'; exit 0; }
    if ! git \(safety) rev-parse --show-toplevel >/dev/null 2>&1; then printf 'kind=notrepo\\n'; exit 0; fi
    """

    static func statusScript() -> String {
        """
        export GIT_OPTIONAL_LOCKS=0
        root=
        for candidate do
          [ -n "$candidate" ] || continue
          case "$candidate" in
            '~') candidate=$HOME ;;
            '~/'*) candidate=$HOME/${candidate#??} ;;
          esac
          root=$(git \(safety) -C "$candidate" rev-parse --show-toplevel 2>/dev/null) && break
          root=
        done
        [ -n "$root" ] || { printf 'kind=notrepo\\n'; exit 0; }
        cd -- "$root" 2>/dev/null || { printf 'kind=notrepo\\n'; exit 0; }
        printf 'kind=status-v2\\n--\\n%s\\0' "$root"
        git \(safety) status --porcelain=v1 -z --untracked-files=normal || exit $?
        printf '\\0'
        git \(safety) worktree list --porcelain -z
        """
    }

    /// Reads one extra byte so truncation is detected rather than assumed.
    static func diffScript(staged: Bool, limit: Int) -> String {
        """
        \(guardScript)
        printf 'kind=diff\\n--\\n'
        git \(safety) diff --no-ext-diff --no-textconv\(staged ? " --cached" : "") -- "$2" \
          | head -c \(limit + 1)
        """
    }

    public static func statusCommand(directory: String) -> String {
        statusCommand(directories: [directory])
    }

    public static func statusCommand(directories: [String]) -> String {
        (["/bin/sh", "-c", statusScript(), "perch-git"] + directories)
            .map(SSHCommand.quote).joined(separator: " ")
    }

    public static func diffCommand(directory: String, path: String, staged: Bool,
                                   limit: Int = diffLimit) -> String {
        ["/bin/sh", "-c", diffScript(staged: staged, limit: limit), "perch-git", directory, path]
            .map(SSHCommand.quote).joined(separator: " ")
    }

    public static func sshArguments(destination: String, command: String) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
         destination, command]
    }

    private static func body(_ data: Data) throws -> (kind: String, fields: [String: String], body: Data) {
        guard let separator = data.range(of: Data("\n--\n".utf8)) else {
            let header = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard header == "kind=notrepo" else { throw WorkbenchError("远端返回了无法识别的结果。") }
            return ("notrepo", [:], Data())
        }
        var fields: [String: String] = [:]
        for line in String(decoding: data[..<separator.lowerBound], as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard let kind = fields["kind"] else { throw WorkbenchError("远端返回了无法识别的结果。") }
        return (kind, fields, Data(data[separator.upperBound...]))
    }

    public static func parseStatus(_ data: Data) throws -> RemoteGitStatus {
        let result = try body(data)
        if result.kind == "notrepo" { return .notARepository }
        guard result.kind == "status-v2" else { throw WorkbenchError("远端返回了无法识别的结果。") }
        let records = result.body.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let root = records.first, !root.isEmpty,
              let separator = records.dropFirst().firstIndex(where: \.isEmpty) else {
            throw WorkbenchError("远端返回了无法识别的结果。")
        }
        let entries = parseEntries(Array(records[1..<separator]))
        let worktrees = parseWorktrees(Array(records[records.index(after: separator)...]), currentRoot: root)
        return entries.isEmpty ? .clean(root: root, worktrees: worktrees)
                               : .changes(root: root, worktrees: worktrees, entries: entries)
    }

    private static func parseEntries(_ records: [String]) -> [RemoteGitEntry] {
        var entries: [RemoteGitEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count > 3 else { continue }
            let codes = Array(record.prefix(2))
            let path = String(record.dropFirst(3))
            var original: String?
            if codes[0] == "R" || codes[0] == "C" || codes[1] == "R" || codes[1] == "C", index < records.count {
                original = records[index]
                index += 1
            }
            entries.append(RemoteGitEntry(path: path, originalPath: original,
                                          indexStatus: codes[0], worktreeStatus: codes[1]))
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func parseWorktrees(_ records: [String], currentRoot: String) -> [RemoteGitWorktree] {
        var result: [RemoteGitWorktree] = []
        var fields: [String: String] = [:]
        var flags = Set<String>()
        func finish() {
            guard let path = fields["worktree"] else { fields = [:]; flags = []; return }
            result.append(RemoteGitWorktree(path: path, head: fields["HEAD"] ?? "", branch: fields["branch"],
                detached: flags.contains("detached"), bare: flags.contains("bare"),
                locked: flags.contains("locked"), lockedReason: fields["locked"],
                prunable: flags.contains("prunable"), prunableReason: fields["prunable"], current: path == currentRoot))
            fields = [:]; flags = []
        }
        for record in records {
            if record.isEmpty { finish(); continue }
            let parts = record.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            flags.insert(key)
            if parts.count == 2 { fields[key] = String(parts[1]) }
        }
        finish()
        return result.sorted {
            if $0.current != $1.current { return $0.current }
            let left = $0.branchName ?? $0.path
            let right = $1.branchName ?? $1.path
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    public static func parseDiff(_ data: Data, limit: Int = diffLimit) throws -> RemoteGitDiff {
        let result = try body(data)
        if result.kind == "notrepo" { return .notARepository }
        guard result.kind == "diff" else { throw WorkbenchError("远端返回了无法识别的结果。") }
        guard !result.body.isEmpty else { return .empty }
        var bytes = result.body
        let truncated = bytes.count > limit
        if truncated {
            bytes = bytes.prefix(limit)
            while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
            if let last = bytes.last, last & 0x80 != 0 { bytes.removeLast() }
        }
        guard let text = String(data: bytes, encoding: .utf8) else { return .binary }
        if !truncated, text.contains("\nBinary files ") || text.hasPrefix("Binary files ") { return .binary }
        return .text(text, truncated: truncated)
    }
}
