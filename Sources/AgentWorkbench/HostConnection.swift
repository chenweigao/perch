import Foundation
import WorkbenchCore

@MainActor
final class HostConnection: ObservableObject, Identifiable {
    nonisolated let host: SSHHost
    nonisolated var id: UUID { host.id }
    @Published private(set) var snapshot: Snapshot?
    @Published private var stateMessage: String.LocalizationValue = "未连接"
    var state: String { L(stateMessage) }
    func state(locale: Locale) -> String { L(stateMessage, locale: locale) }
    @Published private(set) var error: String?
    @Published private(set) var online = false
    @Published private(set) var wantsConnection = false
    @Published private(set) var updatedAt: Date?
    private(set) var binary = "herdr"
    private(set) var controlPath = ""
    private var socketPath = ""
    private var directory: URL?
    private var process: Process?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var onSnapshot: (() -> Void)?

    init(host: SSHHost) { self.host = host }

    func connect() {
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
                    while !Task.isCancelled && self.generation == token {
                        try await self.refresh(token: token)
                        // Metadata only, through an existing SSH tunnel. Terminal bytes
                        // stream separately and never pass through SwiftUI state.
                        try await Task.sleep(for: .seconds(3))
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
        let data = try await ProcessRunner.run("/usr/bin/ssh", [
            "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=1",
            host.destination, "herdr status --json"
        ])
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let status = try JSONDecoder().decode(RemoteStatus.self, from: data)
        guard status.server.running, let remoteSocket = status.server.socket else {
            throw WorkbenchError("远端 Herdr 未运行，请先在远端终端启动 Herdr。")
        }
        binary = status.client.binary
        let folder = URL(fileURLWithPath: "/tmp/awb-\(UUID().uuidString.prefix(12))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        directory = folder
        socketPath = folder.appendingPathComponent("rpc").path
        controlPath = folder.appendingPathComponent("ssh").path
        let tunnel = Process()
        tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        tunnel.arguments = ["-N", "-T", "-M", "-S", controlPath,
                            "-o", "ControlPersist=no",
                            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                            "-o", "ConnectTimeout=10", "-o", "ExitOnForwardFailure=yes",
                            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
                            "-L", "\(socketPath):\(remoteSocket)", host.destination]
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
                throw WorkbenchError(message.isEmpty ? "SSH 隧道已退出" : message)
            }
            if FileManager.default.fileExists(atPath: socketPath) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WorkbenchError("SSH 转发建立超时")
    }

    func refresh() async {
        do { try await refresh(token: generation) }
        catch { self.error = error.localizedDescription }
    }

    private func refresh(token: UUID) async throws {
        let path = socketPath
        let result = try await Task.detached {
            let data = try JSONSocket.request(path: path, method: "session.snapshot")
            return try Wire.decode(SnapshotResult.self, from: data).snapshot
        }.value
        guard generation == token else { throw CancellationError() }
        snapshot = result
        online = true
        stateMessage = "已连接"
        error = nil
        updatedAt = Date()
        onSnapshot?()
    }

    func closeTerminal(_ terminalID: String) async throws {
        guard online else { throw WorkbenchError("请先连接远端") }
        let token = generation
        try await refresh(token: token)
        guard let pane = snapshot?.panes.first(where: { $0.terminalID == terminalID }) else { throw WorkbenchError("此终端已不在远端列表中") }
        let command = "exec \(SSHCommand.quote(binary)) pane close \(SSHCommand.quote(pane.paneID))"
        let data = try await ProcessRunner.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-S", controlPath, host.destination, command])
        _ = try Wire.decode(JSONValue.self, from: data)
        try await refresh(token: token)
    }

    func createTerminal(workspaceID: String, cwd: String, label: String) async throws -> Pane {
        guard online else { throw WorkbenchError("请先连接远端") }
        let token = generation
        let path = socketPath
        let created = try await Task.detached {
            let data = try JSONSocket.request(path: path, method: "tab.create", params: [
                "workspace_id": workspaceID, "cwd": cwd, "label": label, "focus": false
            ])
            return try Wire.decode(CreatedTerminalResult.self, from: data)
        }.value
        try await refresh(token: token)
        var pane = created.rootPane
        pane.tabLabel = created.tab.label
        return pane
    }
}

private struct CreatedTerminalResult: Decodable {
    let rootPane: Pane
    let tab: Tab
    enum CodingKeys: String, CodingKey { case rootPane = "root_pane", tab }
}
