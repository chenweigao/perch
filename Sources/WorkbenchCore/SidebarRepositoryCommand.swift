import Foundation

/// Resolve on the owning machine. Git's first worktree is the main checkout,
/// regardless of the linked checkout's name, branch, or current subdirectory.
public enum SidebarRepositoryCommand {
    public static func command(directories: [String]) -> String {
        let script = """
        export GIT_OPTIONAL_LOCKS=0
        for directory do
          printf '%s\\0' "$directory"
          git -C "$directory" --no-pager worktree list --porcelain -z 2>/dev/null | base64 | tr -d '\\n'
          printf '\\0'
        done
        """
        return (["/bin/sh", "-c", script, "perch-projects"] + directories)
            .map(SSHCommand.quote).joined(separator: " ")
    }

    /// Empty roots denote non-repositories; paths are NUL-delimited, including
    /// spaces, shell metacharacters, non-ASCII text and embedded newlines.
    public static func parse(_ data: Data, directories: [String]) throws -> [String: String] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count == directories.count * 2 + 1, fields.last?.isEmpty == true else {
            throw WorkbenchError("Invalid repository response")
        }
        var roots: [String: String] = [:]
        for (index, directory) in directories.enumerated() {
            guard String(decoding: fields[index * 2], as: UTF8.self) == directory,
                  let decoded = Data(base64Encoded: Data(fields[index * 2 + 1])) else {
                throw WorkbenchError("Invalid repository response")
            }
            let first = decoded.split(separator: 0).first.map { String(decoding: $0, as: UTF8.self) } ?? ""
            roots[directory] = first.hasPrefix("worktree /") ? String(first.dropFirst(9)) : ""
        }
        return roots
    }
}
