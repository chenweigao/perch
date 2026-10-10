import AppKit
import SwiftUI
import Observation
import WorkbenchCore

/// Shared reading metrics keep Kimi, OMP and Qoder aligned with their composers.
enum ReplyStyle {
    static let readingWidth: CGFloat = 700
    static let bodySize: CGFloat = 14
    static let lineHeightRatio: CGFloat = 1.625
    static let ink = Color.primary.opacity(0.88)
    static let paper = Color.primary.opacity(0.035)
    // Preserve a dynamic color in cached attributed text. Applying alpha to
    // labelColor once can freeze the system appearance before the light window exists.
    static let nativeInk = NSColor(name: nil) { appearance in
        var ink = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { ink = NSColor.labelColor.withAlphaComponent(0.88) }
        return ink
    }
    static let tableCellSize: CGFloat = 13
    /// Column totals are arithmetic over estimated content widths, so a table
    /// never probes TextKit for widths and cannot feed the transcript layout.
    static let tableGeometry = ReplyTableGeometry(fontSize: tableCellSize)
}

enum UserMessageStyle {
    static let lineHeight: CGFloat = 20
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 8
    static let cornerRadius: CGFloat = 12
    static let maxWidthRatio: CGFloat = 0.85
    static let topSpacing: CGFloat = 10
    static let paragraphSpacing: CGFloat = 12
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
    private struct Group: Identifiable, Equatable {
        let id: Int
        let block: ReplyBlock
        var following: [[ReplyInline]] = []
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                GroupContent(group: group, compact: compact, coalescesParagraphs: coalescesParagraphs).equatable()
                    .padding(.top, group.id == 0 ? 0 : spacing(before: group.block, after: blocks[group.id - 1]))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private struct GroupContent: View, Equatable {
        let group: Group
        let compact: Bool
        let coalescesParagraphs: Bool
        @ViewBuilder var body: some View {
            if case .paragraph(let runs) = group.block {
                ReplyText(runs: runs, followingParagraphs: group.following, paragraphSpacing: compact ? 8 : 12, preservesSelectionOnAppend: coalescesParagraphs)
            } else {
                ReplyBlockContent(block: group.block, coalescesParagraphs: coalescesParagraphs).equatable()
            }
        }
    }

    private func spacing(before block: ReplyBlock, after previous: ReplyBlock?) -> CGFloat {
        if case .rule = previous { return 28 }
        if case .heading = previous { return 7 }
        if case .paragraph = previous, case .paragraph = block { return compact ? 8 : 12 }
        switch block {
        case .heading: return compact ? 14 : 22
        case .rule: return 28
        case .code: return compact ? 10 : 18
        default: return compact ? 6 : 12
        }
    }

}

/// Completed Markdown blocks preserve their view tree while the tail streams.
private struct ReplyBlockContent: View, Equatable {
    let block: ReplyBlock
    var coalescesParagraphs = ReplyParagraphLayout.enabled
    @ViewBuilder var body: some View {
        switch block {
        case .paragraph(let runs): ReplyText(runs: runs)
        case .heading(let level, let runs):
            ReplyText(runs: runs, size: level == 1 ? ReplyStyle.bodySize + 2 : ReplyStyle.bodySize,
                      weight: .medium, lineHeight: 24)
        case .code(let language, let source): ReplyCode(language: language, source: source)
        case .list(let items):
            ReplyListLayout {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(item.marker).font(.system(size: ReplyStyle.bodySize)).foregroundStyle(ReplyStyle.ink)
                            .frame(minWidth: 18, alignment: .trailing)
                        // Type erasure breaks the recursive SwiftUI view type, not the document hierarchy.
                        AnyView(ReplyBlocks(blocks: item.blocks, compact: true, coalescesParagraphs: coalescesParagraphs))
                    }
                }
            }
        case .quote(let blocks):
            AnyView(ReplyBlocks(blocks: blocks, compact: true, coalescesParagraphs: coalescesParagraphs))
                .padding(.leading, 21).padding(.vertical, 7)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.16)).frame(width: 2) }
        case .table(let headers, let rows, let alignments):
            ReplyTable(headers: headers, rows: rows, alignments: alignments)
        case .rule: Rectangle().fill(.primary.opacity(0.09)).frame(height: 1)
        }
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
                let multiline = max(rows[index - 1].height, rows[index].height) > ReplyStyle.bodySize * ReplyStyle.lineHeightRatio * 1.5
                height += multiline ? 6 : 2
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
    static let defaultValue = ReplyStyle.bodySize * ReplyStyle.lineHeightRatio
}
extension EnvironmentValues {
    var replyLineHeight: CGFloat {
        get { self[ReplyLineHeightKey.self] }
        set { self[ReplyLineHeightKey.self] = newValue }
    }
}

/// Both native user rows and SwiftUI Markdown share exact text attributes.
enum ReplyTextAttributes {
    static func paragraphs(_ paragraphs: [[ReplyInline]], size: CGFloat = ReplyStyle.bodySize,
                           weight: NSFont.Weight = .regular, alignment: TextAlignment = .leading,
                           lineHeight: CGFloat? = nil, paragraphSpacing: CGFloat = 12,
                           ink: NSColor = ReplyStyle.nativeInk) -> NSAttributedString {
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("attributed_text", since: start) }
        #endif
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight ?? size * ReplyStyle.lineHeightRatio
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
                let runWeight: NSFont.Weight = run.strong ? .medium : weight
                var font = run.code ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: runWeight)
                                    : NSFont.systemFont(ofSize: size, weight: runWeight)
                if run.emphasis { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: ink, .paragraphStyle: paragraph
                ]
                if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = ConversationFileReference(text: link.relativeString.removingPercentEncoding ?? link.relativeString)?.url ?? link }
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
        return result
    }

    /// Matches `SelectableReplyText(_:font:lineSpacing:)` so native and SwiftUI code
    /// cards measure identical text.
    static func code(_ source: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        return NSAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: ReplyStyle.nativeInk, .paragraphStyle: paragraph
        ])
    }
    /// Gutter numbers share the code font and line spacing so rows align
    /// exactly; only color and alignment differ.
    static func codeGutter(_ lines: Int) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; paragraph.alignment = .right
        let numbers = (1...max(1, lines)).map(String.init).joined(separator: "\n")
        return NSAttributedString(string: numbers, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
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
    var paragraphSpacing: CGFloat = 12
    var preservesSelectionOnAppend = false
    private var resolvedLineHeight: CGFloat { lineHeight ?? defaultLineHeight }
    private var attributed: NSAttributedString {
        ReplyTextAttributes.paragraphs([runs] + followingParagraphs, size: size, weight: weight,
                                      alignment: alignment, lineHeight: resolvedLineHeight,
                                      paragraphSpacing: paragraphSpacing, ink: ink)
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
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), url.scheme == "perch-file" else { return false }
            NotificationCenter.default.post(name: .init("PerchOpenConversationFile"), object: url)
            return true
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
final class NativeUserMessageView: NSView {
    private static var recycled: [NativeUserMessageView] = []
    private var texts: [ReplyTextView] = []
    private let links = SelectableReplyText.Coordinator()
    private let bubbleBackground = NSView()
    /// Row identity for message-level menu actions; set by the hosting controller.
    var actionContext: ConversationActionContext?
    var sourceText = ""
    /// Turn id + reading key for the bookmark menu item.
    var bookmarkTurn: String?
    var bookmarkSession: String?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if TRANSCRIPT_CHECKS
        bubbleBackground.identifier = NSUserInterfaceItemIdentifier("native-user-bubble-background")
        #endif
        bubbleBackground.wantsLayer = true
        bubbleBackground.layer?.cornerRadius = UserMessageStyle.cornerRadius
        addSubview(bubbleBackground)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func content(_ source: String) -> [NSAttributedString]? {
        NativeParagraphContent.make(source, lineHeight: UserMessageStyle.lineHeight)
    }
    static func acquire() -> NativeUserMessageView { recycled.popLast() ?? NativeUserMessageView() }
    static func recycle(_ view: NativeUserMessageView) {
        view.removeFromSuperview()
        view.actionContext = nil
        view.sourceText = ""
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
            texts.append(text); addSubview(text)
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
        return CGSize(width: width, height: UserMessageStyle.topSpacing + UserMessageStyle.verticalPadding * 2 + textHeight + gaps)
    }
    func place(width: CGFloat) {
        let layout = measurements(width: width)
        let x = width - layout.bubbleWidth
        var y = UserMessageStyle.topSpacing + UserMessageStyle.verticalPadding
        for (text, size) in zip(texts, layout.sizes) {
            let frame = CGRect(x: x + UserMessageStyle.horizontalPadding, y: y,
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
        CGSize(width: width, height: stack.contentHeight(width: width) + 12 + 24)
    }
    func place(width: CGFloat) {
        let content = stack.contentHeight(width: width)
        let stackFrame = CGRect(x: 0, y: 0, width: width, height: content)
        if stack.frame != stackFrame { stack.frame = stackFrame }
        stack.place(width: width)
        let frame = CGRect(x: 0, y: content + 12, width: actionsWidth, height: 24)
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
        let retainedSelection = preservingSelectionOnAppend && value.string.hasPrefix(storage.string) ? selectedRange() : nil
        storage.setAttributedString(value)
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
    @State private var showingAll = false
    @State private var reader = LongOutputReaderHandle()
    @Environment(\.conversationDisclosureWillChange) private var disclosureWillChange

    private var expansion: Binding<Bool> {
        Binding(get: { showingAll }, set: { value in
            disclosureWillChange()
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { showingAll = value }
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
                Text(language.isEmpty ? "代码" : language).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                ReplyCopyButton(text: source, label: "复制代码")
            }.padding(.horizontal, 14).padding(.vertical, 5)
            Rectangle().fill(.primary.opacity(0.055)).frame(height: 1)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    if lineCount > 1 {
                        SelectableReplyText(attributed: ReplyTextAttributes.codeGutter(lineCount), selectable: false)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 14)
                    }
                    SelectableReplyText(source, font: .monospacedSystemFont(ofSize: 13, weight: .regular), lineSpacing: 5)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(lineCount > 1
                                 ? EdgeInsets(top: 14, leading: 0, bottom: 14, trailing: 14)
                                 : EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
                }
            }
        }.background(ReplyStyle.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.055)))
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
            .padding(.horizontal, ReplyStyle.tableGeometry.cellPadding).padding(.vertical, 10)
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
