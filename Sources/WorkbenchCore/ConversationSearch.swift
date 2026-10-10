import Foundation

public struct ConversationSearchHit: Identifiable, Equatable {
    public let entryID: String
    public let occurrence: Int
    public let excerpt: String
    public var id: String { "\(entryID):\(occurrence)" }
}

/// Find-bar switches: letter case, regular expressions and whose text to search.
public struct ConversationFindOptions: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable, CaseIterable {
        case all, user, assistant, tool
    }
    public var caseSensitive = false
    public var regex = false
    public var role: Role = .all
    public init(caseSensitive: Bool = false, regex: Bool = false, role: Role = .all) {
        self.caseSensitive = caseSensitive; self.regex = regex; self.role = role
    }
    /// The document can place the caret on an occurrence only for literal text.
    public var canLocateOccurrence: Bool { !regex }
    public func compareOptions() -> NSString.CompareOptions {
        caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
    }
}

public struct ConversationFindResult: Equatable {
    public let hits: [ConversationSearchHit]
    /// Invalid regular expression input; the last valid matches stay on screen.
    public let queryError: String?
    public static let empty = ConversationFindResult(hits: [], queryError: nil)
}

/// One find bar's rendered text cache. Reuse requires both row identity and source
/// equality; replacing history with same-ID messages must invalidate its text.
public final class ConversationSearch {
    private struct Entry {
        let sources: [String]
        let text: NSString
        let role: ConversationFindOptions.Role
    }
    private var entries: [String: Entry] = [:]
    public init() {}

    public func hits(in messages: [KimiMessage], query: String, running: Bool,
                     options: ConversationFindOptions = ConversationFindOptions()) -> ConversationFindResult {
        guard !query.isEmpty else { return .empty }
        var next: [String: Entry] = [:]
        defer { entries = next }
        var regex: NSRegularExpression?
        if options.regex {
            do {
                regex = try NSRegularExpression(pattern: query, options: options.caseSensitive ? [] : [.caseInsensitive])
            } catch {
                return ConversationFindResult(hits: [], queryError: L("无效正则表达式"))
            }
        }
        let entries_ = ConversationTimelineEntry.make(messages, isRunning: running)
        var hits: [ConversationSearchHit] = []
        for entry in entries_ {
            let classified = Self.classify(entry)
            guard options.role == .all || classified.role == options.role else { continue }
            let cached: Entry
            if let previous = entries[entry.id], previous.sources == classified.sources {
                cached = previous
            } else {
                cached = Entry(sources: classified.sources,
                               text: classified.sources.map { Self.renderedText(ReplyDocument.parse($0)) }.joined(separator: "\n") as NSString,
                               role: classified.role)
            }
            next[entry.id] = cached
            let text = cached.text
            var matches: [NSRange] = []
            if let regex {
                matches = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map(\.range)
            } else {
                var range = NSRange(location: 0, length: text.length)
                while range.length > 0 {
                    let found = text.range(of: query, options: options.compareOptions(), range: range)
                    guard found.location != NSNotFound else { break }
                    matches.append(found)
                    range = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
                }
            }
            for (index, found) in matches.enumerated() {
                let start = max(0, found.location - 50), end = min(text.length, NSMaxRange(found) + 80)
                let excerptRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                hits.append(.init(entryID: entry.id, occurrence: index, excerpt: text.substring(with: excerptRange)))
            }
        }
        return ConversationFindResult(hits: hits, queryError: nil)
    }

    /// User prompts, tool activity and assistant text search separately. Tool
    /// parts count only on activity rows — an empty-output row holds the same
    /// message and must not double the hits.
    private static func classify(_ entry: ConversationTimelineEntry) -> (role: ConversationFindOptions.Role, sources: [String]) {
        let textSources = entry.messages.flatMap(\.content).filter { $0.type == "text" }.compactMap(\.visibleText)
        if entry.messages.contains(where: { $0.isUserPrompt }) { return (.user, textSources) }
        let parts = entry.messages.flatMap(\.content)
        let hasToolActivity = (entry.presentation == .activity || entry.presentation == .progress)
            && parts.contains { $0.type == "tool_use" || $0.type == "tool_result" }
        if hasToolActivity {
            var sources = textSources
            sources += parts.filter { $0.type == "tool_use" || $0.type == "tool_result" }
                .flatMap { [$0.toolName, $0.name, $0.text, $0.input?.display, $0.output?.display] }
                .compactMap { $0?.isEmpty == false ? $0 : nil }
            return (.tool, sources)
        }
        return (.assistant, textSources)
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
