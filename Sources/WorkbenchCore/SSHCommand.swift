import Foundation

public enum SSHCommand {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func validateDestination(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"),
              !value.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue == 0 }) else {
            throw WorkbenchError(L("请输入 SSH 配置别名或 user@host；端口和跳板机请配置在 ~/.ssh/config 中。"))
        }
    }

    public static func attach(host: SSHHost, binary: String, terminalID: String, controlPath: String) -> String {
        // Run the installed remote binary so attach and server use the same protocol.
        let remote = "exec \(quote(binary)) terminal attach \(quote(terminalID))"
        return (["/usr/bin/ssh", "-tt", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                 "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                 "-S", controlPath, host.destination, remote].map(quote)).joined(separator: " ")
    }

    /// A throwaway login shell on the host, multiplexed over the same control
    /// connection as attach. Unlike a Herdr pane nothing persists: the shell
    /// ends when the surface closes. An empty directory lands on the login
    /// directory; "~/..." expands on the remote side.
    public static func shell(host: SSHHost, directory: String, controlPath: String) -> String {
        let destination = directory.hasPrefix("~/") ? "\"$HOME\"/" + quote(String(directory.dropFirst(2))) : quote(directory)
        let remote = directory.isEmpty ? "exec ${SHELL:-/bin/sh} -l" : "cd \(destination) && exec ${SHELL:-/bin/sh} -l"
        return (["/usr/bin/ssh", "-tt", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                 "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                 "-S", controlPath, host.destination, remote].map(quote)).joined(separator: " ")
    }
}
