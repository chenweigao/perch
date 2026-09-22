import Foundation

public struct ConversationSearchHit: Identifiable, Equatable {
    public let entryID: String
    public let occurrence: Int
    public let excerpt: String
    public var id: String { "\(entryID):\(occurrence)" }
}
/// One find bar's rendered text cache. Reuse requires both row identity and source
/// equality; replacing history with same-ID messages must invalidate its text.
public final class ConversationSearch {
    private struct Entry {
        let sources: [String]
        let text: NSString
    }
    private var entries: [String: Entry] = [:]
    public init() {}

    public func hits(in messages: [KimiMessage], query: String, running: Bool) -> [ConversationSearchHit] {
        guard !query.isEmpty else { return [] }
        var next: [String: Entry] = [:]
        defer { entries = next }
        return ConversationTimelineEntry.make(messages, isRunning: running).flatMap { entry -> [ConversationSearchHit] in
            let sources = entry.messages.flatMap(\.content).filter { $0.type == "text" }.compactMap(\.visibleText)
            let cached: Entry
            if let previous = entries[entry.id], previous.sources == sources {
                cached = previous
            } else {
                cached = Entry(sources: sources, text: sources.map { Self.renderedText(ReplyDocument.parse($0)) }.joined(separator: "\n") as NSString)
            }
            next[entry.id] = cached
            let text = cached.text
            var range = NSRange(location: 0, length: text.length), hits: [ConversationSearchHit] = []
            while range.length > 0 {
                let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                guard found.location != NSNotFound else { break }
                let start = max(0, found.location - 50), end = min(text.length, NSMaxRange(found) + 80)
                let excerptRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                hits.append(.init(entryID: entry.id, occurrence: hits.count, excerpt: text.substring(with: excerptRange)))
                range = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            }
            return hits
        }
    }
    private static func renderedText(_ blocks: [ReplyBlock]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let runs), .heading(_, let runs): return runs.map(\.text).joined()
            case .code(_, let source): return source
            case .list(let items): return items.map { renderedText($0.blocks) }.joined(separator: "\n")
            case .quote(let children): return renderedText(children)
            case .table(let headers, let rows, _): return (headers + rows.flatMap { $0 }).map { $0.map(\.text).joined() }.joined(separator: "\n")
            case .rule: return ""
            }
        }.joined(separator: "\n")
    }

}
public struct SessionNavigation {
    public private(set) var entries: [String] = []
    public private(set) var index = -1
    public init() {}
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < entries.count }
    public mutating func visit(_ id: String) {
        guard index < 0 || entries[index] != id else { return }
        entries = Array(entries.prefix(index + 1)); entries.append(id); index = entries.count - 1
    }
    public func canStep(_ delta: Int, isAvailable: (String) -> Bool) -> Bool {
        destinationIndex(delta, isAvailable: isAvailable) != nil
    }
    public mutating func step(_ delta: Int, isAvailable: (String) -> Bool = { _ in true }) -> String? {
        guard let next = destinationIndex(delta, isAvailable: isAvailable) else { return nil }
        index = next; return entries[next]
    }
    private func destinationIndex(_ delta: Int, isAvailable: (String) -> Bool) -> Int? {
        guard delta != 0 else { return nil }
        var next = index + delta
        while entries.indices.contains(next) {
            if isAvailable(entries[next]) { return next }
            next += delta
        }
        return nil
    }
}
