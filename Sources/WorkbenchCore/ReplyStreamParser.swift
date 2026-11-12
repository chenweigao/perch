import Foundation
import Markdown

/// Incremental Markdown parse for an append-only streaming reply. Completed
/// top-level blocks are kept; only the final block and the appended text are
/// reparsed, so a long stream costs O(delta) instead of O(document) per update.
/// Link reference definitions and TeX \( \[ delimiters resolve document-wide;
/// sources containing them take full parses.
public struct ReplyStreamParser {
    private let documentLinks: Bool
    private var source: String
    private var blocks: [ReplyBlock]
    private var tail: String.Index
    private var tailBlockCount: Int
    private var documentWideSyntax: Bool
    /// Prefix blocks unchanged by the latest append. A replacement invalidates
    /// the whole prefix; an unchanged update keeps every block stable.
    public private(set) var stableBlockCount: Int

    public init(documentLinks: Bool = false) {
        self.documentLinks = documentLinks
        source = ""
        blocks = []
        tail = source.startIndex
        tailBlockCount = 0
        documentWideSyntax = false
        stableBlockCount = 0
    }

    public mutating func update(_ next: String) -> [ReplyBlock] {
        if next.utf8.count == source.utf8.count && next == source {
            stableBlockCount = blocks.count
            return blocks
        }
        // Indices of `source` stay valid in `next` once the prefix is verified.
        guard !documentWideSyntax, next.utf8.count > source.utf8.count, next.hasPrefix(source) else {
            return fullParse(next)
        }
        let suffix = next[tail...]
        guard !Self.documentWideSyntax(in: suffix) else { return fullParse(next) }
        let parsed = Self.parse(String(suffix), documentLinks: documentLinks)
        let preserved = max(0, blocks.count - tailBlockCount)
        blocks.removeLast(tailBlockCount)
        blocks.append(contentsOf: parsed.blocks)
        tailBlockCount = parsed.tailBlockCount
        if let line = parsed.tailLine { tail = Self.index(ofLine: line, in: next, from: tail) }
        stableBlockCount = preserved
        source = next
        return blocks
    }

    private mutating func fullParse(_ next: String) -> [ReplyBlock] {
        let parsed = Self.parse(next, documentLinks: documentLinks)
        blocks = parsed.blocks
        tailBlockCount = parsed.tailBlockCount
        tail = parsed.tailLine.map { Self.index(ofLine: $0, in: next, from: next.startIndex) } ?? next.startIndex
        documentWideSyntax = Self.documentWideSyntax(in: next[...])
        stableBlockCount = 0
        source = next
        return blocks
    }

    private static func parse(_ source: String, documentLinks: Bool) -> (blocks: [ReplyBlock], tailBlockCount: Int, tailLine: Int?) {
        let document = Document(parsing: ReplyMath.normalizeDelimiters(source))
        var blocks: [ReplyBlock] = []
        var tailBlockCount = 0
        var tailLine: Int?
        var previous: (node: Markup, blockCount: Int)?
        for child in document.children {
            let childBlocks = ReplyDocument.blocks(from: child, documentLinks: documentLinks)
            blocks.append(contentsOf: childBlocks)
            // A GFM table decides row membership from cell content, so a trailing
            // paragraph line can join the table as it grows ("| " becomes "| 1").
            // Reparse the table too when the last block sits on its very next line.
            if let previous, previous.node is Markdown.Table,
               let priorRange = previous.node.range, let range = child.range,
               range.lowerBound.line == priorRange.upperBound.line + 1 {
                tailBlockCount = previous.blockCount + childBlocks.count
                tailLine = priorRange.lowerBound.line
            } else {
                tailBlockCount = childBlocks.count
                tailLine = child.range?.lowerBound.line
            }
            previous = (child, childBlocks.count)
        }
        return (blocks, tailBlockCount, tailLine)
    }

    /// A reference definition rewrites link resolution everywhere, and TeX
    /// \( \[ normalization pairs delimiters across the whole source. Over-detect:
    /// a false positive only costs a full parse.
    private static func documentWideSyntax(in text: Substring) -> Bool {
        if text.contains(#"\("#) || text.contains(#"\["#) { return true }
        return text.range(of: #"(?m)^ {0,3}\[[^\n]*\]:"#, options: .regularExpression) != nil
    }

    private static func index(ofLine line: Int, in text: String, from start: String.Index) -> String.Index {
        var index = start
        var remaining = line - 1
        while remaining > 0, index < text.endIndex {
            if ["\n", "\r", "\r\n"].contains(text[index]) { remaining -= 1 }
            index = text.index(after: index)
        }
        return index
    }
}
