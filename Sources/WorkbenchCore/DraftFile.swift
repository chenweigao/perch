import Foundation

public struct SavedDrafts: Codable, Sendable {
    public var text: [String: String] = [:]
    public var attachments: [String: [URL]] = [:]
    public var outbox = OutboundQueue()
    public init(text: [String: String] = [:], attachments: [String: [URL]] = [:], outbox: OutboundQueue = .init()) {
        self.text = text; self.attachments = attachments; self.outbox = outbox
    }
}

/// Ordered atomic writes keep text and queued instructions recoverable after restart.
public final class DraftFile: @unchecked Sendable {
    private let writer = DispatchQueue(label: "perch.drafts")
    public let url: URL
    public init(url: URL) { self.url = url }
    public static func applicationFile(namespace: String) -> DraftFile {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.agentworkbench.mac")
        return DraftFile(url: directory.appendingPathComponent("drafts-\(namespace).json"))
    }
    public func load() throws -> SavedDrafts {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedDrafts() }
        var saved = try JSONDecoder().decode(SavedDrafts.self, from: Data(contentsOf: url))
        saved.outbox.recoverAfterRestart()
        return saved
    }
    private func write(_ value: SavedDrafts) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func save(_ value: SavedDrafts, completion: @escaping @Sendable (String?) -> Void) {
        writer.async { do { try self.write(value); completion(nil) } catch { completion(error.localizedDescription) } }
    }
    public func flush(_ value: SavedDrafts) throws { try writer.sync { try write(value) } }
}
