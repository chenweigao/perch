import Foundation
import Markdown

/// A semantic document shared by all native conversation providers.
public enum ReplyBlock: Equatable, Sendable {
    case paragraph([ReplyInline])
    case heading(Int, [ReplyInline])
    case code(language: String, source: String)
    /// Display math ($$…$$ / \[…\]); the formula is one atomic block.
    case math(String)
    indirect case list([ReplyListItem])
    indirect case quote([ReplyBlock])
    case table(headers: [[ReplyInline]], rows: [[[ReplyInline]]], alignments: [ReplyAlignment])
    /// GitHub-style alert quote (> [!NOTE] …): kind drives the tinted chrome.
    case alert(kind: ReplyAlertKind, [ReplyBlock])
    case rule
}

public enum ReplyAlertKind: String, Equatable, CaseIterable, Sendable {
    case note, tip, important, warning, caution
}

/// `> [!NOTE]`-style alert detection (ccgui remark-github-alerts parity).
public enum ReplyAlert {
    /// The first line of a quote starts with [!TYPE]; the marker is consumed.
    public static func rewrite(_ blocks: [ReplyBlock]) -> (ReplyAlertKind, [ReplyBlock])? {
        guard case .paragraph(let runs) = blocks.first,
              let first = runs.first, first.text.hasPrefix("[!"),
              let close = first.text.firstIndex(of: "]") else { return nil }
        let marker = first.text.dropFirst(2).prefix(upTo: close).lowercased()
        guard let kind = ReplyAlertKind(rawValue: String(marker)) else { return nil }
        var rest = runs
        var head = first
        head.text = String(first.text[first.text.index(after: close)...])
            .trimmingCharacters(in: .init(charactersIn: " \n"))
        if head.text.isEmpty { rest.removeFirst() } else { rest[0] = head }
        // The soft break after the marker line is layout, not content.
        if rest.first?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            rest.removeFirst()
        }
        var inner = blocks
        if rest.isEmpty { inner.removeFirst() } else { inner[0] = .paragraph(rest) }
        return (kind, inner)
    }
}

public struct ReplyListItem: Equatable, Sendable {
    public let marker: String
    public let blocks: [ReplyBlock]
}

public enum ReplyAlignment: Equatable, Sendable { case leading, center, trailing }

public struct ReplyInline: Equatable, Hashable, Sendable {
    public var text: String
    public var strong = false
    public var emphasis = false
    public var code = false
    public var strikethrough = false
    public var link: URL?
    /// Inline TeX ($…$ / \(…\)); the text carries the object replacement char.
    public var math: String? = nil
}

public enum ReplyDocument {
    public static func parse(_ source: String, documentLinks: Bool = false) -> [ReplyBlock] {
        blocks(Document(parsing: source), documentLinks: documentLinks)
    }

    private static func blocks(_ parent: Markup, documentLinks: Bool) -> [ReplyBlock] {
        parent.children.flatMap { blocks(from: $0, documentLinks: documentLinks) }
    }

    public static func blocks(from node: Markup, documentLinks: Bool = false) -> [ReplyBlock] {
            switch node {
            case let value as Paragraph:
                let runs = linkBareURLs(inlines(value, documentLinks: documentLinks))
                if let latex = ReplyMath.displayContent(runs.map(\.text).joined()) { return [.math(latex)] }
                return [.paragraph(ReplyMath.splitInline(runs))]
            case let value as Heading: return [.heading(value.level, linkBareURLs(inlines(value, documentLinks: documentLinks)))]
            case let value as CodeBlock:
                // Remove the parser's terminal newline, preserving code indentation and blank lines.
                let code = value.code.hasSuffix("\n") ? String(value.code.dropLast()) : value.code
                return [.code(language: value.language ?? "", source: code)]
            case let value as OrderedList:
                return [.list(value.listItems.enumerated().map { index, item in
                    ReplyListItem(marker: "\(Int(value.startIndex) + index).", blocks: blocks(item, documentLinks: documentLinks))
                })]
            case let value as UnorderedList:
                return [.list(value.listItems.map { item in
                    ReplyListItem(marker: item.checkbox.map { $0 == .checked ? "☑" : "☐" } ?? "•", blocks: blocks(item, documentLinks: documentLinks))
                })]
            case let value as BlockQuote:
                let inner = blocks(value, documentLinks: documentLinks)
                if let (kind, content) = ReplyAlert.rewrite(inner) { return [.alert(kind: kind, content)] }
                return [.quote(inner)]
            case let value as Markdown.Table:
                let alignments: [ReplyAlignment] = value.columnAlignments.map {
                    switch $0 { case .center: return .center; case .right: return .trailing; default: return .leading }
                }
                return [.table(headers: value.head.cells.map { ReplyMath.splitInline(linkBareURLs(inlines($0, documentLinks: documentLinks))) }, rows: value.body.rows.map { $0.cells.map { ReplyMath.splitInline(linkBareURLs(inlines($0, documentLinks: documentLinks))) } }, alignments: alignments)]
            case is ThematicBreak: return [.rule]
            case let value as HTMLBlock: return [.paragraph([ReplyInline(text: value.rawHTML)])]
            default: return blocks(node, documentLinks: documentLinks)
            }
    }

    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func linkBareURLs(_ runs: [ReplyInline]) -> [ReplyInline] {
        runs.flatMap { run -> [ReplyInline] in
            guard run.link == nil, !run.code else { return [run] }
            let text = run.text as NSString
            let matches = linkDetector.matches(in: run.text, range: NSRange(location: 0, length: text.length))
                .filter { ["http", "https"].contains($0.url?.scheme?.lowercased() ?? "") }
            guard !matches.isEmpty else { return [run] }
            var result: [ReplyInline] = []
            var offset = 0
            for match in matches {
                if match.range.location > offset {
                    var prefix = run
                    prefix.text = text.substring(with: NSRange(location: offset, length: match.range.location - offset))
                    result.append(prefix)
                }
                var link = run
                link.text = text.substring(with: match.range)
                link.link = match.url
                result.append(link)
                offset = NSMaxRange(match.range)
            }
            if offset < text.length {
                var suffix = run
                suffix.text = text.substring(from: offset)
                result.append(suffix)
            }
            return result
        }
    }

    private static func inlines(_ parent: Markup, documentLinks: Bool) -> [ReplyInline] {
        parent.children.flatMap { node -> [ReplyInline] in
            switch node {
            case let value as Markdown.Text: return [ReplyInline(text: value.string)]
            case is SoftBreak: return [ReplyInline(text: " ")]
            case is LineBreak: return [ReplyInline(text: "\n")]
            case let value as InlineCode: return [ReplyInline(text: value.code, code: true)]
            case let value as Strong: return inlines(value, documentLinks: documentLinks).map { var run = $0; run.strong = true; return run }
            case let value as Emphasis: return inlines(value, documentLinks: documentLinks).map { var run = $0; run.emphasis = true; return run }
            case let value as Strikethrough: return inlines(value, documentLinks: documentLinks).map { var run = $0; run.strikethrough = true; return run }
            case let value as Link:
                let url = value.destination.flatMap(URL.init(string:))
                let allowed = ["https", "http", "mailto"].contains(url?.scheme?.lowercased() ?? "")
                let file = value.destination.flatMap { ConversationFileReference(text: $0.removingPercentEncoding ?? $0) }
                return inlines(value, documentLinks: documentLinks).map { var run = $0; run.link = documentLinks ? value.destination.flatMap(DocumentLink.url) : (allowed ? url : file?.url); return run }
            case let value as Markdown.Image: return inlines(value, documentLinks: documentLinks) // Render alt text without fetching remote media.
            case let value as InlineHTML: return [ReplyInline(text: value.rawHTML)]
            default: return inlines(node, documentLinks: documentLinks)
            }
        }
    }
}
