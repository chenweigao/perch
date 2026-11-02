import Foundation
import WorkbenchCore

/// A host's SSH control channel, on demand. Features like the command-line
/// island multiplex over this master instead of paying a handshake per shell.
/// It carries no remote daemon state: `online` means the master is usable.
@MainActor
final class HostConnection: ObservableObject, Identifiable {
    @Published private(set) var host: SSHHost
    nonisolated let id: UUID
    @Published private var stateMessage: String.LocalizationValue = "未连接"
    var state: String { L(stateMessage) }
    func state(locale: Locale) -> String { L(stateMessage, locale: locale) }
    @Published private(set) var error: String?
    @Published private(set) var online = false
    @Published private(set) var wantsConnection = false
    @Published private(set) var updatedAt: Date?
    private(set) var controlPath = ""
    private var directory: URL?
    private var process: Process?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(host: SSHHost) { self.host = host; self.id = host.id }
    func updateHost(_ host: SSHHost) { self.host = host }

    func connect() {
        guard !host.isLocal else { return }
        disconnect()
        let token = UUID()
        generation = token
        wantsConnection = true
        stateMessage = "连接中"
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            var delay = 1
            while !Task.isCancelled && self.generation == token {
                do {
                    try await self.establish(token: token)
                    delay = 1
                    // No polling: the master exiting is the liveness signal.
                    while !Task.isCancelled && self.generation == token {
                        if self.process?.isRunning != true { throw WorkbenchError(L("SSH 隧道已退出")) }
                        try await Task.sleep(for: .seconds(2))
                    }
                } catch is CancellationError { break }
                catch {
                    guard self.generation == token else { break }
                    self.online = false
                    self.error = error.localizedDescription
                    self.stateMessage = "\(delay) 秒后重连"
                    self.stopTunnel()
                    do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    func disconnect() {
        generation = UUID()
        task?.cancel()
        task = nil
        stopTunnel()
        online = false
        wantsConnection = false
        stateMessage = "未连接"
        error = nil
    }

    private func stopTunnel() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func establish(token: UUID) async throws {
        try SSHCommand.validateDestination(host.destination)
        stateMessage = "连接中"
        let folder = URL(fileURLWithPath: "/tmp/awb-\(UUID().uuidString.prefix(12))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        directory = folder
        controlPath = folder.appendingPathComponent("ssh").path
        let tunnel = Process()
        tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        tunnel.arguments = ["-N", "-T", "-M", "-S", controlPath,
                            "-o", "ControlPersist=no",
                            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                            "-o", "ConnectTimeout=10",
                            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
                            host.destination]
        tunnel.standardInput = FileHandle.nullDevice
        tunnel.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        tunnel.standardError = errors
        process = tunnel
        try tunnel.run()
        for _ in 0..<150 {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            if !tunnel.isRunning {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw WorkbenchError(message.isEmpty ? L("SSH 隧道已退出") : message)
            }
            if FileManager.default.fileExists(atPath: controlPath) {
                // The socket file predates authentication; one round trip proves
                // the master actually works before anything multiplexes over it.
                let probe = try? await ProcessRunner.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
                    "-S", controlPath, host.destination, "true"])
                if probe != nil {
                    online = true
                    stateMessage = "已连接"
                    updatedAt = Date()
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WorkbenchError(L("SSH 转发建立超时"))
    }
}
