import Foundation
import Markdown

/// A semantic document shared by all native conversation providers.
public enum ReplyBlock: Equatable {
    case paragraph([ReplyInline])
    case heading(Int, [ReplyInline])
    case code(language: String, source: String)
    indirect case list([ReplyListItem])
    indirect case quote([ReplyBlock])
    case table(headers: [[ReplyInline]], rows: [[[ReplyInline]]], alignments: [ReplyAlignment])
    case rule
}

public struct ReplyListItem: Equatable {
    public let marker: String
    public let blocks: [ReplyBlock]
}

public enum ReplyAlignment: Equatable { case leading, center, trailing }

public struct ReplyInline: Equatable {
    public let text: String
    public var strong = false
    public var emphasis = false
    public var code = false
    public var strikethrough = false
    public var link: URL?
}

public enum ReplyDocument {
    public static func parse(_ source: String) -> [ReplyBlock] {
        blocks(Document(parsing: source))
    }

    private static func blocks(_ parent: Markup) -> [ReplyBlock] {
        parent.children.flatMap { node -> [ReplyBlock] in
            switch node {
            case let value as Paragraph: return [.paragraph(inlines(value))]
            case let value as Heading: return [.heading(value.level, inlines(value))]
            case let value as CodeBlock:
                // Remove the parser's terminal newline, preserving code indentation and blank lines.
                let code = value.code.hasSuffix("\n") ? String(value.code.dropLast()) : value.code
                return [.code(language: value.language ?? "", source: code)]
            case let value as OrderedList:
                return [.list(value.listItems.enumerated().map { index, item in
                    ReplyListItem(marker: "\(Int(value.startIndex) + index).", blocks: blocks(item))
                })]
            case let value as UnorderedList:
                return [.list(value.listItems.map { item in
                    ReplyListItem(marker: item.checkbox.map { $0 == .checked ? "☑" : "☐" } ?? "•", blocks: blocks(item))
                })]
            case let value as BlockQuote: return [.quote(blocks(value))]
            case let value as Markdown.Table:
                let alignments: [ReplyAlignment] = value.columnAlignments.map {
                    switch $0 { case .center: return .center; case .right: return .trailing; default: return .leading }
                }
                return [.table(headers: value.head.cells.map(inlines), rows: value.body.rows.map { $0.cells.map(inlines) }, alignments: alignments)]
            case is ThematicBreak: return [.rule]
            case let value as HTMLBlock: return [.paragraph([ReplyInline(text: value.rawHTML)])]
            default: return blocks(node)
            }
        }
    }

    private static func inlines(_ parent: Markup) -> [ReplyInline] {
        parent.children.flatMap { node -> [ReplyInline] in
            switch node {
            case let value as Markdown.Text: return [ReplyInline(text: value.string)]
            case is SoftBreak: return [ReplyInline(text: " ")]
            case is LineBreak: return [ReplyInline(text: "\n")]
            case let value as InlineCode: return [ReplyInline(text: value.code, code: true)]
            case let value as Strong: return inlines(value).map { var run = $0; run.strong = true; return run }
            case let value as Emphasis: return inlines(value).map { var run = $0; run.emphasis = true; return run }
            case let value as Strikethrough: return inlines(value).map { var run = $0; run.strikethrough = true; return run }
            case let value as Link:
                let url = value.destination.flatMap(URL.init(string:))
                let allowed = ["https", "http", "mailto"].contains(url?.scheme?.lowercased() ?? "")
                let file = value.destination.flatMap { ConversationFileReference(text: $0.removingPercentEncoding ?? $0) }
                return inlines(value).map { var run = $0; run.link = allowed ? url : file?.url; return run }
            case let value as Markdown.Image: return inlines(value) // Render alt text without fetching remote media.
            case let value as InlineHTML: return [ReplyInline(text: value.rawHTML)]
            default: return inlines(node)
            }
        }
    }
}
