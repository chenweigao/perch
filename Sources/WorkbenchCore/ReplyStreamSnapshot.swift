import Foundation

/// A parsed stream snapshot. Display frames reveal these immutable blocks;
/// Markdown parsing happens only when the authoritative source changes.
/// Release follows rendered text and preserves the current Markdown styles.
public struct ReplyStreamSnapshot: Sendable {
    public let blocks: [ReplyBlock]
    public let text: String
    public let utf16Length: Int
    private let lengths: [Int]

    public init(blocks: [ReplyBlock]) {
        self.blocks = blocks
        let texts = blocks.map(Self.displayText)
        lengths = texts.map { $0.utf16.count }
        text = texts.joined(separator: "\n\n")
        utf16Length = lengths.reduce(0, +) + max(0, blocks.count - 1) * 2
    }

    public func prefix(utf16Length: Int) -> [ReplyBlock] {
        guard utf16Length < self.utf16Length else { return blocks }
        return Self.prefix(blocks, lengths: lengths, budget: max(0, utf16Length))
    }

    private static func displayText(_ runs: [ReplyInline]) -> String {
        runs.map(\.text).joined()
    }
    private static func displayText(_ blocks: [ReplyBlock]) -> String {
        blocks.map(displayText).joined(separator: "\n\n")
    }
    private static func displayText(_ block: ReplyBlock) -> String {
        switch block {
        case .paragraph(let runs), .heading(_, let runs): return displayText(runs)
        case .code(_, let source): return source
        case .quote(let inner), .alert(_, let inner): return displayText(inner)
        case .list(let items): return items.map { displayText($0.blocks) }.joined(separator: "\n")
        case .table(let headers, let rows, _):
            return ([headers] + rows).map { $0.map(displayText).joined(separator: "\t") }.joined(separator: "\n")
        case .math, .rule: return "\u{FFFC}" // Atomic visual blocks.
        }
    }

    private static func prefix(_ blocks: [ReplyBlock], lengths: [Int]? = nil, budget: Int) -> [ReplyBlock] {
        var remaining = budget
        var result: [ReplyBlock] = []
        for (index, block) in blocks.enumerated() {
            guard remaining > 0 else { break }
            let length = lengths?[index] ?? displayText(block).utf16.count
            if remaining >= length { result.append(block) }
            else { result.append(prefix(block, budget: remaining)); break }
            remaining -= length + 2
        }
        return result
    }
    private static func prefix(_ runs: [ReplyInline], budget: Int) -> [ReplyInline] {
        var remaining = budget
        var result: [ReplyInline] = []
        for var run in runs {
            guard remaining > 0 else { break }
            let length = run.text.utf16.count
            if remaining < length {
                run.text = prefix(run.text, budget: remaining)
                result.append(run); break
            }
            result.append(run); remaining -= length
        }
        return result
    }
    private static func prefix(_ text: String, budget: Int) -> String {
        let source = text as NSString
        let end = min(source.length, max(0, budget))
        guard end > 0, end < source.length else { return end == 0 ? "" : text }
        // The release clock already protects graphemes. Keep this public
        // projection safe for callers that supply an arbitrary UTF-16 count.
        let character = source.rangeOfComposedCharacterSequence(at: end - 1)
        return source.substring(to: NSMaxRange(character))
    }
    private static func prefix(_ block: ReplyBlock, budget: Int) -> ReplyBlock {
        switch block {
        case .paragraph(let runs): return .paragraph(prefix(runs, budget: budget))
        case .heading(let level, let runs): return .heading(level, prefix(runs, budget: budget))
        case .code(let language, let source): return .code(language: language, source: prefix(source, budget: budget))
        case .quote(let inner): return .quote(prefix(inner, budget: budget))
        case .alert(let kind, let inner): return .alert(kind: kind, prefix(inner, budget: budget))
        case .list(let items):
            var remaining = budget
            var visible: [ReplyListItem] = []
            for item in items {
                guard remaining > 0 else { break }
                let length = displayText(item.blocks).utf16.count
                visible.append(ReplyListItem(marker: item.marker,
                    blocks: remaining >= length ? item.blocks : prefix(item.blocks, budget: remaining)))
                if remaining < length { break }
                remaining -= length + 1
            }
            return .list(visible)
        case .table(let headers, let rows, let alignments):
            var remaining = budget
            var visible: [[[ReplyInline]]] = []
            for row in [headers] + rows {
                guard remaining > 0 else { break }
                visible.append(row.map { cell in
                    let length = displayText(cell).utf16.count
                    let value = prefix(cell, budget: max(0, remaining))
                    remaining -= length + 1
                    return value
                })
            }
            return .table(headers: visible.first ?? headers.map { _ in [] }, rows: Array(visible.dropFirst()), alignments: alignments)
        case .math, .rule: return block
        }
    }
}
