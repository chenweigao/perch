import Foundation
import WorkbenchCore

/// Owns one ssh process so a pending read can actually be stopped.
final class RemoteReader: @unchecked Sendable {
    private let local: Bool
    init(local: Bool = false) { self.local = local }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func terminate() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    func run(command: String, destination: String) async -> Result<Data, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.execute(command: command, destination: destination))
            }
        }
    }

    private func execute(command: String, destination: String) -> Result<Data, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: local ? "/bin/sh" : "/usr/bin/ssh")
        process.arguments = local ? ["-c", command] : RemoteGitCommand.sshArguments(destination: destination, command: command)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        lock.lock()
        if cancelled { lock.unlock(); return .failure(WorkbenchError(L("已取消读取。"))) }
        self.process = process
        lock.unlock()
        do { try process.run() } catch { return .failure(error) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        self.process = nil
        lock.unlock()
        if wasCancelled { return .failure(WorkbenchError(L("已取消读取。"))) }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: failure, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(WorkbenchError(message.isEmpty ? L("远端连接失败或已断开。") : message))
        }
        return .success(data)
    }
}
