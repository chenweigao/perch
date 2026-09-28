import Foundation

public struct ProjectFileReference: Equatable {
    public let path: String
    public let range: NSRange
    private static let referencePattern = try! NSRegularExpression(pattern: #"@("(?:[^"\\]|\\.)*")"#)
    private static let queryPattern = try! NSRegularExpression(pattern: #"(?:^|\s)(@[^\s@"]*)$"#)

    public static func token(path: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return "@" + String(decoding: try! encoder.encode(path), as: UTF8.self)
    }

    public static func references(in draft: String) -> [Self] {
        let source = draft as NSString
        return referencePattern.matches(in: draft, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let json = source.substring(with: match.range(at: 1))
            guard let path = try? JSONDecoder().decode(String.self, from: Data(json.utf8)), path.hasPrefix("/") else { return nil }
            return Self(path: path, range: match.range)
        }
    }

    public static func query(in draft: String, selection: NSRange) -> (range: NSRange, filter: String)? {
        let text = draft as NSString
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let prefix = text.substring(to: selection.location)
        guard let match = queryPattern.firstMatch(in: prefix, range: NSRange(location: 0, length: selection.location)) else { return nil }
        let range = match.range(at: 1)
        return (range, String(text.substring(with: range).dropFirst()))
    }
}

public struct ProjectFileCatalog {
    public let root: String
    public let paths: [String]
    public static let limit = 1_048_576

    public static func command(directory: String) -> String {
        let script = """
        \(RemoteGitCommand.guardScript)
        root=$(git \(RemoteGitCommand.safety) rev-parse --show-toplevel) || exit $?
        printf '%s\\0' "$root"
        # Keep catalog bytes on fd 3 and capture Git's status separately on fd 4.
        # Drain excess bytes so the output cap does not give Git a SIGPIPE error.
        exec 3>&1
        status=$(
          exec 4>&1
          { git \(RemoteGitCommand.safety) -C "$root" ls-files --full-name --cached --others --exclude-standard -z --; printf '%s' "$?" >&4; } \\
            | { head -c \(limit + 1); cat >/dev/null; } >&3
        )
        exit "$status"
        """
        return ["/bin/sh", "-c", script, "perch-project-files", directory].map(SSHCommand.quote).joined(separator: " ")
    }

    public static func parse(_ data: Data) throws -> Self {
        guard let separator = data.firstIndex(of: 0),
              let root = String(data: data[..<separator], encoding: .utf8), root.hasPrefix("/") else {
            throw WorkbenchError(L("当前目录不是 Git 项目，请在文件面板按路径引用。"))
        }
        let body = data[data.index(after: separator)...]
        guard body.count <= limit else { throw WorkbenchError(L("项目文件列表过大，请在文件面板按路径引用。")) }
        let paths = String(decoding: body, as: UTF8.self).split(separator: "\0").map(String.init)
        return Self(root: root, paths: Set(paths).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    public func matches(_ query: String) -> [String] {
        guard !query.isEmpty else { return Array(paths.prefix(30)) }
        var exact: [String] = [], prefix: [String] = [], other: [String] = []
        for path in paths where path.localizedCaseInsensitiveContains(query) {
            let name = (path as NSString).lastPathComponent
            if name.localizedCaseInsensitiveCompare(query) == .orderedSame {
                exact.append(path)
            } else if name.range(of: query, options: [.anchored, .caseInsensitive], locale: .current) != nil {
                prefix.append(path)
            } else {
                other.append(path)
            }
        }
        return Array((exact + prefix + other).prefix(30))
    }
}
