import Foundation

/// Resolve on the owning machine. Git's first worktree is the main checkout,
/// regardless of the linked checkout's name, branch, or current subdirectory.
public enum SidebarRepositoryCommand {
    public static func command(directories: [String]) -> String {
        let script = """
        export GIT_OPTIONAL_LOCKS=0
        command -v git >/dev/null 2>&1 || exit 127
        for directory do
          printf '%s\\0' "$directory"
          candidate=$directory
          if [ -f "$directory/PERCH_CLAIM.json" ]; then
            declared=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])).get("cwd"); print(p if isinstance(p,str) and p.startswith("/") and "\\0" not in p else "",end="")' "$directory/PERCH_CLAIM.json" 2>/dev/null) || declared=
            [ -z "$declared" ] || candidate=$declared
          fi
          printf '%s\\0' "$candidate"
          common=$(git -C "$candidate" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=
          primary=
          if [ -n "$common" ]; then
            configured=$(git --git-dir="$common" config --get core.worktree 2>/dev/null) || configured=
            if [ -n "$configured" ]; then
              primary=$(cd -- "$common" && cd -- "$configured" && pwd -P) || primary=
            fi
          fi
          {
            if [ -n "$primary" ]; then printf 'worktree %s\\0' "$primary"
            else git -C "$candidate" --no-pager worktree list --porcelain -z 2>/dev/null
            fi
          } | base64 | tr -d '\\n'
          printf '\\0'
        done
        """
        return (["/bin/sh", "-c", script, "perch-projects"] + directories)
            .map(SSHCommand.quote).joined(separator: " ")
    }

    /// Non-repositories retain their declared working directory, not a temporary
    /// classification. Paths are NUL-delimited, including
    /// spaces, shell metacharacters, non-ASCII text and embedded newlines.
    public static func parse(_ data: Data, directories: [String]) throws -> [String: String] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count == directories.count * 3 + 1, fields.last?.isEmpty == true else {
            throw WorkbenchError("Invalid repository response")
        }
        var roots: [String: String] = [:]
        for (index, directory) in directories.enumerated() {
            guard String(decoding: fields[index * 3], as: UTF8.self) == directory,
                  let decoded = Data(base64Encoded: Data(fields[index * 3 + 2])) else {
                throw WorkbenchError("Invalid repository response")
            }
            let first = decoded.split(separator: 0).first.map { String(decoding: $0, as: UTF8.self) } ?? ""
            roots[directory] = first.hasPrefix("worktree /") ? String(first.dropFirst(9))
                : String(decoding: fields[index * 3 + 1], as: UTF8.self)
        }
        return roots
    }
}
