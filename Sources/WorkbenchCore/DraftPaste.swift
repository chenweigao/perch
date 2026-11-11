import Foundation

/// A long paste stays out of the visible draft as a `@paste("id")` token; the
/// full text is stored locally and expanded back in when the prompt is sent.
/// Like project file references, tokens are plain draft text, so drafts,
/// history and the queue carry them without another channel.
public struct DraftPaste: Equatable {
    public let id: String
    public let range: NSRange
    private static let tokenPattern = try! NSRegularExpression(pattern: #"@paste\("([0-9a-f]{8})"\)"#)

    public static func token(id: String) -> String { "@paste(\"\(id)\")" }

    public static func references(in draft: String) -> [DraftPaste] {
        let source = draft as NSString
        return tokenPattern.matches(in: draft, range: NSRange(location: 0, length: source.length))
            .map { DraftPaste(id: source.substring(with: $0.range(at: 1)), range: $0.range) }
    }

    /// Short text pastes inline as before; a wall of log or diff folds.
    public static func shouldFold(_ text: String) -> Bool {
        text.utf8.count >= 1000 || text.components(separatedBy: .newlines).count > 10
    }
}

public struct DraftPasteExpansion: Equatable, Sendable {
    public let text: String
    public let missing: [String]
}

public final class DraftPasteStore: @unchecked Sendable {
    public struct Stats: Equatable, Sendable { public let lines: Int; public let bytes: Int }
    private let directory: URL
    private var cached: [String: Stats] = [:]
    public init(directory: URL) { self.directory = directory }
    public static func applicationStore(namespace: String) -> DraftPasteStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.agentworkbench.mac")
        return DraftPasteStore(directory: root.appendingPathComponent("pastes-\(namespace)", isDirectory: true))
    }

    public func save(_ text: String) throws -> String {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: file(id), atomically: true, encoding: .utf8)
        cached[id] = Stats(lines: text.components(separatedBy: .newlines).count, bytes: text.utf8.count)
        return id
    }

    public func text(for id: String) -> String? {
        try? String(contentsOf: file(id), encoding: .utf8)
    }

    public func stats(for id: String) -> Stats? {
        if let cached = cached[id] { return cached }
        guard let text = text(for: id) else { return nil }
        let stats = Stats(lines: text.components(separatedBy: .newlines).count, bytes: text.utf8.count)
        cached[id] = stats
        return stats
    }

    public func expand(_ draft: String) -> DraftPasteExpansion {
        var result = draft as NSString
        var missing: [String] = []
        // Replace from the end so earlier ranges stay valid.
        for paste in DraftPaste.references(in: draft).reversed() {
            guard let text = text(for: paste.id) else { missing.append(paste.id); continue }
            result = result.replacingCharacters(in: paste.range, with: text) as NSString
        }
        return DraftPasteExpansion(text: result as String, missing: missing.reversed())
    }

    private func file(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).txt")
    }
}
