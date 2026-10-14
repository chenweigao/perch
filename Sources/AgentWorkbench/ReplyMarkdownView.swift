import AppKit
import SwiftUI
import Observation
import WorkbenchCore

/// The reading scale. Kimi, OMP, Qoder and the other native agents share it with
/// their composers, and both renderers read every size, line height and gap from
/// here — SwiftUI rows while a reply streams, native cached rows once it settles —
/// so a settled row keeps the geometry of the row it replaces.
///
/// A 14 pt system body on a 22 pt line (≈1.57) with an ~48-character CJK measure:
/// the native macOS reading size rather than a web-sized one. Hierarchy comes from
/// weight and space; only H1 steps up in size.
enum ReplyStyle {
    static let readingWidth: CGFloat = 680
    static let bodySize: CGFloat = 14
    static let lineHeight: CGFloat = 22
    static let lineHeightRatio: CGFloat = lineHeight / bodySize
    static let paragraphSpacing: CGFloat = 10
    /// Between paragraphs inside list items, quotes and alerts.
    static let compactParagraphSpacing: CGFloat = 6
    static let codeSize: CGFloat = 12.5
    static let codeLineSpacing: CGFloat = 4
    /// Between the parts of one transcript entry, and above a reply's actions.
    static let entryPartSpacing: CGFloat = 10
    /// Between transcript entries; consecutive process rows sit closer.
    static let entrySpacing: CGFloat = 16
    static let processEntrySpacing: CGFloat = 6
    static let ink = Color.primary.opacity(0.9)
    static func headingSize(_ level: Int) -> CGFloat { level == 1 ? 16 : bodySize }
    static func headingLineHeight(_ level: Int) -> CGFloat { lineHeight }
    static let paper = Color.primary.opacity(0.035)
    // Preserve a dynamic color in cached attributed text. Applying alpha to
    // labelColor once can freeze the system appearance before the light window exists.
    static let nativeInk = NSColor(name: nil) { appearance in
        var ink = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { ink = NSColor.labelColor.withAlphaComponent(0.9) }
        return ink
    }
    static let tableCellSize: CGFloat = 13
    /// Column totals are arithmetic over estimated content widths, so a table
    /// never probes TextKit for widths and cannot feed the transcript layout.
    static let tableGeometry = ReplyTableGeometry(fontSize: tableCellSize)

    /// Block categories that set vertical rhythm. Display math spaces like code.
    enum BlockKind { case paragraph, heading, code, rule, other }
    /// Space above a block, shared by both renderers. Compact applies inside list
    /// items, quotes and alerts.
    static func blockSpacing(before block: BlockKind, after previous: BlockKind?, compact: Bool) -> CGFloat {
        guard let previous else { return 0 }
        if previous == .rule { return 20 }
        if previous == .heading { return 6 }
        if previous == .paragraph && block == .paragraph { return compact ? compactParagraphSpacing : paragraphSpacing }
        switch block {
        case .heading: return compact ? 12 : 20
        case .rule: return 20
        case .code: return compact ? 8 : 14
        case .paragraph, .other: return compact ? 4 : paragraphSpacing
        }
    }

    /// Code card chrome; the native card and the SwiftUI card place text identically.
    enum Code {
        static let cornerRadius: CGFloat = 8
        static let labelSize: CGFloat = 11
        static let copyButtonSize: CGFloat = 24
        static let headerHorizontalPadding: CGFloat = 12
        static let headerVerticalPadding: CGFloat = 3
        static var headerHeight: CGFloat { headerVerticalPadding * 2 + copyButtonSize }
        /// Around the code text, and on its leading side when there is no gutter.
        static let inset: CGFloat = 12
        static let gutterLeading: CGFloat = 10
        static let gutterTrailing: CGFloat = 8
    }
    enum ListLayout {
        static let markerGap: CGFloat = 8
        static let minimumMarkerWidth: CGFloat = 16
        /// Rows taller than one and a half lines are separated a little more.
        static let multilineRowGap: CGFloat = 4
        static let singleLineRowGap: CGFloat = 2
        static func rowGap(between previous: CGFloat, and next: CGFloat) -> CGFloat {
            max(previous, next) > ReplyStyle.lineHeight * 1.5 ? multilineRowGap : singleLineRowGap
        }
    }
    /// Quotes and alerts: a 2 pt rule with the text inset after it.
    enum Quote {
        static let leadingInset: CGFloat = 16
        static let verticalInset: CGFloat = 4
        static let barWidth: CGFloat = 2
    }
}

extension ReplyStyle.BlockKind {
    init(_ block: ReplyBlock) {
        switch block {
        case .paragraph: self = .paragraph
        case .heading: self = .heading
        case .code, .math: self = .code
        case .rule: self = .rule
        default: self = .other
        }
    }
}

enum UserMessageStyle {
    /// Nine lines of a folded long prompt; prompts past eleven lines fold.
    static let collapsedHeight: CGFloat = 189
    static let foldThreshold: CGFloat = 231
    static let lineHeight: CGFloat = 21
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 7
    static let cornerRadius: CGFloat = 12
    static let maxWidthRatio: CGFloat = 0.85
    static let topSpacing: CGFloat = 8
    static let paragraphSpacing: CGFloat = ReplyStyle.paragraphSpacing
}

enum ReplyParagraphLayout {
    static let enabled: Bool = {
        #if TRANSCRIPT_CHECKS
        return ProcessInfo.processInfo.environment["NAVIGATION_GROUP_PARAGRAPHS"] != "0"
        #else
        return true
        #endif
    }()
}

enum ReplyMarkdownPreparation: Equatable {
    case reuse(sessionID: String, messageID: String, source: String, blocks: [ReplyBlock])
    case reparseRejected(sessionID: String, messageID: String, source: String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.reuse(lhsSession, lhsMessage, lhsSource, _), .reuse(rhsSession, rhsMessage, rhsSource, _)):
            return lhsSession == rhsSession && lhsMessage == rhsMessage && lhsSource == rhsSource
        case let (.reparseRejected(lhsSession, lhsMessage, lhsSource),
                  .reparseRejected(rhsSession, rhsMessage, rhsSource)):
            return lhsSession == rhsSession && lhsMessage == rhsMessage && lhsSource == rhsSource
        default:
            return false
        }
    }
}

struct KimiMarkdown: View {
    let text: String
    var sessionID: String? = nil
    var messageID: String? = nil
    var preparation: ReplyMarkdownPreparation? = nil
    var coalescesParagraphs = ReplyParagraphLayout.enabled
    var body: some View {
        ReplyContent(text: text, sessionID: sessionID, messageID: messageID, preparation: preparation,
                     coalescesParagraphs: coalescesParagraphs).equatable()
    }
}

/// Static history is not reparsed when the surrounding conversation streams updates.
private struct ReplyContent: View, Equatable {
    let text: String
    let sessionID: String?
    let messageID: String?
    let preparation: ReplyMarkdownPreparation?
    let coalescesParagraphs: Bool
    private var blocks: [ReplyBlock] {
        if case .reuse(let expectedSession, let expectedID, let expectedSource, let blocks)? = preparation,
           expectedSession == sessionID, expectedID == messageID, expectedSource == text {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("markdown_parse_reused")
            #endif
            return blocks
        }
        #if TRANSCRIPT_CHECKS
        if case .reparseRejected(let expectedSession, let expectedID, let expectedSource)? = preparation,
           expectedSession == sessionID, expectedID == messageID, expectedSource == text {
            NavigationRenderMetrics.count("markdown_parse_rejected_fallback")
        } else {
            NavigationRenderMetrics.count("markdown_parse_direct")
            if preparation != nil { NavigationRenderMetrics.count("markdown_parse_preparation_mismatch") }
        }
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("markdown_parse", since: start) }
        #endif
        return ReplyDocument.parse(text)
    }
    var body: some View {
        ReplyBlocks(blocks: blocks, coalescesParagraphs: coalescesParagraphs)
            .foregroundStyle(ReplyStyle.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReplyBlocks: View {
    let blocks: [ReplyBlock]
    var compact = false
    var coalescesParagraphs = ReplyParagraphLayout.enabled
    @Environment(\.streamRevealCursor) private var revealCursor
    private struct Group: Identifiable, Equatable {
        let id: Int
        let block: ReplyBlock
        var following: [[ReplyInline]] = []
        /// Length in the reveal cursor space: paragraph and heading groups count
        /// their rendered UTF-16 text (with paragraph separators); code, lists,
        /// quotes, tables and rules are wholesale checkpoints with zero length —
        /// they appear once the cursor reaches them.
        var renderedLength: Int {
            switch block {
            case .paragraph(let runs):
                var total = runs.reduce(0) { $0 + $1.text.utf16.count }
                for paragraph in following {
                    total += 1 + paragraph.reduce(0) { $0 + $1.text.utf16.count }
                }
                return total + 1
            case .heading(_, let runs):
                return 1 + runs.reduce(0) { $0 + $1.text.utf16.count }
            default:
                return 0
            }
        }
    }
    private struct RevealedGroup: Equatable {
        let group: Group
        let truncateAt: Int?
    }
    // Bound streaming invalidation: only the final group of at most eight
    // paragraphs changes when the tail grows; completed groups remain equal.
    private var groups: [Group] {
        var result: [Group] = []
        for (index, block) in blocks.enumerated() {
            if coalescesParagraphs, case .paragraph(let runs) = block, runs.contains(where: { !$0.text.isEmpty }),
               let last = result.last, last.following.count < 7,
               case .paragraph(let first) = last.block, first.contains(where: { !$0.text.isEmpty }) {
                result[result.count - 1].following.append(runs)
            } else {
                result.append(Group(id: index, block: block))
            }
        }
        return result
    }
    /// Map the cursor onto groups: fully covered groups render whole, the
    /// crossing paragraph/heading group renders a grapheme-safe prefix, groups
    /// beyond the cursor stay hidden until it reaches them.
    private func revealedGroups(upTo cursor: Int) -> [RevealedGroup] {
        guard cursor != Int.max else { return groups.map { RevealedGroup(group: $0, truncateAt: nil) } }
        var offset = 0
        var result: [RevealedGroup] = []
        for group in groups {
            let length = group.renderedLength
            if cursor >= offset + length {
                result.append(RevealedGroup(group: group, truncateAt: nil))
            } else if length > 0, cursor > offset {
                result.append(RevealedGroup(group: group, truncateAt: cursor - offset))
            }
            offset += length
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(revealedGroups(upTo: revealCursor?.visible ?? Int.max), id: \.group.id) { revealed in
                let group = revealed.group
                GroupContent(group: group, compact: compact, coalescesParagraphs: coalescesParagraphs,
                             truncateAt: revealed.truncateAt).equatable()
                    .padding(.top, group.id == 0 ? 0 : spacing(before: group.block, after: blocks[group.id - 1]))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private struct GroupContent: View, Equatable {
        let group: Group
        let compact: Bool
        let coalescesParagraphs: Bool
        var truncateAt: Int? = nil
        @ViewBuilder var body: some View {
            if case .paragraph(let runs) = group.block {
                ReplyText(runs: runs, followingParagraphs: group.following,
                          paragraphSpacing: compact ? ReplyStyle.compactParagraphSpacing : ReplyStyle.paragraphSpacing,
                          preservesSelectionOnAppend: coalescesParagraphs, truncateAt: truncateAt)
            } else {
                ReplyBlockContent(block: group.block, coalescesParagraphs: coalescesParagraphs,
                                  truncateAt: truncateAt).equatable()
                    // Lists/quotes/tables appear whole at their checkpoint.
                    // Their nested blocks must not restart the outer cursor.
                    .environment(\.streamRevealCursor, nil)
            }
        }
    }

    private func spacing(before block: ReplyBlock, after previous: ReplyBlock?) -> CGFloat {
        ReplyStyle.blockSpacing(before: ReplyStyle.BlockKind(block),
                                after: previous.map { ReplyStyle.BlockKind($0) }, compact: compact)
    }

}

/// Completed Markdown blocks preserve their view tree while the tail streams.
private struct ReplyBlockContent: View, Equatable {
    let block: ReplyBlock
    var coalescesParagraphs = ReplyParagraphLayout.enabled
    /// UTF-16 cap in reveal cursor space; only headings consume it.
    var truncateAt: Int? = nil
    @ViewBuilder var body: some View {
        switch block {
        case .paragraph(let runs): ReplyText(runs: runs, truncateAt: truncateAt)
        case .heading(let level, let runs):
            ReplyText(runs: runs, size: ReplyStyle.headingSize(level),
                      weight: .semibold, lineHeight: ReplyStyle.headingLineHeight(level), truncateAt: truncateAt)
        case .code(let language, let source): ReplyCode(language: language, source: source)
        case .math(let latex): ReplyMathBlock(latex: latex)
        case .list(let items):
            let markerWidth = ReplyListMetrics.columnWidth(items.map(\.marker))
            ReplyListLayout {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: ReplyStyle.ListLayout.markerGap) {
                        ReplyListMarker(marker: item.marker)
                            .fixedSize()
                            .alignmentGuide(.firstTextBaseline) { _ in
                                ceil(NSFont.systemFont(ofSize: ReplyStyle.bodySize).ascender)
                            }
                            .frame(width: markerWidth, alignment: .trailing)
                        // Type erasure breaks the recursive SwiftUI view type, not the document hierarchy.
                        AnyView(ReplyBlocks(blocks: item.blocks, compact: true, coalescesParagraphs: coalescesParagraphs))
                    }
                }
            }
        case .quote(let blocks):
            AnyView(ReplyBlocks(blocks: blocks, compact: true, coalescesParagraphs: coalescesParagraphs))
                .padding(.leading, ReplyStyle.Quote.leadingInset).padding(.vertical, ReplyStyle.Quote.verticalInset)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.16)).frame(width: ReplyStyle.Quote.barWidth)
                }
        case .alert(let kind, let blocks):
            ReplyAlertBlock(kind: kind, blocks: blocks, coalescesParagraphs: coalescesParagraphs)
        case .table(let headers, let rows, let alignments):
            ReplyTable(headers: headers, rows: rows, alignments: alignments)
        case .rule: Rectangle().fill(.primary.opacity(0.09)).frame(height: 1)
        }
    }
}

/// GitHub-style alert (> [!NOTE] …): tinted bar, kind title, compact content.
/// Layout mirrors the quote block so both sit identically in the reading column.
private struct ReplyAlertBlock: View {
    let kind: ReplyAlertKind
    let blocks: [ReplyBlock]
    var coalescesParagraphs = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(kind.title, systemImage: kind.symbol)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(kind.tint)
            AnyView(ReplyBlocks(blocks: blocks, compact: true, coalescesParagraphs: coalescesParagraphs))
        }
        .padding(.leading, ReplyStyle.Quote.leadingInset).padding(.vertical, ReplyStyle.Quote.verticalInset)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(kind.tint.opacity(0.7)).frame(width: ReplyStyle.Quote.barWidth)
        }
    }
}

/// One right-aligned marker column per list, at least 16 pt wide, shared by the
/// SwiftUI and native renderers. Item text starts at the same x for "9." and
/// "10.", and a settled native row keeps the geometry of the streamed SwiftUI
/// row it replaces. Widths are measured with the marker's own label metrics.
@MainActor enum ReplyListMetrics {
    static let minimumMarkerWidth: CGFloat = ReplyStyle.ListLayout.minimumMarkerWidth
    private static let measuringField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: ReplyStyle.bodySize)
        field.alignment = .right
        field.lineBreakMode = .byClipping
        return field
    }()
    /// Markers repeat ("•", "1." …); bounded independently of history length.
    private static var widths: [String: CGFloat] = [:]
    static func markerWidth(_ marker: String) -> CGFloat {
        if let width = widths[marker] { return width }
        measuringField.stringValue = marker
        let width = measuringField.fittingSize.width
        if widths.count >= 256 { widths.removeAll(keepingCapacity: true) }
        widths[marker] = width
        return width
    }
    static func columnWidth(_ markers: [String]) -> CGFloat {
        max(minimumMarkerWidth, ceil(markers.map(markerWidth).max() ?? 0))
    }
}

/// Use the same marker metrics as native transcript rows. SwiftUI Text's rounded
/// baseline can otherwise add a pixel to every list item at some font sizes.
private struct ReplyListMarker: NSViewRepresentable {
    let marker: String
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: marker)
        field.font = .systemFont(ofSize: ReplyStyle.bodySize)
        field.textColor = ReplyStyle.nativeInk
        field.alignment = .right
        field.lineBreakMode = .byClipping
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) { field.stringValue = marker }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize {
        nsView.fittingSize
    }
}

/// Measure wrapped rows at the actual column width without a geometry/state loop.
private struct ReplyListLayout: Layout {
    struct Measurement {
        let width: CGFloat?
        let size: CGSize
        let rows: [CGSize]
        let offsets: [CGFloat]
    }
    func makeCache(subviews: Subviews) -> [Measurement] { [] }
    func updateCache(_ cache: inout [Measurement], subviews: Subviews) { cache.removeAll(keepingCapacity: true) }
    private func measure(width: CGFloat?, subviews: Subviews, cache: inout [Measurement]) -> Measurement {
        // SwiftUI also probes the maximum size with an infinite proposal.
        let columnWidth = width.flatMap { $0.isFinite ? $0 : nil }
        if let measured = cache.first(where: { $0.width == columnWidth }) { return measured }
        let rows = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)) }
        var offsets: [CGFloat] = []
        var height: CGFloat = 0
        for index in rows.indices {
            if index > 0 {
                height += ReplyStyle.ListLayout.rowGap(between: rows[index - 1].height, and: rows[index].height)
            }
            offsets.append(height)
            height += rows[index].height
        }
        let measured = Measurement(width: columnWidth,
            size: CGSize(width: columnWidth ?? rows.map(\.width).max() ?? 0, height: height), rows: rows, offsets: offsets)
        if cache.count == 4 { cache.removeFirst() }
        cache.append(measured)
        return measured
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [Measurement]) -> CGSize {
        measure(width: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [Measurement]) {
        let measured = measure(width: bounds.width, subviews: subviews, cache: &cache)
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY + measured.offsets[index]),
                                  anchor: .topLeading, proposal: ProposedViewSize(measured.rows[index]))
        }
    }
}

private struct ReplyInkKey: EnvironmentKey {
    static let defaultValue = ReplyStyle.nativeInk
}
private extension EnvironmentValues {
    var replyInk: NSColor {
        get { self[ReplyInkKey.self] }
        set { self[ReplyInkKey.self] = newValue }
    }
}
private struct ReplyLineHeightKey: EnvironmentKey {
    static let defaultValue = ReplyStyle.lineHeight
}
extension EnvironmentValues {
    var replyLineHeight: CGFloat {
        get { self[ReplyLineHeightKey.self] }
        set { self[ReplyLineHeightKey.self] = newValue }
    }
}

/// Live rows inject their reveal cursor; nil (and `Int.max`) render everything.
private struct StreamRevealCursorKey: EnvironmentKey { static let defaultValue: RevealCursor? = nil }
extension EnvironmentValues {
    var streamRevealCursor: RevealCursor? {
        get { self[StreamRevealCursorKey.self] }
        set { self[StreamRevealCursorKey.self] = newValue }
    }
}

/// Both native user rows and SwiftUI Markdown share exact text attributes.
enum ReplyTextAttributes {
    /// Attributed paragraph text is a pure function of runs and style. The live
    /// row's crossing group rebuilds it every reveal frame, including the file
    /// reference scan; memoize so a frame only slices the cached string.
    /// Render-thread only.
    private struct ParagraphsKey: Hashable {
        let paragraphs: [[ReplyInline]]
        let size: CGFloat
        let weight: CGFloat
        let alignment: TextAlignment
        let lineHeight: CGFloat
        let paragraphSpacing: CGFloat
        let ink: ObjectIdentifier
    }
    private static var paragraphsCache: [ParagraphsKey: NSAttributedString] = [:]
    private static var paragraphsCacheOrder: [ParagraphsKey] = []
    private static var paragraphsCacheCharacters = 0

    static func paragraphs(_ paragraphs: [[ReplyInline]], size: CGFloat = ReplyStyle.bodySize,
                           weight: NSFont.Weight = .regular, alignment: TextAlignment = .leading,
                           lineHeight: CGFloat? = nil, paragraphSpacing: CGFloat = ReplyStyle.paragraphSpacing,
                           ink: NSColor = ReplyStyle.nativeInk) -> NSAttributedString {
        // Body text uses the exact scale line height; other sizes keep its ratio.
        let resolvedLineHeight = lineHeight
            ?? (size == ReplyStyle.bodySize ? ReplyStyle.lineHeight : size * ReplyStyle.lineHeightRatio)
        let key = ParagraphsKey(paragraphs: paragraphs, size: size, weight: weight.rawValue,
                                alignment: alignment, lineHeight: resolvedLineHeight,
                                paragraphSpacing: paragraphSpacing, ink: ObjectIdentifier(ink))
        if let cached = paragraphsCache[key] {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("paragraphs_cache_hit")
            #endif
            if let index = paragraphsCacheOrder.firstIndex(of: key) {
                paragraphsCacheOrder.append(paragraphsCacheOrder.remove(at: index))
            }
            return cached
        }
        #if TRANSCRIPT_CHECKS
        NavigationRenderMetrics.count("paragraphs_cache_miss")
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("attributed_text", since: start) }
        #endif
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = resolvedLineHeight
        // Wrap oversized paths/URLs in TextKit without altering selectable text.
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment == .trailing ? .right : alignment == .center ? .center : .left
        for (index, paragraphRuns) in paragraphs.enumerated() {
            if index > 0 {
                // Space only the paragraph boundary, preserving Markdown hard breaks.
                let previous = (result.string as NSString).paragraphRange(for: NSRange(location: result.length - 1, length: 1))
                let separated = paragraph.mutableCopy() as! NSMutableParagraphStyle
                separated.paragraphSpacing = paragraphSpacing
                result.addAttribute(.paragraphStyle, value: separated, range: previous)
                var separator = result.attributes(at: result.length - 1, effectiveRange: nil)
                separator.removeValue(forKey: .link)
                result.append(NSAttributedString(string: "\n", attributes: separator))
            }
            for run in paragraphRuns {
                if let math = run.math {
                    // Inline formula: one attachment char carrying the paragraph style.
                    let attachment = NSMutableAttributedString(attributedString: ReplyMathAttachment.string(latex: math, size: size))
                    attachment.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attachment.length))
                    result.append(attachment)
                    continue
                }
                // Strong text is at least medium; it never lightens a semibold heading.
                let runWeight: NSFont.Weight = run.strong && weight.rawValue < NSFont.Weight.medium.rawValue ? .medium : weight
                var font = run.code ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: runWeight)
                                    : NSFont.systemFont(ofSize: size, weight: runWeight)
                if run.emphasis { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: ink, .paragraphStyle: paragraph
                ]
                if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link {
                    // Render layer: only allowlisted schemes become clickable;
                    // everything else stays plain text (SafeLink).
                    if let reference = ConversationFileReference(text: link.relativeString.removingPercentEncoding ?? link.relativeString)?.url {
                        attributes[.link] = reference
                    } else if SafeLink.allowed(link) {
                        attributes[.link] = link
                    }
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        #if TRANSCRIPT_CHECKS
        // Nested inside attributed_text; reported separately because this scan is
        // the part whose cost grows with paragraph length rather than run count.
        let scanStart = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("file_reference_scan", since: scanStart) }
        #endif
        for (range, reference) in ConversationFileReference.matches(in: result.string) {
            if result.attribute(.link, at: range.location, effectiveRange: nil) == nil {
                result.addAttribute(.link, value: reference.url, range: range)
            }
        }
        let characters = result.length
        if characters <= 512_000 {
            while !paragraphsCacheOrder.isEmpty,
                  paragraphsCacheOrder.count >= 96 || paragraphsCacheCharacters + characters > 512_000 {
                let oldest = paragraphsCacheOrder.removeFirst()
                if let evicted = paragraphsCache.removeValue(forKey: oldest) {
                    paragraphsCacheCharacters -= evicted.length
                }
            }
            paragraphsCache[key] = result
            paragraphsCacheOrder.append(key)
            paragraphsCacheCharacters += characters
        }
        return result
    }

    /// Matches `SelectableReplyText(_:font:lineSpacing:)` so native and SwiftUI code
    /// cards measure identical text.
    static func code(_ source: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = ReplyStyle.codeLineSpacing
        return NSAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: ReplyStyle.codeSize, weight: .regular),
            .foregroundColor: ReplyStyle.nativeInk, .paragraphStyle: paragraph
        ])
    }
    /// Gutter numbers share the code font and line spacing so rows align
    /// exactly; only color and alignment differ.
    static func codeGutter(_ lines: Int) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = ReplyStyle.codeLineSpacing; paragraph.alignment = .right
        let numbers = (1...max(1, lines)).map(String.init).joined(separator: "\n")
        return NSAttributedString(string: numbers, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: ReplyStyle.codeSize, weight: .regular),
            .foregroundColor: ReplyStyle.nativeInk.withAlphaComponent(0.32), .paragraphStyle: paragraph
        ])
    }
}

/// A trailing newline ends the last line rather than starting another.
enum CodeLineNumbers {
    static func count(in source: String) -> Int {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).count
        if source.hasSuffix("\n") { lines -= 1 }
        return max(1, lines)
    }
}

private struct ReplyText: View {
    @Environment(\.replyInk) private var ink
    @Environment(\.replyLineHeight) private var defaultLineHeight
    let runs: [ReplyInline]
    var size: CGFloat = ReplyStyle.bodySize
    var weight: NSFont.Weight = .regular
    var alignment: TextAlignment = .leading
    var lineHeight: CGFloat? = nil
    var followingParagraphs: [[ReplyInline]] = []
    var paragraphSpacing: CGFloat = ReplyStyle.paragraphSpacing
    var preservesSelectionOnAppend = false
    /// Live reveal cap in UTF-16 units; nil renders the complete text.
    var truncateAt: Int? = nil
    private var resolvedLineHeight: CGFloat { lineHeight ?? defaultLineHeight }
    private var attributed: NSAttributedString {
        let full = ReplyTextAttributes.paragraphs([runs] + followingParagraphs, size: size, weight: weight,
                                                  alignment: alignment, lineHeight: resolvedLineHeight,
                                                  paragraphSpacing: paragraphSpacing, ink: ink)
        guard let truncateAt, truncateAt < full.length else { return full }
        return full.visiblePrefix(utf16Count: truncateAt)
    }
    var body: some View {
        SelectableReplyText(attributed: attributed, preservesSelectionOnAppend: preservesSelectionOnAppend)
            .alignmentGuide(.firstTextBaseline) { _ in
                let font = NSFont.systemFont(ofSize: size)
                let naturalHeight = ceil(font.ascender - font.descender + font.leading)
                // TextKit adds minimum-line-height leading above the glyph baseline.
                return ceil(font.ascender) + max(0, resolvedLineHeight - naturalHeight)
            }
            .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }
}

/// TextKit owns selection and line measurement. SwiftUI receives only the measured
/// size, with no SelectionOverlay/font-baseline feedback through its layout graph.
private struct ConversationBodyTextKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isConversationBodyText: Bool {
        get { self[ConversationBodyTextKey.self] }
        set { self[ConversationBodyTextKey.self] = newValue }
    }
}

struct SelectableReplyText: NSViewRepresentable {
    @Environment(\.isConversationBodyText) private var isConversationBodyText
    let attributed: NSAttributedString
    var preservesSelectionOnAppend = false
    /// Gutter-style rows opt out of selection.
    var selectable = true
    init(attributed: NSAttributedString, preservesSelectionOnAppend: Bool = false, selectable: Bool = true) {
        self.attributed = attributed
        self.preservesSelectionOnAppend = preservesSelectionOnAppend
        self.selectable = selectable
    }
    init(_ text: String, font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular), lineSpacing: CGFloat = 4, selectable: Bool = true) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing
        attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: ReplyStyle.nativeInk, .paragraphStyle: paragraph
        ])
        self.selectable = selectable
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            if url.scheme == "perch-file" {
                NotificationCenter.default.post(name: .init("PerchOpenConversationFile"), object: url)
                return true
            }
            // Click layer defense in depth: non-allowlisted schemes are
            // swallowed here even if some path missed the render allowlist.
            return !SafeLink.allowed(url)
        }
    }
    // Dismantled paragraphs hold no message content or delegate. Reuse only after
    // SwiftUI has detached them; cap the pool independently of history length.
    private static var recycled: [ReplyTextView] = []
    #if TRANSCRIPT_CHECKS
    static var recycledCount: Int { recycled.count }
    #endif
    static func dismantleNSView(_ view: ReplyTextView, coordinator: Coordinator) { recycle(view) }
    static func recycle(_ view: ReplyTextView) {
        view.delegate = nil
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.update(NSAttributedString(string: ""))
        view.isConversationBodyText = false
        view.extraMenuItems = nil
        view.findHighlight = nil
        if recycled.count < 64 { recycled.append(view) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ReplyTextView { Self.acquire(delegate: context.coordinator) }
    static func acquire(delegate: NSTextViewDelegate) -> ReplyTextView {
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("text_create", since: start) }
        #endif
        // The enclosing conversation owns viewport layout; each short paragraph
        // needs selection and drawing, not another TextKit 2 viewport controller.
        let view: ReplyTextView
        if let index = Self.recycled.firstIndex(where: { $0.superview == nil && $0.window == nil }) {
            view = Self.recycled.remove(at: index)
            #if TRANSCRIPT_CHECKS
            precondition(view.string.isEmpty && view.delegate == nil && view.selectedRange().length == 0,
                         "Recycled text view retained outgoing row state")
            NavigationRenderMetrics.record("text_reuse", since: CACurrentMediaTime())
            #endif
        } else {
            view = ReplyTextView(usingTextLayoutManager: false)
        }
        view.isEditable = false
        view.delegate = delegate
        view.enabledTextCheckingTypes = 0
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.linkTextAttributes = [.foregroundColor: WorkbenchTheme.link]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: ReplyTextView, context: Context) { view.isConversationBodyText = isConversationBodyText; view.isSelectable = selectable; view.update(attributed, preservingSelectionOnAppend: preservesSelectionOnAppend) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReplyTextView, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}

enum NativeParagraphContent {
    struct Preparation {
        let blocks: [ReplyBlock]
        let content: [NSAttributedString]?
    }

    static func make(_ source: String, lineHeight: CGFloat? = nil) -> [NSAttributedString]? {
        prepare(source, lineHeight: lineHeight).content
    }

    static func prepare(_ source: String, lineHeight: CGFloat? = nil) -> Preparation {
        #if TRANSCRIPT_CHECKS
        let parseStart = CACurrentMediaTime()
        let blocks = ReplyDocument.parse(source)
        NavigationRenderMetrics.record("row_parse", since: parseStart)
        NavigationRenderMetrics.count("row_parse_native_user")
        #else
        let blocks = ReplyDocument.parse(source)
        #endif
        let content = build(blocks, lineHeight: lineHeight)
        #if TRANSCRIPT_CHECKS
        if content == nil { NavigationRenderMetrics.count("row_parse_rejected") }
        #endif
        return Preparation(blocks: blocks, content: content)
    }

    private static func build(_ blocks: [ReplyBlock], lineHeight: CGFloat?) -> [NSAttributedString]? {
        var paragraphs: [[ReplyInline]] = []
        for block in blocks {
            guard case .paragraph(let runs) = block, runs.contains(where: { !$0.text.isEmpty }) else { return nil }
            paragraphs.append(runs)
        }
        guard !paragraphs.isEmpty else { return nil }
        return stride(from: 0, to: paragraphs.count, by: 8).map {
            ReplyTextAttributes.paragraphs(Array(paragraphs[$0..<min($0 + 8, paragraphs.count)]), lineHeight: lineHeight)
        }
    }
}

/// Plain-paragraph user messages need text selection and a right-aligned bubble,
/// but no SwiftUI state graph. Complex Markdown/attachments keep their existing row.
private final class UserPromptClipView: NSView { override var isFlipped: Bool { true } }

final class NativeUserMessageView: NSView {
    private static var recycled: [NativeUserMessageView] = []
    private var texts: [ReplyTextView] = []
    private let links = SelectableReplyText.Coordinator()
    private let bubbleBackground = NSView()
    private let promptClip = UserPromptClipView()
    private let expandButton = NSButton()
    var expansionKey: String?
    var expansionWillChange: (() -> Void)?
    var expansionDidChange: (() -> Void)?
    private var expanded: Bool {
        expansionKey.flatMap { ConversationReadingMemory.shared.expansions[$0 + ":user-prompt"] } ?? false
    }
    @objc private func togglePrompt() {
        guard let expansionKey else { return }
        expansionWillChange?()
        ConversationReadingMemory.shared.expansions[expansionKey + ":user-prompt"] = !expanded
        expansionDidChange?()
    }
    /// Row identity for message-level menu actions; set by the hosting controller.
    var actionContext: ConversationActionContext?
    var sourceText = ""
    /// Turn id + reading key for the bookmark menu item.
    var bookmarkTurn: String?
    var bookmarkSession: String?
    override var isFlipped: Bool { true }
    var widthChanged: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = bounds.width
        super.setFrameSize(newSize)
        if bounds.width != previousWidth { widthChanged?() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if TRANSCRIPT_CHECKS
        bubbleBackground.identifier = NSUserInterfaceItemIdentifier("native-user-bubble-background")
        #endif
        bubbleBackground.wantsLayer = true
        bubbleBackground.layer?.cornerRadius = UserMessageStyle.cornerRadius
        addSubview(bubbleBackground)
        promptClip.wantsLayer = true
        promptClip.layer?.masksToBounds = true
        addSubview(promptClip)
        expandButton.bezelStyle = .inline
        expandButton.font = .systemFont(ofSize: 12)
        expandButton.target = self
        expandButton.action = #selector(togglePrompt)
        expandButton.identifier = NSUserInterfaceItemIdentifier("user-prompt-toggle")
        addSubview(expandButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func content(_ source: String) -> [NSAttributedString]? {
        NativeParagraphContent.make(source, lineHeight: UserMessageStyle.lineHeight)
    }
    static func acquire() -> NativeUserMessageView { recycled.popLast() ?? NativeUserMessageView() }
    static func recycle(_ view: NativeUserMessageView) {
        view.widthChanged = nil
        view.identifier = nil
        view.removeFromSuperview()
        view.actionContext = nil
        view.sourceText = ""
        view.expansionKey = nil
        view.expansionWillChange = nil
        view.expansionDidChange = nil
        view.expandButton.isHidden = true
        view.bookmarkTurn = nil
        view.bookmarkSession = nil
        for text in view.texts { text.setSelectedRange(NSRange(location: 0, length: 0)); text.update(NSAttributedString(string: "")) }
        // A giant prompt must not leave an unbounded number of text containers
        // in the row pool after it is no longer visible.
        while view.texts.count > 8 {
            let text = view.texts.removeLast(); text.removeFromSuperview(); SelectableReplyText.recycle(text)
        }
        if recycled.count < 16 { recycled.append(view) }
    }
    func update(_ content: [NSAttributedString], dark: Bool) {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bubbleBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
        }
        while texts.count > content.count {
            let text = texts.removeLast(); text.removeFromSuperview(); SelectableReplyText.recycle(text)
        }
        while texts.count < content.count {
            let text = SelectableReplyText.acquire(delegate: links)
            text.isConversationBodyText = true
            text.extraMenuItems = { [weak self] in
                guard let self, let context = self.actionContext, !self.sourceText.isEmpty else { return [] }
                var items = context.userMenuItems(copyText: self.sourceText, sourceText: self.sourceText)
                if let turn = self.bookmarkTurn, let session = self.bookmarkSession {
                    items += [.separator(), ConversationActionContext.bookmarkMenuItem(turn: turn, session: session)]
                }
                return items
            }
            texts.append(text); promptClip.addSubview(text)
        }
        for (text, value) in zip(texts, content) { text.update(value, preservingSelectionOnAppend: true) }
        needsDisplay = true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let actionContext, !sourceText.isEmpty else { return nil }
        let menu = actionContext.userMenu(copyText: sourceText, sourceText: sourceText)
        if let turn = bookmarkTurn, let session = bookmarkSession {
            menu.addItem(.separator())
            menu.addItem(ConversationActionContext.bookmarkMenuItem(turn: turn, session: session))
        }
        return menu
    }
    private func measurements(width: CGFloat) -> (bubbleWidth: CGFloat, sizes: [CGSize]) {
        let contentPadding = UserMessageStyle.horizontalPadding * 2
        let maxBubble = width * UserMessageStyle.maxWidthRatio
        let ideal = (texts.map { $0.measure(width: nil).width }.max() ?? 0) + contentPadding
        let bubbleWidth = min(ideal, maxBubble)
        return (bubbleWidth, texts.map { $0.measure(width: max(1, bubbleWidth - contentPadding)) })
    }
    func measure(width: CGFloat) -> CGSize {
        let sizes = measurements(width: width).sizes
        let textHeight = sizes.reduce(CGFloat.zero) { $0 + $1.height }
        let gaps = CGFloat(max(0, sizes.count - 1)) * UserMessageStyle.paragraphSpacing
        let natural = textHeight + gaps
        let folds = natural > UserMessageStyle.foldThreshold
        let visible = folds && !expanded ? UserMessageStyle.collapsedHeight : natural
        return CGSize(width: width, height: UserMessageStyle.topSpacing + UserMessageStyle.verticalPadding * 2 + visible + (folds ? 30 : 0))
    }
    func place(width: CGFloat) {
        let layout = measurements(width: width)
        let x = width - layout.bubbleWidth
        let natural = layout.sizes.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(0, layout.sizes.count - 1)) * UserMessageStyle.paragraphSpacing
        let folds = natural > UserMessageStyle.foldThreshold
        let visible = folds && !expanded ? UserMessageStyle.collapsedHeight : natural
        promptClip.frame = CGRect(x: x, y: UserMessageStyle.topSpacing + UserMessageStyle.verticalPadding,
                                  width: layout.bubbleWidth, height: visible)
        expandButton.isHidden = !folds
        expandButton.title = L(expanded ? "收起问题" : "展开完整问题")
        expandButton.setAccessibilityLabel(expandButton.title)
        expandButton.frame = CGRect(x: x + UserMessageStyle.horizontalPadding,
            y: promptClip.frame.maxY + 4, width: max(1, layout.bubbleWidth - UserMessageStyle.horizontalPadding * 2), height: 24)
        var y: CGFloat = 0
        for (text, size) in zip(texts, layout.sizes) {
            let frame = CGRect(x: UserMessageStyle.horizontalPadding, y: y,
                               width: max(1, layout.bubbleWidth - UserMessageStyle.horizontalPadding * 2), height: size.height)
            if text.frame != frame { text.frame = frame }
            y += size.height + UserMessageStyle.paragraphSpacing
        }
        let height = measure(width: width).height - UserMessageStyle.topSpacing
        let next = CGRect(x: x, y: UserMessageStyle.topSpacing, width: layout.bubbleWidth, height: height)
        if bubbleBackground.frame != next { bubbleBackground.frame = next }
    }
}

private struct NativeAssistantActions: View {
    var source: String?
    var enabled = true
    var context: ConversationActionContext?
    var messageID: String?
    var body: some View {
        HStack(spacing: 2) {
            if let source { ReplyCopyButton(text: source).id(source).disabled(!enabled) }
            if let context, let source {
                Button { context.post(.quote(source)) } label: {
                    Image(systemName: "quote.opening").font(.system(size: 11))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("引用到输入框")
                    .accessibilityLabel("引用到输入框")
                if let messageID, !messageID.isEmpty {
                    Button { context.post(.regenerate(before: messageID)) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("重新生成（重发上一条提问）")
                        .accessibilityLabel("重新生成")
                }
            }
        }
    }
}

final class NativeAssistantMessageView: NSView {
    private static var recycled: [NativeAssistantMessageView] = []
    private let links = SelectableReplyText.Coordinator()
    private let stack: NativeAssistantStackView
    private let actions = NSHostingView(rootView: NativeAssistantActions())
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        stack = NativeAssistantStackView(compact: false, links: links)
        super.init(frame: frameRect)
        actions.sizingOptions = []
        actions.safeAreaRegions = []
        addSubview(stack)
        addSubview(actions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func acquire() -> NativeAssistantMessageView {
        #if TRANSCRIPT_CHECKS
        NavigationRenderMetrics.record(recycled.isEmpty ? "native_assistant_create" : "native_assistant_reuse", since: CACurrentMediaTime())
        #endif
        return recycled.popLast() ?? NativeAssistantMessageView(frame: .zero)
    }
    static func recycle(_ view: NativeAssistantMessageView) {
        view.removeFromSuperview()
        view.actions.rootView = NativeAssistantActions()
        // Block containers are torn down; their text views return to the shared pool
        // cleared of content and selection, so recycled shells hold no conversation data.
        view.stack.teardown()
        if recycled.count < 16 { recycled.append(view) }
    }
    func update(_ blocks: [NativeAssistantBlock], source: String, dark: Bool, enabled: Bool = true,
                actionContext: ConversationActionContext? = nil, messageID: String? = nil) {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        stack.update(blocks)
        let next = actions.rootView
        if next.source != source || next.enabled != enabled || next.context != actionContext || next.messageID != messageID {
            actions.rootView = NativeAssistantActions(source: source, enabled: enabled, context: actionContext, messageID: messageID)
        }
        // The hosting view hugs its buttons so hit targets never sit in padding.
        actionButtonCount = (source == nil ? 0 : 1) + (actionContext != nil && source != nil ? 1 : 0)
            + (actionContext != nil && messageID?.isEmpty == false ? 1 : 0)
    }
    private var actionButtonCount = 1
    private var actionsWidth: CGFloat { CGFloat(actionButtonCount) * 24 + CGFloat(max(0, actionButtonCount - 1)) * 2 }
    func measure(width: CGFloat) -> CGSize {
        CGSize(width: width, height: stack.contentHeight(width: width) + ReplyStyle.entryPartSpacing + 24)
    }
    func place(width: CGFloat) {
        let content = stack.contentHeight(width: width)
        let stackFrame = CGRect(x: 0, y: 0, width: width, height: content)
        if stack.frame != stackFrame { stack.frame = stackFrame }
        stack.place(width: width)
        let frame = CGRect(x: 0, y: content + ReplyStyle.entryPartSpacing, width: actionsWidth, height: 24)
        if actions.frame != frame { actions.frame = frame }
    }
    #if TRANSCRIPT_CHECKS
    static var poolState: [String: Any] {
        ["rows": recycled.count,
         "cleared": recycled.allSatisfy { view in
             view.actions.rootView.source == nil && view.stack.blocks.isEmpty && view.stack.textViews().isEmpty
         }]
    }
    #endif
}

final class ReplyTextView: NSTextView {
    var isConversationBodyText = false
    /// Extra context-menu items (message-level actions) supplied by the row.
    var extraMenuItems: (() -> [NSMenuItem])?
    /// Active find-bar query to highlight across this text. Re-applied after
    /// every content update, since streaming replaces the text storage.
    var findHighlight: (query: String, caseSensitive: Bool, regex: Bool)?
    private var hasFindHighlight = false
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let extra = extraMenuItems?(), !extra.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            extra.forEach { menu.addItem($0) }
        }
        return menu
    }
    /// Background-color is not part of reply styling, so clearing it here
    /// cannot disturb content. Works in text attributes, never layout.
    func applyFindHighlight() {
        guard let storage = textStorage, findHighlight != nil || hasFindHighlight else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: full)
        if let highlight = findHighlight, !highlight.query.isEmpty, storage.length > 0 {
            let color = NSColor.systemYellow.withAlphaComponent(0.35)
            if highlight.regex, let expression = try? NSRegularExpression(
                pattern: highlight.query, options: highlight.caseSensitive ? [] : [.caseInsensitive]) {
                for match in expression.matches(in: storage.string, range: full) {
                    storage.addAttribute(.backgroundColor, value: color, range: match.range)
                }
            } else if !highlight.regex {
                let options: NSString.CompareOptions = highlight.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
                let source = storage.string as NSString
                var search = full
                while search.length > 0 {
                    let found = source.range(of: highlight.query, options: options, range: search)
                    guard found.location != NSNotFound else { break }
                    storage.addAttribute(.backgroundColor, value: color, range: found)
                    search = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
                }
            }
        }
        hasFindHighlight = findHighlight != nil
        storage.endEditing()
    }
    // SwiftUI alternates minimum, ideal and final width proposals. Retain those
    // sizes together; a single last-width cache remeasures unchanged history.
    private var measurements: [(width: CGFloat, size: CGSize)] = []
    func update(_ value: NSAttributedString, preservingSelectionOnAppend: Bool = false) {
        guard let storage = textStorage, !storage.isEqual(to: value) else { return }
        let appending = value.string.hasPrefix(storage.string)
        let retainedSelection = preservingSelectionOnAppend && appending ? selectedRange() : nil
        if appending {
            // Prefix growth (streaming, reveal frames): append only the delta so
            // TextKit layout invalidates the tail, not the whole paragraph.
            storage.append(value.attributedSubstring(from: NSRange(location: storage.length, length: value.length - storage.length)))
        } else {
            storage.setAttributedString(value)
        }
        if let retainedSelection { setSelectedRange(retainedSelection) }
        measurements.removeAll(keepingCapacity: true)
        applyFindHighlight()
    }
    func measure(width proposed: CGFloat?) -> CGSize {
        // A nil proposal is the ideal unwrapped width used by code and wide tables.
        let width = max(1, proposed?.isFinite == true ? proposed! : 1_000_000)
        if let cached = measurements.first(where: { $0.width == width }) {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("text_measure_cache_hit")
            #endif
            return cached.size
        }
        guard let storage = textStorage else { return .zero }
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer {
            NavigationRenderMetrics.record("text_measure", since: start)
            // An unwrapped probe lays the whole string out on one 1,000,000pt line;
            // splitting it from wrapped measurement is what makes a redundant
            // ideal-width probe visible instead of hiding inside text_measure.
            NavigationRenderMetrics.record(width >= 1_000_000 ? "text_measure_unwrapped" : "text_measure_wrapped", since: start)
        }
        #endif
        // Measure independently from NSTextView's drawing container: Grid probes
        // multiple widths, and those probes must never reflow the displayed text.
        let used = storage.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
        if measurements.count == 8 { measurements.removeFirst() }
        measurements.append((width, size))
        return size
    }

}

/// A disclosure should not synchronously lay out an unbounded log on opening.
/// Keep the full source available for explicit inspection and copying.
struct DisclosureReplyText: View {
    let text: String
    var attributes: [NSAttributedString.Key: Any]? = nil
    @State private var fullOverride: Bool?
    @Environment(\.conversationMemoryKey) private var memoryKey
    private var showingAll: Bool {
        fullOverride ?? (!memoryKey.isEmpty && ConversationReadingMemory.shared.expansions[memoryKey + ":full-output"] == true)
    }
    @State private var reader = LongOutputReaderHandle()
    @Environment(\.conversationDisclosureWillChange) private var disclosureWillChange

    private var expansion: Binding<Bool> {
        Binding(get: { showingAll }, set: { value in
            disclosureWillChange()
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { fullOverride = value }
        })
    }
    private var usesViewport: Bool {
        #if TRANSCRIPT_CHECKS
        return ProcessInfo.processInfo.environment["NAVIGATION_LONG_OUTPUT_VARIANT"] != "inline"
        #else
        return true
        #endif
    }

    var body: some View {
        let prefix = text.prefix(4_000)
        let isLong = prefix.endIndex != text.endIndex
        let visible = showingAll || !isLong ? text : String(prefix)
        #if TRANSCRIPT_CHECKS
        let _ = { if ConversationDisclosureFixture.enabled && isLong {
            ConversationDisclosureFixture.fullBindings[text] = expansion
        } }()
        #endif
        VStack(alignment: .leading, spacing: 8) {
            if showingAll && isLong && usesViewport {
                LongOutputReader(text: text, attributes: attributes, handle: reader)
                    .frame(height: 360)
            } else {
                Group {
                    if let attributes {
                        SelectableReplyText(attributed: NSAttributedString(string: visible, attributes: attributes))
                    } else {
                        SelectableReplyText(visible)
                    }
                }.frame(height: isLong && usesViewport ? 360 : nil, alignment: .top).clipped()
            }
            if isLong {
                HStack(spacing: 12) {
                    if !showingAll { Text("…").foregroundStyle(.secondary) }
                    Button(showingAll ? "收起长内容" : "显示完整内容") { expansion.wrappedValue.toggle() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    if showingAll && usesViewport {
                        Button("查找完整内容") { reader.showFindBar() }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    ReplyCopyButton(text: text, label: "复制完整内容")
                }.font(.system(size: 11))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Complete text has its own viewport. The transcript measures only this fixed
/// viewport, never the full text height. TextKit owns selection and text layout.
@MainActor @Observable final class LongOutputReaderHandle {
    @ObservationIgnored weak var textView: NSTextView?
    var searchVisible = false
    var query = ""
    var found: Bool?
    func showFindBar() { searchVisible = true }
    func find(backwards: Bool = false) {
        guard let textView, !query.isEmpty else { found = nil; return }
        let source = textView.string as NSString
        let selection = textView.selectedRange()
        let start = min(source.length, backwards ? selection.location : NSMaxRange(selection))
        let range = backwards ? NSRange(location: 0, length: start) : NSRange(location: start, length: source.length - start)
        var options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if backwards { options.insert(.backwards) }
        var hit = source.range(of: query, options: options, range: range)
        if hit.location == NSNotFound { hit = source.range(of: query, options: options) }
        found = hit.location != NSNotFound
        if found == true {
            textView.setSelectedRange(hit)
            textView.scrollRangeToVisible(hit)
        }
    }
}

struct LongOutputReader: View {
    let text: String
    let attributes: [NSAttributedString.Key: Any]?
    @Bindable var handle: LongOutputReaderHandle
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 6) {
            if handle.searchVisible {
                HStack(spacing: 8) {
                    TextField("查找完整内容", text: $handle.query)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                        .onSubmit { handle.find() }
                    if handle.found == false { Text("未找到").foregroundStyle(.secondary) }
                    Button { handle.find(backwards: true) } label: { Image(systemName: "chevron.up") }.help("上一个匹配")
                    Button { handle.find() } label: { Image(systemName: "chevron.down") }.help("下一个匹配")
                    Button { handle.searchVisible = false } label: { Image(systemName: "xmark") }.help("关闭查找")
                }.font(.system(size: 11)).frame(height: 28)
            }
            LongOutputViewport(text: text, attributes: attributes, handle: handle)
                .frame(height: handle.searchVisible ? 326 : 360)
        }.frame(height: 360)
            .onChange(of: handle.searchVisible) { _, visible in searchFocused = visible }
            .onChange(of: handle.query) { _, _ in handle.found = nil }
    }
}

private final class LongOutputTextView: NSTextView {
    var find: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" { find?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

private struct LongOutputViewport: NSViewRepresentable {
    let text: String
    let attributes: [NSAttributedString.Key: Any]?
    let handle: LongOutputReaderHandle

    final class Coordinator {
        var text: String?
        var attributes: NSDictionary?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.identifier = .init("perch-long-output")
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = LongOutputTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 360)
        view.minSize = NSSize(width: 0, height: 360)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.enabledTextCheckingTypes = 0
        view.find = { [weak handle] in handle?.showFindBar() }
        view.setAccessibilityLabel(NSLocalizedString("完整内容", comment: "Full output reader"))
        scroll.documentView = view
        handle.textView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        handle.textView = view
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let style = attributes ?? [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                   .foregroundColor: ReplyStyle.nativeInk, .paragraphStyle: paragraph]
        let dictionary = style as NSDictionary
        guard context.coordinator.text != text || context.coordinator.attributes != dictionary else { return }
        let previous = context.coordinator.text
        let appending = context.coordinator.attributes == dictionary && previous.map { text.hasPrefix($0) } == true
        let sourceChanged = context.coordinator.text != text
        context.coordinator.text = text
        context.coordinator.attributes = dictionary
        if appending, let previous {
            let suffix = (text as NSString).substring(from: previous.utf16.count)
            view.textStorage?.append(NSAttributedString(string: suffix, attributes: style))
        } else {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: style))
        }
        if sourceChanged && !appending {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? ReplyStyle.readingWidth, height: proposal.height ?? 360)
    }
}

struct ReplyCopyButton: View {
    let text: String
    var label = "复制回复"
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary).help(copied ? "已复制" : label)
            .accessibilityLabel(copied ? "已复制" : label)
            .task(id: copied) {
                if copied { try? await Task.sleep(for: .seconds(2)); copied = false }
            }
    }
}

private struct ReplyCode: View {
    let language: String
    let source: String
    private var lineCount: Int { CodeLineNumbers.count(in: source) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.system(size: ReplyStyle.Code.labelSize, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                ReplyCopyButton(text: source, label: "复制代码")
            }.padding(.horizontal, ReplyStyle.Code.headerHorizontalPadding).padding(.vertical, ReplyStyle.Code.headerVerticalPadding)
            Rectangle().fill(.primary.opacity(0.055)).frame(height: 1)
            // The settled native card uses an overlay scroller that takes no height.
            // When macOS shows legacy scrollers (a mouse is attached), a SwiftUI
            // scroll view reserves a scroller band below an overflowing line once it
            // is displayed, so this card would be taller than the native card it
            // settles into. Never reserve it; trackpad and Shift-wheel still scroll.
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    if lineCount > 1 {
                        SelectableReplyText(attributed: ReplyTextAttributes.codeGutter(lineCount), selectable: false)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.leading, ReplyStyle.Code.gutterLeading).padding(.trailing, ReplyStyle.Code.gutterTrailing)
                            .padding(.vertical, ReplyStyle.Code.inset)
                    }
                    SelectableReplyText(source, font: .monospacedSystemFont(ofSize: ReplyStyle.codeSize, weight: .regular),
                                        lineSpacing: ReplyStyle.codeLineSpacing)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(EdgeInsets(top: ReplyStyle.Code.inset, leading: lineCount > 1 ? 0 : ReplyStyle.Code.inset,
                                            bottom: ReplyStyle.Code.inset, trailing: ReplyStyle.Code.inset))
                }
            }
            .scrollIndicators(.never, axes: .horizontal)
        }.background(ReplyStyle.paper, in: RoundedRectangle(cornerRadius: ReplyStyle.Code.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ReplyStyle.Code.cornerRadius).strokeBorder(.primary.opacity(0.055)))
    }
}

private struct ReplyTable: View {
    let headers: [[ReplyInline]]
    let rows: [[[ReplyInline]]]
    let alignments: [ReplyAlignment]
    private let contents: [CGFloat]
    private let minimumTotal: CGFloat

    init(headers: [[ReplyInline]], rows: [[[ReplyInline]]], alignments: [ReplyAlignment]) {
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
        let geometry = ReplyStyle.tableGeometry
        let contents = ReplyTableGeometry.contentWidths(headers: headers, rows: rows, fontSize: geometry.fontSize)
        self.contents = contents
        self.minimumTotal = geometry.minimumWidths(contentWidths: contents).reduce(0, +)
    }

    var body: some View {
        // Fit the viewport first; only the minimum column widths can cause overflow.
        ScrollView(.horizontal) {
            ReplyTableLayout(contents: contents, geometry: ReplyStyle.tableGeometry, columnCount: headers.count) {
                cells
            }
            .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                max(width, minimumTotal)
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    /// Header cells first, then one separator and one row of cells per data row:
    /// the order `ReplyTableLayout` walks.
    @ViewBuilder private var cells: some View {
        ForEach(Array(headers.indices), id: \.self) { column in
            cell(headers[column], column: column, header: true)
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            Rectangle().fill(.primary.opacity(0.06)).frame(height: 1)
            ForEach(Array(headers.indices), id: \.self) { column in
                cell(column < row.count ? row[column] : [], column: column, header: false)
            }
        }
    }

    private func cell(_ runs: [ReplyInline], column: Int, header: Bool) -> some View {
        ReplyText(runs: runs, size: ReplyStyle.tableCellSize, weight: header ? .medium : .regular,
                  alignment: alignments[column] == .trailing ? .trailing : alignments[column] == .center ? .center : .leading)
            .padding(.horizontal, ReplyStyle.tableGeometry.cellPadding).padding(.vertical, 8)
    }
}

/// Places cells row-major at the column totals from `ReplyTableGeometry`. Cells are
/// measured only for row height, at their final width, so a table makes fewer text
/// probes than the equal-split grid it replaces. Widths are arithmetic over content,
/// which keeps GeometryReader and state — and with them any layout feedback loop —
/// out of the transcript, matching `ReplyListLayout`.
private struct ReplyTableLayout: Layout {
    let contents: [CGFloat]
    let geometry: ReplyTableGeometry
    let columnCount: Int
    private let separatorHeight: CGFloat = 1

    struct Measurement {
        let width: CGFloat?
        let size: CGSize
        let placements: [(point: CGPoint, size: CGSize)]
    }
    func makeCache(subviews: Subviews) -> [Measurement] { [] }
    func updateCache(_ cache: inout [Measurement], subviews: Subviews) { cache.removeAll(keepingCapacity: true) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [Measurement]) -> CGSize {
        measure(width: proposal.width.flatMap { $0.isFinite ? $0 : nil }, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [Measurement]) {
        let placed = measure(width: bounds.width.isFinite ? bounds.width : nil, subviews: subviews, cache: &cache).placements
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + placed[index].point.x, y: bounds.minY + placed[index].point.y),
                                  anchor: .topLeading, proposal: ProposedViewSize(placed[index].size))
        }
    }

    /// Both passes share one bounded measurement per width, as `ReplyListLayout` does.
    private func measure(width: CGFloat?, subviews: Subviews, cache: inout [Measurement]) -> Measurement {
        if let measured = cache.first(where: { $0.width == width }) { return measured }
        let widths = geometry.columnWidths(contentWidths: contents, available: width)
        var placements: [(point: CGPoint, size: CGSize)] = Array(repeating: (.zero, .zero), count: subviews.count)
        guard columnCount > 0, widths.count == columnCount else {
            return Measurement(width: width, size: CGSize(width: width ?? 0, height: 0), placements: placements)
        }
        let total = widths.reduce(0, +)
        var height: CGFloat = 0
        var index = 0
        while index < subviews.count {
            if isSeparator(index) {
                placements[index] = (.zero, CGSize(width: total, height: separatorHeight))
                height += separatorHeight
                index += 1
                continue
            }
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            for column in 0..<columnCount {
                guard index < subviews.count else { break }
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: widths[column], height: nil))
                placements[index] = (CGPoint(x: x, y: height), CGSize(width: widths[column], height: size.height))
                rowHeight = max(rowHeight, size.height)
                x += widths[column]
                index += 1
            }
            height += rowHeight
        }
        let measured = Measurement(width: width, size: CGSize(width: width ?? widths.reduce(0, +), height: height), placements: placements)
        if cache.count == 4 { cache.removeFirst() }
        cache.append(measured)
        return measured
    }

    private func isSeparator(_ index: Int) -> Bool {
        index >= columnCount && (index - columnCount) % (columnCount + 1) == 0
    }
}
