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
    private var pending: (SavedDrafts, @Sendable (String?) -> Void)?
    private var scheduledSave: DispatchWorkItem?
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
    /// Text edits share a bounded 250 ms window. Queue and attachment changes bypass
    /// it; only the newest pending text save reports completion.
    public func save(_ value: SavedDrafts, coalescing: Bool = false, completion: @escaping @Sendable (String?) -> Void) {
        writer.async {
            self.pending = (value, completion)
            if coalescing {
                guard self.scheduledSave == nil else { return }
                let work = DispatchWorkItem { self.writePending() }
                self.scheduledSave = work
                self.writer.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
            } else {
                self.scheduledSave?.cancel()
                self.writePending()
            }
        }
    }
    private func writePending() {
        scheduledSave = nil
        guard let (value, completion) = pending else { return }
        pending = nil
        do { try write(value); completion(nil) } catch { completion(error.localizedDescription) }
    }
    public func flush(_ value: SavedDrafts) throws {
        try writer.sync {
            scheduledSave?.cancel(); scheduledSave = nil; pending = nil
            try write(value)
        }
    }
}
