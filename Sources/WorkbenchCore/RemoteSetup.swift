import Foundation

public struct KimiRuntime: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case path, npmPrefix }
    public let path: String
    public let version: String
    public let source: Source
}

public enum KimiRuntimeProbeResult: Equatable, Sendable {
    case ready(KimiRuntime)
    case missing(npmPrefix: String?)
    case npmMissing
    case nodeMissing
    case nodeTooOld(version: String)
    case npmFailed
    case unusable(path: String, reason: String)
    case invalid(output: String)
}

/// Saved endpoints contain routing information only. Agent credentials stay remote.
public enum RemoteSetup {
    public static let agents: [SessionKind] = [.kimi, .omp, .qoder, .dsh, .codex, .claude, .terminal]

    public static func sshAliases(_ config: String) -> [String] {
        var aliases = Set<String>()
        for line in config.split(separator: "\n") {
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .replacingOccurrences(of: "=", with: " ").split(whereSeparator: \.isWhitespace)
            guard fields.first?.lowercased() == "host" else { continue }
            for field in fields.dropFirst() {
                let alias = String(field)
                if !alias.contains(where: { "*?!\"'".contains($0) }), (try? SSHCommand.validateDestination(alias)) != nil {
                    aliases.insert(alias)
                }
            }
        }
        return aliases.sorted()
    }

    public static func validate(_ host: SSHHost) throws {
        try SSHCommand.validateDestination(host.destination)
        guard (1...65535).contains(host.kimiPort) else { throw WorkbenchError(L("Kimi 端口须为 1–65535。")) }
        guard host.kimiTokenPath.hasPrefix("/") || host.kimiTokenPath.hasPrefix("~/"),
              !host.kimiTokenPath.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
            throw WorkbenchError(L("令牌路径须为远端绝对路径或以 ~/ 开头。"))
        }
    }

    public static func remotePath(_ path: String) -> String {
        path.hasPrefix("~/") ? "\"$HOME\"/" + SSHCommand.quote(String(path.dropFirst(2))) : SSHCommand.quote(path)
    }

    public static func sshArguments(_ destination: String, command: String) throws -> [String] {
        try SSHCommand.validateDestination(destination)
        return ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", destination, command]
    }

    public static func terminalCommand(destination: String, command: String? = nil) throws -> String {
        try SSHCommand.validateDestination(destination)
        var args = ["ssh", "-tt", destination]
        if let command { args.append(command) }
        return args.map(SSHCommand.quote).joined(separator: " ")
    }

    public static func sshHint(_ error: String) -> String {
        let message = error.lowercased()
        if message.contains("host key") || message.contains("host identification") {
            return L("在终端确认主机指纹；如果指纹已改变，先核实服务器身份，再更新 SSH 配置。")
        }
        if message.contains("permission denied") || message.contains("authentication") {
            return L("在终端完成登录，并将密钥加入 SSH agent。Perch 需要免交互 SSH 登录。")
        }
        if message.contains("resolve hostname") {
            return L("检查 SSH 别名或主机名；端口、用户名和跳板机可配置在 ~/.ssh/config。")
        }
        return L("检查网络、VPN 与 SSH 配置。在终端连接成功后，返回这里重新检查。")
    }

    public static let kimiRuntimeProbeCommand = #"""
    if command -v kimi >/dev/null 2>&1; then
        perch_kimi="$(command -v kimi)"
        perch_source=path
    else
        if ! command -v npm >/dev/null 2>&1; then
            printf 'npm_missing\0'
            exit 0
        fi
        if ! command -v node >/dev/null 2>&1; then
            printf 'node_missing\0'
            exit 0
        fi
        perch_node_version="$(node --version 2>/dev/null)"
        if ! node -e 'const v=process.versions.node.split(".").map(Number); process.exit(v[0] > 22 || (v[0] === 22 && v[1] >= 19) ? 0 : 1)' >/dev/null 2>&1; then
            printf 'node_old\0%s\0' "$perch_node_version"
            exit 0
        fi
        perch_prefix="$(npm prefix -g 2>/dev/null)" || {
            printf 'npm_failed\0'
            exit 0
        }
        perch_kimi="${perch_prefix%/}/bin/kimi"
        if [ ! -x "$perch_kimi" ]; then
            printf 'missing\0%s\0' "$perch_prefix"
            exit 0
        fi
        perch_source=npm
    fi
    perch_version="$("$perch_kimi" --version 2>&1)"
    perch_status=$?
    if [ "$perch_status" -ne 0 ]; then
        printf 'unusable\0%s\0%s\0' "$perch_kimi" "$perch_version"
        exit 0
    fi
    printf 'ready\0%s\0%s\0%s\0' "$perch_kimi" "$perch_version" "$perch_source"
    """#

    public static func parseKimiRuntimeProbe(_ data: Data) -> KimiRuntimeProbeResult {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let status = fields.first else { return .invalid(output: "") }
        switch status {
        case "ready" where fields.count >= 4:
            let source: KimiRuntime.Source = fields[3] == "npm" ? .npmPrefix : .path
            return .ready(KimiRuntime(path: fields[1], version: fields[2], source: source))
        case "missing": return .missing(npmPrefix: fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil)
        case "npm_missing": return .npmMissing
        case "node_missing": return .nodeMissing
        case "node_old": return .nodeTooOld(version: fields.count > 1 ? fields[1] : "")
        case "npm_failed": return .npmFailed
        case "unusable" where fields.count >= 3: return .unusable(path: fields[1], reason: fields[2])
        default: return .invalid(output: String(decoding: data, as: UTF8.self))
        }
    }

    public static func directoryListCommand(_ directory: String) -> String {
        // NUL-separated names preserve whitespace and shell metacharacters.
        let root = SSHCommand.quote(directory)
        return "test -d " + root + " && test -r " + root + " && test -x " + root
            + " && for entry in " + root + "/* " + root + "/.[!.]* " + root + "/..?*; do [ -d \"$entry\" ] && printf '%s\\0' \"$entry\"; done;"
            + " test -d " + root + " && test -r " + root + " && test -x " + root
    }

    public static func kimiStartCommand(binaryPath: String, port: Int) -> String {
        // Never replaces a running service or changes its permission mode.
        "umask 077; mkdir -p ~/.local/state/perch; nohup \(SSHCommand.quote(binaryPath)) web --host 127.0.0.1 --port \(port) --no-open >> ~/.local/state/perch/kimi-web.log 2>&1 < /dev/null &"
    }
}
