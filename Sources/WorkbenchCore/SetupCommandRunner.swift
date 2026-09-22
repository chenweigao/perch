import Foundation

/// Bounded, cancellable commands used by the setup sheet. Cancellation ends only
/// the local check/SSH client, never an already running remote agent.
public enum SetupCommandRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> Data {
        let execution = Execution()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try execution.run(executable, arguments, timeout: timeout)
            }.value
        } onCancel: { execution.stop(cancelled: true) }
    }

    private final class Execution: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private var cancelled = false
        private var timedOut = false
        private var finished = false

        func stop(cancelled: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            if cancelled { self.cancelled = true } else { timedOut = true }
            if process.isRunning { process.terminate() }
        }
        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
            let output = Pipe(), errors = Pipe()
            lock.lock()
            if cancelled { lock.unlock(); throw CancellationError() }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = errors
            do { try process.run() } catch { finished = true; lock.unlock(); throw error }
            lock.unlock()
            let expiry = DispatchWorkItem { self.stop(cancelled: false) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
            let stderr = ErrorReader(errors.fileHandleForReading)
            let group = DispatchGroup()
            group.enter(); DispatchQueue.global().async { stderr.read(); group.leave() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); group.wait(); expiry.cancel()
            lock.lock(); finished = true
            let didCancel = cancelled, didTimeOut = timedOut
            lock.unlock()
            if didCancel { throw CancellationError() }
            if didTimeOut { throw WorkbenchError(L("检查超时。请在终端确认远端命令可以运行，再重试。")) }
            guard process.terminationStatus == 0 else {
                let message = String(decoding: stderr.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw WorkbenchError(message.isEmpty ? L("远端命令执行失败。请在终端检查后重试。") : message)
            }
            return data
        }
    }
    private final class ErrorReader: @unchecked Sendable {
        let handle: FileHandle
        var data = Data()
        init(_ handle: FileHandle) { self.handle = handle }
        func read() { data = handle.readDataToEndOfFile() }
    }
}
