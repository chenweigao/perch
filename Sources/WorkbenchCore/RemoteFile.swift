import Foundation

public struct RemoteDirectoryEntry: Equatable, Identifiable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public var id: String { name }
}

public enum RemoteFileContent: Equatable, Sendable {
    case directory([RemoteDirectoryEntry])
    case text(String, truncated: Bool, size: Int)
    case binary(size: Int)
    case denied
    case missing
}

public enum RemoteFilePath {
    /// Resolves what the user typed against the session's remote working directory.
    /// Remote paths are POSIX even though the Mac side is also POSIX: never route
    /// them through URL/FileManager, which would resolve against the local disk.
    public static func resolve(_ input: String, cwd: String) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw WorkbenchError("请输入远端路径。") }
        guard !raw.contains("\0") else { throw WorkbenchError("路径包含无效字符。") }
        let base: String
        if raw.hasPrefix("/") { base = raw }
        else if raw == "~" || raw.hasPrefix("~/") { base = raw }
        else {
            guard cwd.hasPrefix("/") else { throw WorkbenchError("当前会话没有远端工作目录，请输入绝对路径。") }
            base = cwd + "/" + raw
        }
        // A leading ~ is expanded by the remote shell, so its components stay as typed.
        guard base.hasPrefix("/") else { return base }
        var components: [String] = []
        for part in base.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(part))
            }
        }
        return "/" + components.joined(separator: "/")
    }

    public static func parent(of path: String) -> String? {
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        return "/" + parent
    }

    public static func child(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}

public enum RemoteFileCommand {
    public static let readLimit = 1_048_576

    /// The remote script is fixed text; the path arrives as a positional parameter so
    /// it is never parsed as shell syntax. `--` keeps leading-hyphen names as operands.
    /// Reading stops at the limit instead of downloading the whole file first.
    static func script(limit: Int) -> String {
        """
        p=$1
        if [ -d "$p" ]; then
          if [ ! -x "$p" ] || [ ! -r "$p" ]; then printf 'kind=denied\\n'; exit 0; fi
          printf 'kind=dir\\n--\\n'
          ls -A -p -1 -- "$p"
        elif [ -e "$p" ]; then
          if [ ! -r "$p" ]; then printf 'kind=denied\\n'; exit 0; fi
          printf 'kind=file\\nsize=%s\\n--\\n' "$(wc -c < "$p")"
          head -c \(limit) -- "$p"
        else
          printf 'kind=missing\\n'
        fi
        """
    }

    public static func remoteCommand(path: String, limit: Int = readLimit) -> String {
        // Quote every operand separately; the path stays one argv element on the remote.
        ["/bin/sh", "-c", script(limit: limit), "perch-file-view", path]
            .map(SSHCommand.quote).joined(separator: " ")
    }

    public static func sshArguments(destination: String, controlPath: String?,
                                    path: String, limit: Int = readLimit) -> [String] {
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                         "-o", "ConnectTimeout=10"]
        if let controlPath, !controlPath.isEmpty { arguments += ["-S", controlPath] }
        arguments += [destination, remoteCommand(path: path, limit: limit)]
        return arguments
    }

    public static func parse(_ data: Data, limit: Int = readLimit) throws -> RemoteFileContent {
        guard let separator = data.range(of: Data("\n--\n".utf8)) else {
            let header = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if header == "kind=denied" { return .denied }
            if header == "kind=missing" { return .missing }
            throw WorkbenchError("远端返回了无法识别的结果。")
        }
        let header = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        let body = data[separator.upperBound...]
        var fields: [String: String] = [:]
        for line in header.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        switch fields["kind"] {
        case "dir":
            let entries = String(decoding: body, as: UTF8.self).split(separator: "\n").map { line -> RemoteDirectoryEntry in
                let isDirectory = line.hasSuffix("/")
                return RemoteDirectoryEntry(name: isDirectory ? String(line.dropLast()) : String(line),
                                            isDirectory: isDirectory)
            }
            return .directory(entries.sorted {
                $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                                 : $0.isDirectory
            })
        case "file":
            // BSD wc pads its count with leading spaces.
            let size = fields["size"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? body.count
            guard !body.contains(0) else { return .binary(size: size) }
            // Reading stops mid-character at the limit; drop that partial scalar
            // rather than showing replacement characters.
            var bytes = Data(body)
            let truncated = size > limit
            if truncated { while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
                           if let last = bytes.last, last & 0x80 != 0 { bytes.removeLast() } }
            guard let text = String(data: bytes, encoding: .utf8) else { return .binary(size: size) }
            return .text(text, truncated: truncated, size: size)
        default:
            throw WorkbenchError("远端返回了无法识别的结果。")
        }
    }
}
