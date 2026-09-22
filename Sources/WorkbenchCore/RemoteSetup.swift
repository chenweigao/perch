import Foundation

/// Saved endpoints contain routing information only. Agent credentials stay remote.
public enum RemoteSetup {
    public static let agents: [SessionKind] = [.kimi, .omp, .qoder, .dsh, .terminal]

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

    public static func directoryListCommand(_ directory: String) -> String {
        // NUL-separated names preserve whitespace and shell metacharacters.
        let root = SSHCommand.quote(directory)
        return "test -d " + root + " && test -r " + root + " && test -x " + root
            + " && for entry in " + root + "/* " + root + "/.[!.]* " + root + "/..?*; do [ -d \"$entry\" ] && printf '%s\\0' \"$entry\"; done;"
            + " test -d " + root + " && test -r " + root + " && test -x " + root
    }

    public static func kimiStartCommand(port: Int) -> String {
        // Never replaces a running service or changes its permission mode.
        "umask 077; mkdir -p ~/.local/state/perch; nohup kimi web --host 127.0.0.1 --port \(port) --no-open >> ~/.local/state/perch/kimi-web.log 2>&1 < /dev/null &"
    }
}
