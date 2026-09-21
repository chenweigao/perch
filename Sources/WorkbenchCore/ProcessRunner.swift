import Foundation

public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            async let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let errorData = await stderr
            guard process.terminationStatus == 0 else {
                throw WorkbenchError(String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return stdout
        }.value
    }
}
