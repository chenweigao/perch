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

public enum BridgeProbeResult: Equatable, Sendable {
    case installed(version: Int)
    case missing
    case unreadable
    case invalid(output: String)
}

/// What `local-agent-service.py --agent kimi` reports about the Kimi Web it ensured.
public struct KimiServiceEndpoint: Equatable, Sendable {
    public enum RestartReason: String, Equatable, Sendable { case update, settings }
    public let port: Int
    public let token: String
    /// Perch started this instance, so it is the only kind Perch restarts.
    public let owned: Bool
    /// The previous instance was stopped and this one started during the check.
    public let replaced: Bool
    public let installedVersion: String?
    public let runningVersion: String?
    public let restartReason: RestartReason?
    /// Busy sessions an update or new settings wait for; -1 when Perch cannot confirm
    /// the service is idle, or a restart already failed to apply the update.
    public let restartPending: Int?

    public init(port: Int, token: String, owned: Bool = false, replaced: Bool = false,
                installedVersion: String? = nil, runningVersion: String? = nil,
                restartReason: RestartReason? = nil, restartPending: Int? = nil) {
        self.port = port; self.token = token; self.owned = owned; self.replaced = replaced
        self.installedVersion = installedVersion; self.runningVersion = runningVersion
        self.restartReason = restartReason; self.restartPending = restartPending
    }
}

/// Saved endpoints contain routing information only. Agent credentials stay remote.
public enum RemoteSetup {
    public static let agents: [SessionKind] = [.kimi, .omp, .qoder, .qoderintl, .dsh, .codex, .claude, .terminal]

    /// The bridge protocol this build speaks. It must match SERVICE_VERSION in
    /// remote/native-agent-service.py; scripts/check-version.py enforces that.
    public static let bridgeServiceVersion = 9

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
        for (name, value) in host.kimiEnvironment {
            guard validEnvironmentName(name), !value.contains(where: { $0.isWhitespace || $0.asciiValue == 0 }) else {
                throw WorkbenchError(L("Kimi Web 环境变量 \(name) 无效。"))
            }
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

    /// Reads the installed bridge's version without starting or restarting it.
    public static let bridgeProbeCommand = #"""
    perch_script="$HOME/.local/share/agent-workbench/native/native-agent-service.py"
    if [ ! -f "$perch_script" ]; then
        printf 'missing\0'
        exit 0
    fi
    perch_version="$(sed -n 's/^SERVICE_VERSION *= *\([0-9][0-9]*\) *$/\1/p' "$perch_script" | head -n 1)"
    if [ -z "$perch_version" ]; then
        printf 'unreadable\0'
        exit 0
    fi
    printf 'installed\0%s\0' "$perch_version"
    """#

    public static func parseBridgeProbe(_ data: Data) -> BridgeProbeResult {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let status = fields.first else { return .invalid(output: "") }
        switch status {
        case "missing": return .missing
        case "unreadable": return .unreadable
        case "installed" where fields.count >= 2:
            guard let version = Int(fields[1]) else { break }
            return .installed(version: version)
        default: break
        }
        return .invalid(output: String(decoding: data, as: UTF8.self))
    }

    public static func directoryListCommand(_ directory: String) -> String {
        // NUL-separated names preserve whitespace and shell metacharacters.
        let root = SSHCommand.quote(directory)
        let script = "test -d " + root + " && test -r " + root + " && test -x " + root
            + " && for entry in " + root + "/* " + root + "/.[!.]* " + root + "/..?*; do [ -d \"$entry\" ] && printf '%s\\0' \"$entry\"; done;"
            + " test -d " + root + " && test -r " + root + " && test -x " + root
        // SSH uses the login shell, which may reject unmatched globs (zsh).
        return "/bin/sh -c " + SSHCommand.quote(script)
    }

    /// Stopping an idle instance waits up to 90 s for its shutdown hooks before the
    /// replacement starts.
    public static let kimiEnsureTimeout: TimeInterval = 150

    /// Runs a script passed as the first argument, so the host needs no installed Perch
    /// file. The script stays compatible with Python 3.6.
    static let streamedScriptLoader = #"import base64,sys;exec(compile(base64.b64decode(sys.argv.pop(1)),"perch-kimi-web","exec"))"#

    /// Starts, reuses or replaces Perch's Kimi Web on the host and prints its endpoint.
    /// Only the 127.0.0.1 instance Perch started is ever stopped, and only while idle;
    /// a service the user runs is reused untouched.
    public static func kimiEnsureCommand(script: String, port: Int, tokenPath: String,
                                         environment: [String: String]) -> String {
        var arguments = ["python3", "-c", streamedScriptLoader, Data(script.utf8).base64EncodedString(),
                         "--agent", "kimi", "--port", String(port), "--token-path", tokenPath]
        for name in environment.keys.sorted() { arguments += ["--env", name + "=" + (environment[name] ?? "")] }
        return arguments.map(SSHCommand.quote).joined(separator: " ")
    }

    /// The service script packaged by scripts/build.sh; the Mac runs it for local Kimi
    /// and streams it to remote hosts.
    public static func kimiServiceScript() throws -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("RemoteSetup/remote/local-agent-service.py"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw WorkbenchError(L("此构建缺少 Kimi Web 托管组件。请使用 scripts/build.sh 打包的 Perch.app。"))
        }
        return script
    }

    public static func parseKimiServiceEndpoint(_ data: Data) throws -> KimiServiceEndpoint {
        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard let value, let port = value["port"].int, (1...65535).contains(port),
              let token = value["token"].string, !token.isEmpty else {
            throw WorkbenchError(L("托管的 Kimi Web 未返回连接信息。"))
        }
        return KimiServiceEndpoint(port: port, token: token, owned: value["owned"] == .bool(true),
                                   replaced: value["replaced"] == .bool(true),
                                   installedVersion: value["installedVersion"].string,
                                   runningVersion: value["runningVersion"].string,
                                   restartReason: value["restartReason"].string.flatMap { KimiServiceEndpoint.RestartReason(rawValue: $0) },
                                   restartPending: value["restartPending"].int)
    }

    /// `NAME=value` entries separated by spaces or new lines.
    public static func parseKimiEnvironment(_ text: String) throws -> [String: String] {
        var environment: [String: String] = [:]
        for entry in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, validEnvironmentName(parts[0]), !parts[1].contains("\0") else {
                throw WorkbenchError(L("环境变量须写成 NAME=value，名称只含英文字母、数字和下划线且不以数字开头：\(entry)"))
            }
            environment[parts[0]] = parts[1]
        }
        return environment
    }

    public static func formatKimiEnvironment(_ environment: [String: String]) -> String {
        environment.keys.sorted().map { $0 + "=" + (environment[$0] ?? "") }.joined(separator: " ")
    }

    /// ASCII letters, digits and `_`, not starting with a digit.
    static func validEnvironmentName(_ name: String) -> Bool {
        let values = name.unicodeScalars.map(\.value)
        guard let first = values.first, !(48...57).contains(first) else { return false }
        return values.allSatisfy { $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
}
