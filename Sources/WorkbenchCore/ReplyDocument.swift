import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
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

public struct ReplyInline: Equatable, Hashable, Sendable {
    public var text: String
    public var strong = false
    public var emphasis = false
    public var code = false
    public var strikethrough = false
    public var link: URL?
    /// Inline TeX ($…$ / \(…\)); the text carries the object replacement char.
    public var math: String? = nil

    public init(text: String, strong: Bool = false, emphasis: Bool = false, code: Bool = false,
                strikethrough: Bool = false, link: URL? = nil, math: String? = nil) {
        self.text = text
        self.strong = strong
        self.emphasis = emphasis
        self.code = code
        self.strikethrough = strikethrough
        self.link = link
        self.math = math
    }
}

public enum ReplyDocument {
    public static func parse(_ source: String, documentLinks: Bool = false) -> [ReplyBlock] {
        blocks(Document(parsing: ReplyMath.normalizeDelimiters(source)), documentLinks: documentLinks)
    }

    private static func blocks(_ parent: Markup, documentLinks: Bool, listDepth: Int = 0) -> [ReplyBlock] {
        parent.children.flatMap { blocks(from: $0, documentLinks: documentLinks, listDepth: listDepth) }
    }

    public static func blocks(from node: Markup, documentLinks: Bool = false) -> [ReplyBlock] {
        blocks(from: node, documentLinks: documentLinks, listDepth: 0)
    }

    private static func blocks(from node: Markup, documentLinks: Bool, listDepth: Int) -> [ReplyBlock] {
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
                    ReplyListItem(marker: "\(Int(value.startIndex) + index).", blocks: blocks(item, documentLinks: documentLinks, listDepth: listDepth + 1))
                })]
            case let value as UnorderedList:
                // Browser UA bullet ladder: disc, circle, then square (DSH keeps it).
                let bullet = ["•", "◦", "▪"][min(listDepth, 2)]
                return [.list(value.listItems.map { item in
                    ReplyListItem(marker: item.checkbox.map { $0 == .checked ? "☑" : "☐" } ?? bullet, blocks: blocks(item, documentLinks: documentLinks, listDepth: listDepth + 1))
                })]
            case let value as BlockQuote:
                let inner = blocks(value, documentLinks: documentLinks, listDepth: listDepth)
                if let (kind, content) = ReplyAlert.rewrite(inner) { return [.alert(kind: kind, content)] }
                return [.quote(inner)]
            case let value as Markdown.Table:
                let alignments: [ReplyAlignment] = value.columnAlignments.map {
                    switch $0 { case .center: return .center; case .right: return .trailing; default: return .leading }
                }
                return [.table(headers: value.head.cells.map { ReplyMath.splitInline(linkBareURLs(inlines($0, documentLinks: documentLinks))) }, rows: value.body.rows.map { $0.cells.map { ReplyMath.splitInline(linkBareURLs(inlines($0, documentLinks: documentLinks))) } }, alignments: alignments)]
            case is ThematicBreak: return [.rule]
            case let value as HTMLBlock: return [.paragraph([ReplyInline(text: value.rawHTML)])]
            default: return blocks(node, documentLinks: documentLinks, listDepth: listDepth)
            }
    }

#if canImport(Darwin)
    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
#else
    // NSDataDetector is unavailable in Linux Foundation. The detection only
    // keeps http/https matches, which this reproduces with the RFC 3986
    // character class after the scheme, plus trailing-punctuation trimming
    // the data detector also applies.
    private static let bareURLRegex = try! NSRegularExpression(pattern: "https?://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+")
    private static let urlTrailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\""]
#endif

    private static func linkMatches(in text: String) -> [(range: NSRange, url: URL)] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
#if canImport(Darwin)
        // The data detector reads its input through per-character bridging
        // (@objc __StringStorage.character(at:) and getCharacters(_:range:),
        // both paying String.UTF16View index conversions). Round-16 cold
        // find-bar attribution, nearest-product-frame accounting (archived
        // with the trace under docs/performance/20x-loop-rounds/round-16/):
        // linkMatches owns 66.6% of samples in total; the selected
        // bridge/DD hot leaves subtotal 26.6% of all samples, 97.6% of them
        // linkMatches-owned. Handing the detector the same characters in
        // contiguous UTF-16 storage lets it read the buffer directly;
        // detection results are unchanged (pinned by
        // checkLinkScanContiguousUTF16; isolated screening -34.8%).
        return linkDetector.matches(in: contiguousUTF16(text), range: whole).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (match.range, url)
        }
#else
        return bareURLRegex.matches(in: text, range: whole).compactMap { match in
            var range = match.range
            while range.length > 0 {
                let candidate = ns.substring(with: range)
                guard let last = candidate.last else { break }
                if urlTrailingPunctuation.contains(last) { range.length -= 1; continue }
                if last == ")", candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count { range.length -= 1; continue }
                break
            }
            guard range.length > 0, let url = URL(string: ns.substring(with: range)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (range, url)
        }
#endif
    }

#if canImport(Darwin)
    /// The same characters in contiguous UTF-16 storage: a materialized
    /// CFString that survives the String round trip, so Objective-C consumers
    /// scan the buffer directly instead of per-character Swift bridging. The
    /// empty string keeps its storage (no buffer to materialize).
    private static func contiguousUTF16(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var chars = Array(text.utf16)
        let materialized = chars.withUnsafeMutableBufferPointer { buffer in
            CFStringCreateWithCharacters(nil, buffer.baseAddress!, CFIndex(buffer.count)) as NSString
        }
        return materialized as String
    }
#endif

    private static func linkBareURLs(_ runs: [ReplyInline]) -> [ReplyInline] {
        runs.flatMap { run -> [ReplyInline] in
            guard run.link == nil, !run.code else { return [run] }
            let text = run.text as NSString
            let matches = linkMatches(in: run.text)
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
