import Foundation

public struct SavedDrafts: Codable, Sendable {
    public var text: [String: String] = [:]
    public var attachments: [String: [URL]] = [:]
    public var outbox = OutboundQueue()
    /// Sent prompts per session, oldest first, for composer history recall.
    public var history: [String: [String]] = [:]
    public init(text: [String: String] = [:], attachments: [String: [URL]] = [:], outbox: OutboundQueue = .init(),
                history: [String: [String]] = [:]) {
        self.text = text; self.attachments = attachments; self.outbox = outbox; self.history = history
    }
    /// Files written before a field existed must keep decoding.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent([String: String].self, forKey: .text) ?? [:]
        attachments = try values.decodeIfPresent([String: [URL]].self, forKey: .attachments) ?? [:]
        outbox = try values.decodeIfPresent(OutboundQueue.self, forKey: .outbox) ?? OutboundQueue()
        history = try values.decodeIfPresent([String: [String]].self, forKey: .history) ?? [:]
    }

    /// Repeating the latest prompt must not grow the list; recall stays meaningful.
    public mutating func recordHistory(_ text: String, for session: String, limit: Int = 50) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = (history[session] ?? []).filter { $0 != text }
        entries.append(text)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        history[session] = entries
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
