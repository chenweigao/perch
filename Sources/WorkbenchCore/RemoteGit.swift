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
        let worktree = name(worktreeStatus).map { "工作区：\($0)" }
        return [staged, worktree].compactMap { $0 }.joined(separator: " · ")
    }
}

public enum RemoteGitStatus: Equatable, Sendable {
    case notARepository
    case clean(root: String)
    case changes(root: String, entries: [RemoteGitEntry])
}

public enum RemoteGitDiff: Equatable, Sendable {
    case text(String, truncated: Bool)
    case binary
    case empty
    case untracked
    case notARepository
}

/// Read-only Git inspection on the session's SSH host. Every invocation is a fixed
/// script with the directory and path passed as positional parameters, so nothing a
/// user types is ever parsed as shell syntax.
public enum RemoteGitCommand {
    public static let diffLimit = 262_144

    /// `diff.external=` and `--no-ext-diff` stop a repository's own config from
    /// running an external program, and `--no-textconv` stops attribute-driven
    /// filters. Without these, viewing a diff would execute repository-defined
    /// commands on the remote host.
    private static let safety = "-c core.pager=cat -c diff.external= -c diff.noprefix=false"

    private static let guardScript = """
    cd -- "$1" 2>/dev/null || { printf 'kind=notrepo\\n'; exit 0; }
    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then printf 'kind=notrepo\\n'; exit 0; fi
    """

    static func statusScript() -> String {
        """
        \(guardScript)
        printf 'kind=status\\nroot=%s\\n--\\n' "$(git rev-parse --show-toplevel)"
        git --no-pager \(safety) status --porcelain=v1 -z --untracked-files=normal
        """
    }

    /// Reads one extra byte so truncation is detected rather than assumed.
    static func diffScript(staged: Bool, limit: Int) -> String {
        """
        \(guardScript)
        printf 'kind=diff\\n--\\n'
        git --no-pager \(safety) diff --no-ext-diff --no-textconv\(staged ? " --cached" : "") -- "$2" \
          | head -c \(limit + 1)
        """
    }

    public static func statusCommand(directory: String) -> String {
        ["/bin/sh", "-c", statusScript(), "perch-git", directory].map(SSHCommand.quote).joined(separator: " ")
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
        guard result.kind == "status", let root = result.fields["root"] else {
            throw WorkbenchError("远端返回了无法识别的结果。")
        }
        // -z output is NUL-terminated, and a rename emits its original path as a
        // separate following field rather than an arrow-joined string.
        var records = result.body.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if records.last?.isEmpty == true { records.removeLast() }
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
        let sorted = entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return sorted.isEmpty ? .clean(root: root) : .changes(root: root, entries: sorted)
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
