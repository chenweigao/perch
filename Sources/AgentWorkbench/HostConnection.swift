import Foundation
import Observation
import WorkbenchCore

/// A host's SSH control channel, on demand. Features like the command-line
/// island multiplex over this master instead of paying a handshake per shell.
/// It carries no remote daemon state: `online` means the master is usable.
@MainActor @Observable
final class HostConnection: Identifiable {
    private(set) var host: SSHHost
    nonisolated let id: UUID
    private var stateMessage: String.LocalizationValue = "未连接"
    var state: String { L(stateMessage) }
    func state(locale: Locale) -> String { L(stateMessage, locale: locale) }
    private(set) var error: String?
    private(set) var online = false
    private(set) var wantsConnection = false
    private(set) var updatedAt: Date?
    private(set) var controlPath = ""
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var exitSignal: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var processExited = false

    init(host: SSHHost) { self.host = host; self.id = host.id }
    func updateHost(_ host: SSHHost) { self.host = host }

    /// Starts the master only when nothing already wants it; calling `connect()`
    /// on a live master would tear down every multiplexed client.
    func connectIfNeeded() {
        guard !host.isLocal, !wantsConnection else { return }
        connect()
    }

    /// Opens a local forward multiplexed over this host's master, so conversation
    /// tunnels reuse one handshake instead of dialing their own. The caller owns
    /// the returned process and must terminate it. Returns nil when the master is
    /// not usable, letting the caller fall back to a private master.
    func multiplexedForward(localPort: UInt16, remotePort: Int) -> Process? {
        guard online, !controlPath.isEmpty, !host.isLocal else { return nil }
        let slave = Process()
        slave.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        slave.arguments = ["-N", "-T", "-S", controlPath, "-o", "ControlMaster=no",
                           "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                           "-o", "ExitOnForwardFailure=yes",
                           "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
                           "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)", host.destination]
        slave.standardInput = FileHandle.nullDevice
        slave.standardOutput = FileHandle.nullDevice
        slave.standardError = Pipe()
        do { try slave.run() } catch { return nil }
        return slave
    }

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
                    // The master exiting is the liveness signal; its termination
                    // handler wakes this wait, so there is no polling interval.
                    await self.waitForExit(token: token)
                    guard !Task.isCancelled, self.generation == token else { break }
                    throw WorkbenchError(L("SSH 隧道已退出"))
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
        exitSignal?.resume(); exitSignal = nil
        stopTunnel()
        online = false
        wantsConnection = false
        stateMessage = "未连接"
        error = nil
    }

    /// Suspends until the master process exits. The check and the continuation
    /// install run together on the main actor, so a termination that lands between
    /// them is caught by `processExited` rather than lost.
    private func waitForExit(token: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if processExited || generation != token || process?.isRunning != true {
                continuation.resume(); return
            }
            exitSignal = continuation
        }
    }
    private func signalExit() {
        processExited = true
        exitSignal?.resume(); exitSignal = nil
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
        processExited = false
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
        tunnel.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.signalExit() }
        }
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
