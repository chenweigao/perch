import Foundation

/// A committed branch review, pinned to the commits read when comparison began.
/// Later branch movement or uncommitted edits cannot change an opened file's diff.
public struct RemoteGitComparison: Equatable, Sendable {
    public let root: String
    public let baseRef: String
    public let baseCommit: String
    public let mergeBase: String
    public let headCommit: String
    public let entries: [RemoteGitEntry]

    public var scope: String { "\(baseRef) · \(mergeBase)…\(headCommit) (committed)" }
}

extension RemoteGitCommand {
    public static func comparisonCommand(directory: String, base: String) -> String {
        let script = """
        \(guardScript)
        base=$(git \(safety) rev-parse --verify --end-of-options "$2^{commit}" 2>/dev/null) || { printf 'kind=invalidbase\\n'; exit 0; }
        head=$(git \(safety) rev-parse --verify HEAD 2>/dev/null) || { printf 'kind=nohead\\n'; exit 0; }
        ancestor=$(git \(safety) merge-base "$base" "$head") || { printf 'kind=unrelated\\n'; exit 0; }
        root=$(git \(safety) rev-parse --show-toplevel) || exit $?
        printf 'kind=comparison\\n--\\n%s\\0%s\\0%s\\0%s\\0%s\\0' "$root" "$2" "$base" "$ancestor" "$head"
        git \(safety) diff --name-status -z --find-renames --no-ext-diff --no-textconv "$ancestor" "$head" --
        """
        return ["/bin/sh", "-c", script, "perch-git", directory, base].map(SSHCommand.quote).joined(separator: " ")
    }

    public static func comparisonDiffCommand(comparison: RemoteGitComparison, entry: RemoteGitEntry,
                                             limit: Int = diffLimit) -> String {
        let script = """
        \(guardScript)
        base=$(git \(safety) rev-parse --verify --end-of-options "$2^{commit}") || exit $?
        head=$(git \(safety) rev-parse --verify --end-of-options "$3^{commit}") || exit $?
        shift 3
        printf 'kind=diff\\n--\\n'
        git \(safety) --literal-pathspecs diff --find-renames --no-ext-diff --no-textconv "$base" "$head" -- "$@" | head -c \(limit + 1)
        """
        var arguments = ["/bin/sh", "-c", script, "perch-git", comparison.root, comparison.mergeBase, comparison.headCommit, entry.path]
        if let original = entry.originalPath { arguments.append(original) }
        return arguments.map(SSHCommand.quote).joined(separator: " ")
    }

    public static func parseComparison(_ data: Data) throws -> RemoteGitComparison {
        guard let separator = data.range(of: Data("\n--\n".utf8)) else {
            switch String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
            case "kind=notrepo": throw WorkbenchError("所选目录不是可用的 Git 工作树。")
            case "kind=invalidbase": throw WorkbenchError(L("目标分支或提交不存在于当前仓库；请先在执行环境中更新引用。"))
            case "kind=nohead": throw WorkbenchError(L("当前分支还没有提交，无法比较。"))
            case "kind=unrelated": throw WorkbenchError(L("目标与当前分支没有共同祖先。"))
            default: throw WorkbenchError("远端返回了无法识别的结果。")
            }
        }
        guard String(decoding: data[..<separator.lowerBound], as: UTF8.self) == "kind=comparison" else {
            throw WorkbenchError("远端返回了无法识别的结果。")
        }
        let fields = data[separator.upperBound...].split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard fields.count >= 6, fields.prefix(5).allSatisfy({ !$0.isEmpty }) else {
            throw WorkbenchError("远端返回了无法识别的结果。")
        }
        var entries: [RemoteGitEntry] = [], index = 5
        while index < fields.count - 1 {
            guard let code = fields[index].first, "ACDMRT".contains(code), index + 1 < fields.count else {
                throw WorkbenchError("远端返回了无法识别的结果。")
            }
            index += 1
            let first = fields[index]; index += 1
            var original: String?, path = first
            if code == "R" || code == "C" {
                guard index < fields.count - 1 else { throw WorkbenchError("远端返回了无法识别的结果。") }
                original = first; path = fields[index]; index += 1
            }
            entries.append(RemoteGitEntry(path: path, originalPath: original, indexStatus: " ", worktreeStatus: code))
        }
        return RemoteGitComparison(root: fields[0], baseRef: fields[1], baseCommit: fields[2], mergeBase: fields[3],
            headCommit: fields[4], entries: entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }
}
