import AppKit
import SwiftUI
import WorkbenchCore

/// Bounded native blocks for assistant snapshots: paragraphs, headings, code cards,
/// rules, paragraph-only quotes and paragraph/list items. Tables,
/// attachments and nested content outside this set keep the SwiftUI renderer.
enum NativeAssistantBlock: Equatable {
    case paragraphs(NSAttributedString)
    /// Attributed text plus the Markdown level, which sets the spacing above it.
    case heading(level: Int, NSAttributedString)
    case code(language: String, source: String, text: NSAttributedString)
    case rule
    case quote([NSAttributedString])
    case list([NativeAssistantListItem])
}

struct NativeAssistantListItem: Equatable {
    let marker: String
    /// Only `.paragraphs` and nested `.list`; `make` rejects anything else.
    let blocks: [NativeAssistantBlock]
}

enum NativeAssistantContent {
    struct ReusePoint {
        let source: Int
        let native: Int
    }
    struct Preparation {
        let blocks: [ReplyBlock]
        let content: [NativeAssistantBlock]?
        let allowsRichBlocks: Bool
        let bodySize: CGFloat
        let reusePoints: [ReusePoint]
        let reusedBlockCount: Int

        init(blocks: [ReplyBlock], content: [NativeAssistantBlock]?, allowsRichBlocks: Bool,
             reusePoints: [ReusePoint] = [], reusedBlockCount: Int = 0) {
            self.blocks = blocks
            self.content = content
            self.allowsRichBlocks = allowsRichBlocks
            self.bodySize = ReplyStyle.bodySize
            self.reusePoints = reusePoints
            self.reusedBlockCount = reusedBlockCount
        }
    }

    /// Assistant text with bounded structure. `allowsRichBlocks` exists for
    /// acceptance A/B runs: off limits admission to paragraph groups.
    static func make(_ source: String, allowsRichBlocks: Bool = true) -> [NativeAssistantBlock]? {
        prepare(source, allowsRichBlocks: allowsRichBlocks).content
    }

    static func prepare(_ source: String, allowsRichBlocks: Bool = true) -> Preparation {
        #if TRANSCRIPT_CHECKS
        let parseStart = CACurrentMediaTime()
        let blocks = ReplyDocument.parse(source)
        NavigationRenderMetrics.record("row_parse", since: parseStart)
        NavigationRenderMetrics.count("row_parse_native_assistant")
        #else
        let blocks = ReplyDocument.parse(source)
        #endif
        return prepare(blocks: blocks, allowsRichBlocks: allowsRichBlocks)
    }

    static func prepare(blocks: [ReplyBlock], allowsRichBlocks: Bool = true) -> Preparation {
        let built = build(blocks, allowsRichBlocks: allowsRichBlocks)
        #if TRANSCRIPT_CHECKS
        if built == nil { NavigationRenderMetrics.count("row_parse_rejected") }
        #endif
        return Preparation(blocks: blocks, content: built?.blocks, allowsRichBlocks: allowsRichBlocks,
                           reusePoints: built?.reusePoints ?? [])
    }

    /// Reuse only a parser-certified complete prefix. The last visible block is
    /// deliberately excluded by the caller because a reveal can cut inside it.
    static func prepare(blocks: [ReplyBlock], allowsRichBlocks: Bool = true,
                        reusing previous: Preparation, stableBlockCount: Int) -> Preparation {
        guard stableBlockCount > 0, stableBlockCount <= previous.blocks.count,
              previous.allowsRichBlocks == allowsRichBlocks, previous.bodySize == ReplyStyle.bodySize,
              let previousContent = previous.content,
              let pointIndex = previous.reusePoints.indices.last(where: { previous.reusePoints[$0].source <= stableBlockCount })
        else { return prepare(blocks: blocks, allowsRichBlocks: allowsRichBlocks) }
        let point = previous.reusePoints[pointIndex]
        guard point.source <= blocks.count, point.native <= previousContent.count
        else { return prepare(blocks: blocks, allowsRichBlocks: allowsRichBlocks) }
        let initial = BuildResult(blocks: Array(previousContent.prefix(point.native)),
                                  reusePoints: Array(previous.reusePoints.prefix(through: pointIndex)))
        let built = build(Array(blocks.dropFirst(point.source)), allowsRichBlocks: allowsRichBlocks,
                          initial: initial, sourceOffset: point.source)
        #if TRANSCRIPT_CHECKS
        NavigationRenderMetrics.count("native_prepare_reused_blocks", by: point.native)
        NavigationRenderMetrics.count("native_prepare_rebuilt_blocks", by: max(0, (built?.blocks.count ?? 0) - point.native))
        if built == nil { NavigationRenderMetrics.count("row_parse_rejected") }
        #endif
        return Preparation(blocks: blocks, content: built?.blocks, allowsRichBlocks: allowsRichBlocks,
                           reusePoints: built?.reusePoints ?? [], reusedBlockCount: point.native)
    }

    private struct BuildResult {
        let blocks: [NativeAssistantBlock]
        let reusePoints: [ReusePoint]
    }

    private static func build(_ blocks: [ReplyBlock], allowsRichBlocks: Bool,
                              initial: BuildResult? = nil, sourceOffset: Int = 0) -> BuildResult? {
        guard !blocks.isEmpty || initial != nil else { return nil }
        var result = initial?.blocks ?? []
        var reusePoints = initial?.reusePoints ?? [ReusePoint(source: 0, native: 0)]
        var pending: [[ReplyInline]] = []
        func flush(after sourceIndex: Int) {
            guard !pending.isEmpty else { return }
            for start in stride(from: 0, to: pending.count, by: 8) {
                result.append(.paragraphs(ReplyTextAttributes.paragraphs(Array(pending[start..<min(start + 8, pending.count)]))))
            }
            pending = []
            reusePoints.append(ReusePoint(source: sourceIndex, native: result.count))
        }
        for (index, block) in blocks.enumerated() {
            let sourceIndex = sourceOffset + index
            switch block {
            case .paragraph(let runs):
                guard runs.contains(where: { !$0.text.isEmpty }) else { return nil }
                pending.append(runs)
                if pending.count == 8 { flush(after: sourceIndex + 1) }
            case .heading(let level, let runs):
                guard allowsRichBlocks else { return nil }
                flush(after: sourceIndex)
                result.append(.heading(level: level, ReplyTextAttributes.paragraphs([runs],
                    size: ReplyStyle.headingSize(level),
                    weight: ReplyStyle.headingWeight(level), lineHeight: ReplyStyle.headingLineHeight(level))))
                reusePoints.append(ReusePoint(source: sourceIndex + 1, native: result.count))
            case .code(let language, let code):
                // Mermaid renders asynchronously as a rasterized image; the
                // message keeps the SwiftUI renderer, as tables and math do.
                guard allowsRichBlocks, !MermaidSupport.isMermaid(language) else { return nil }
                flush(after: sourceIndex)
                result.append(.code(language: language, source: code, text: ReplyTextAttributes.code(code)))
                reusePoints.append(ReusePoint(source: sourceIndex + 1, native: result.count))
            case .rule:
                guard allowsRichBlocks else { return nil }
                flush(after: sourceIndex)
                result.append(.rule)
                reusePoints.append(ReusePoint(source: sourceIndex + 1, native: result.count))
            case .quote(let inner):
                guard allowsRichBlocks, let quoted = compactParagraphs(inner) else { return nil }
                flush(after: sourceIndex)
                result.append(.quote(quoted))
                reusePoints.append(ReusePoint(source: sourceIndex + 1, native: result.count))
            case .list(let items):
                guard allowsRichBlocks, let list = listItems(items, depth: 1) else { return nil }
                flush(after: sourceIndex)
                result.append(.list(list))
                reusePoints.append(ReusePoint(source: sourceIndex + 1, native: result.count))
            case .table, .math, .alert:
                return nil
            }
        }
        flush(after: sourceOffset + blocks.count)
        return result.isEmpty ? nil : BuildResult(blocks: result, reusePoints: reusePoints)
    }

    /// Quotes admit only non-empty paragraphs; compact layout uses 8pt spacing.
    private static func compactParagraphs(_ blocks: [ReplyBlock]) -> [NSAttributedString]? {
        var paragraphs: [[ReplyInline]] = []
        for block in blocks {
            guard case .paragraph(let runs) = block, runs.contains(where: { !$0.text.isEmpty }) else { return nil }
            paragraphs.append(runs)
        }
        guard !paragraphs.isEmpty else { return nil }
        return stride(from: 0, to: paragraphs.count, by: 8).map {
            ReplyTextAttributes.paragraphs(Array(paragraphs[$0..<min($0 + 8, paragraphs.count)]),
                                           paragraphSpacing: ReplyStyle.compactParagraphSpacing)
        }
    }

    private static func listItems(_ items: [ReplyListItem], depth: Int) -> [NativeAssistantListItem]? {
        guard !items.isEmpty, depth <= 4 else { return nil }
        var result: [NativeAssistantListItem] = []
        for item in items {
            var blocks: [NativeAssistantBlock] = []
            var pending: [[ReplyInline]] = []
            func flush() {
                guard !pending.isEmpty else { return }
                for start in stride(from: 0, to: pending.count, by: 8) {
                    blocks.append(.paragraphs(ReplyTextAttributes.paragraphs(Array(pending[start..<min(start + 8, pending.count)]),
                                                                             paragraphSpacing: ReplyStyle.compactParagraphSpacing)))
                }
                pending = []
            }
            for block in item.blocks {
                switch block {
                case .paragraph(let runs):
                    guard runs.contains(where: { !$0.text.isEmpty }) else { return nil }
                    pending.append(runs)
                case .list(let nested):
                    flush()
                    guard let children = listItems(nested, depth: depth + 1) else { return nil }
                    blocks.append(.list(children))
                default: return nil
                }
            }
            flush()
            guard !blocks.isEmpty else { return nil }
            result.append(NativeAssistantListItem(marker: item.marker, blocks: blocks))
        }
        return result
    }

    /// The SwiftUI renderer's rhythm (`ReplyStyle.blockSpacing`), applied above each block.
    static func spacing(before block: NativeAssistantBlock, after previous: NativeAssistantBlock?, compact: Bool) -> CGFloat {
        if case .heading(let level, _) = block, previous != nil {
            return ReplyStyle.headingTopSpacing(level, compact: compact)
        }
        return ReplyStyle.blockSpacing(before: ReplyStyle.BlockKind(block),
                                after: previous.map { ReplyStyle.BlockKind($0) }, compact: compact)
    }
}

extension ReplyStyle.BlockKind {
    init(_ block: NativeAssistantBlock) {
        switch block {
        case .paragraphs: self = .paragraph
        case .heading: self = .heading
        case .code: self = .code
        case .rule: self = .rule
        case .quote, .list: self = .other
        }
    }
}

/// The list marker font at the current body size, and the first-baseline offset
/// of a body `ReplyText` from its top, matching the SwiftUI alignment guide so
/// list markers align exactly with wrapped content. Rebuilt when the size changes.
private var nativeMarkerMetricsCache: (size: CGFloat, font: NSFont, firstBaseline: CGFloat)?
private func nativeMarkerMetrics() -> (font: NSFont, firstBaseline: CGFloat) {
    let size = ReplyStyle.bodySize
    if let cached = nativeMarkerMetricsCache, cached.size == size { return (cached.font, cached.firstBaseline) }
    let font = NSFont.systemFont(ofSize: size)
    let natural = ceil(font.ascender - font.descender + font.leading)
    let firstBaseline = ceil(font.ascender) + max(0, ReplyStyle.lineHeight - natural)
    nativeMarkerMetricsCache = (size, font, firstBaseline)
    return (font, firstBaseline)
}

/// Every block view reports its own height and lays out inside an assigned frame.
private class NativeAssistantBlockView: NSView {
    let links: SelectableReplyText.Coordinator
    override var isFlipped: Bool { true }
    init(links: SelectableReplyText.Coordinator) {
        self.links = links
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ block: NativeAssistantBlock) {}
    func contentHeight(width: CGFloat) -> CGFloat { 0 }
    func placeContent(width: CGFloat) {}
    /// Return every text view to the shared pool, cleared of content and selection.
    func teardown() {}
    func textViews() -> [ReplyTextView] { [] }
}

private final class NativeTextBlockView: NativeAssistantBlockView {
    private var text: ReplyTextView?
    override func update(_ block: NativeAssistantBlock) {
        let value: NSAttributedString
        switch block { case .paragraphs(let attributed): value = attributed
        case .heading(_, let attributed): value = attributed
        default: return }
        let text = self.text ?? {
            let view = SelectableReplyText.acquire(delegate: links)
            view.isConversationBodyText = true
            addSubview(view); self.text = view
            return view
        }()
        text.update(value, preservingSelectionOnAppend: true)
    }
    override func contentHeight(width: CGFloat) -> CGFloat { text?.measure(width: width).height ?? 0 }
    override func placeContent(width: CGFloat) {
        guard let text else { return }
        let frame = CGRect(x: 0, y: 0, width: width, height: text.measure(width: width).height)
        if text.frame != frame { text.frame = frame }
    }
    override func teardown() {
        guard let text else { return }
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.update(NSAttributedString(string: ""))
        text.removeFromSuperview()
        SelectableReplyText.recycle(text)
        self.text = nil
    }
    override func textViews() -> [ReplyTextView] { text.map { [$0] } ?? [] }
}

private final class NativeRuleBlockView: NativeAssistantBlockView {
    override func contentHeight(width: CGFloat) -> CGFloat { ReplyStyle.Rule.height }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(ReplyStyle.Rule.opacity).setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

private final class NativeCodeCardView: NativeAssistantBlockView {
    private let label = NSTextField(labelWithString: "")
    private let copy: NSHostingView<ReplyCopyButton>
    private let scroll = NSScrollView()
    private let document = NSView()
    /// Masks the viewport while the code overflows, like the SwiftUI card's
    /// `ReplyOverflowFade`: opaque, then clear across the trailing fade width.
    private let fade = CAGradientLayer()
    private var codeText: ReplyTextView?
    private var gutter: ReplyTextView?
    private var source = ""

    override init(links: SelectableReplyText.Coordinator) {
        copy = NSHostingView(rootView: ReplyCopyButton(text: "", label: "复制代码"))
        super.init(links: links)
        // DSH banner: the language label is monospace 11 in primary ink.
        label.font = .monospacedSystemFont(ofSize: ReplyStyle.Code.labelSize, weight: .regular)
        // DSH's infostring reads at full label strength.
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        copy.sizingOptions = []
        copy.safeAreaRegions = []
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        scroll.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        for view in [label, copy, scroll] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func update(_ block: NativeAssistantBlock) {
        guard case .code(let language, let source, let text) = block else { return }
        // The SwiftUI card's label: DSH leaves the slot empty when the fence
        // carries no language.
        let title = language
        if label.stringValue != title { label.stringValue = title }
        label.isHidden = title.isEmpty
        // Pooled cards outlive a body-size change.
        if label.font?.pointSize != ReplyStyle.Code.labelSize {
            label.font = .monospacedSystemFont(ofSize: ReplyStyle.Code.labelSize, weight: .regular)
        }
        if source != self.source {
            self.source = source
            copy.rootView = ReplyCopyButton(text: source, label: "复制代码", prominent: true)
        }
        let codeText = self.codeText ?? {
            let view = SelectableReplyText.acquire(delegate: links)
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
            document.addSubview(view); self.codeText = view
            return view
        }()
        codeText.update(text)
        // Like the SwiftUI card: a growing stream prefix debounces instead of
        // re-highlighting the whole block on every display frame.
        codeText.highlightCode(language: language, debounce: true)
        let lineCount = CodeLineNumbers.count(in: source)
        if lineCount > 1 {
            let gutter = self.gutter ?? {
                let view = SelectableReplyText.acquire(delegate: links)
                view.isSelectable = false
                view.textContainer?.widthTracksTextView = false
                view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude)
                document.addSubview(view); self.gutter = view
                return view
            }()
            gutter.update(ReplyTextAttributes.codeGutter(lineCount))
        } else if let gutter {
            gutter.update(NSAttributedString(string: ""))
            gutter.removeFromSuperview()
            SelectableReplyText.recycle(gutter)
            self.gutter = nil
        }
    }
    private func textSize() -> CGSize { codeText?.measure(width: nil) ?? .zero }
    private func gutterSize() -> CGSize { gutter?.measure(width: nil) ?? .zero }
    override func contentHeight(width: CGFloat) -> CGFloat {
        ReplyStyle.Code.headerHeight + textSize().height + ReplyStyle.Code.inset * 2
    }
    override func placeContent(width: CGFloat) {
        typealias Card = ReplyStyle.Code
        let text = textSize()
        let gutter = gutterSize()
        // With a gutter the code starts after it, matching the SwiftUI card;
        // without one the code keeps the plain inset.
        let codeX = gutter.width > 0 ? Card.gutterLeading + gutter.width + Card.gutterTrailing : Card.inset
        let labelSize = label.fittingSize
        let labelFrame = CGRect(x: Card.headerHorizontalPadding,
                                y: Card.headerVerticalPadding + (Card.copyButtonSize - labelSize.height) / 2,
                                width: min(labelSize.width, max(0, width - Card.headerHorizontalPadding * 2 - Card.copyButtonSize - 8)),
                                height: labelSize.height)
        if label.frame != labelFrame { label.frame = labelFrame }
        let copyY = Card.headerVerticalPadding
        let copyFrame = CGRect(x: width - Card.headerHorizontalPadding - Card.copyButtonSize, y: copyY,
                               width: Card.copyButtonSize, height: Card.copyButtonSize)
        if copy.frame != copyFrame { copy.frame = copyFrame }
        let scrollFrame = CGRect(x: 0, y: Card.headerHeight,
                                 width: width, height: text.height + Card.inset * 2)
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        let documentFrame = CGRect(x: 0, y: 0, width: codeX + text.width + Card.inset, height: text.height + Card.inset * 2)
        if document.frame != documentFrame { document.frame = documentFrame }
        updateFade(overflows: documentFrame.width > scrollFrame.width + 0.5)
        if let gutterView = self.gutter {
            let frame = CGRect(x: Card.gutterLeading, y: Card.inset, width: gutter.width, height: gutter.height)
            if gutterView.frame != frame { gutterView.frame = frame }
        }
        if let codeText {
            let frame = CGRect(x: codeX, y: Card.inset, width: text.width, height: text.height)
            if codeText.frame != frame { codeText.frame = frame }
        }
    }
    /// A layer mask on the viewport: frames and hit testing stay as they are.
    private func updateFade(overflows: Bool) {
        guard let layer = scroll.layer else { return }
        let size = scroll.bounds.size
        guard overflows, size.width > ReplyStyle.overflowFadeWidth else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        // A standalone layer animates implicitly; the fade must track the frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = CGRect(origin: .zero, size: size)
        fade.locations = [0, NSNumber(value: Double(1 - ReplyStyle.overflowFadeWidth / size.width)), 1]
        if layer.mask !== fade { layer.mask = fade }
        CATransaction.commit()
    }
    override func teardown() {
        if let gutter {
            gutter.update(NSAttributedString(string: ""))
            gutter.removeFromSuperview()
            SelectableReplyText.recycle(gutter)
            self.gutter = nil
        }
        guard let codeText else { return }
        codeText.setSelectedRange(NSRange(location: 0, length: 0))
        codeText.update(NSAttributedString(string: ""))
        codeText.removeFromSuperview()
        SelectableReplyText.recycle(codeText)
        self.codeText = nil
    }
    override func textViews() -> [ReplyTextView] { codeText.map { [$0] } ?? [] }
    override func draw(_ dirtyRect: NSRect) {
        let radius = ReplyStyle.Code.cornerRadius
        let card = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        WorkbenchTheme.replySurfaceNS.setFill()
        card.fill()
        // DSH banner strip: the card's own surface in light, a lighter
        // strip in dark; clipped to the card's rounded corners.
        NSGraphicsContext.saveGraphicsState()
        card.setClip()
        WorkbenchTheme.replyBannerNS.setFill()
        NSBezierPath.fill(CGRect(x: 0, y: 0, width: bounds.width, height: ReplyStyle.Code.headerHeight))
        WorkbenchTheme.codeHeaderDividerNS.setFill()
        NSBezierPath.fill(CGRect(x: 0, y: ReplyStyle.Code.headerHeight - 0.5, width: bounds.width, height: 0.5))
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
        border.lineWidth = 1
        WorkbenchTheme.Stroke.hairlineNS.setStroke()
        border.stroke()
    }
}

private final class NativeQuoteBlockView: NativeAssistantBlockView {
    private var texts: [ReplyTextView] = []
    override func update(_ block: NativeAssistantBlock) {
        guard case .quote(let groups) = block else { return }
        while texts.count > groups.count {
            let text = texts.removeLast()
            text.removeFromSuperview(); SelectableReplyText.recycle(text)
        }
        while texts.count < groups.count {
            let text = SelectableReplyText.acquire(delegate: links)
            text.isConversationBodyText = true
            texts.append(text); addSubview(text)
        }
        for (text, value) in zip(texts, groups) { text.update(value, preservingSelectionOnAppend: true) }
    }
    private func textWidth(_ width: CGFloat) -> CGFloat { max(1, width - ReplyStyle.Quote.leadingInset) }
    override func contentHeight(width: CGFloat) -> CGFloat {
        let content = texts.reduce(0) { $0 + $1.measure(width: textWidth(width)).height }
        return ReplyStyle.Quote.verticalInset * 2 + content
            + CGFloat(max(0, texts.count - 1)) * ReplyStyle.compactParagraphSpacing
    }
    override func placeContent(width: CGFloat) {
        var y = ReplyStyle.Quote.verticalInset
        for text in texts {
            let height = text.measure(width: textWidth(width)).height
            let frame = CGRect(x: ReplyStyle.Quote.leadingInset, y: y, width: textWidth(width), height: height)
            if text.frame != frame { text.frame = frame }
            y += height + ReplyStyle.compactParagraphSpacing
        }
    }
    override func teardown() {
        for text in texts {
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.update(NSAttributedString(string: ""))
            text.removeFromSuperview(); SelectableReplyText.recycle(text)
        }
        texts = []
    }
    override func textViews() -> [ReplyTextView] { texts }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(ReplyStyle.Quote.barOpacity).setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: ReplyStyle.Quote.barWidth, height: bounds.height),
                     xRadius: 1, yRadius: 1).fill()
    }
}

private final class NativeListBlockView: NativeAssistantBlockView {
    private final class Item {
        let marker = NSTextField(labelWithString: "")
        let content: NativeAssistantStackView
        init(links: SelectableReplyText.Coordinator) {
            content = NativeAssistantStackView(compact: true, links: links)
            marker.font = nativeMarkerMetrics().font
            marker.textColor = ReplyStyle.quietInk
            marker.alignment = .right
            marker.lineBreakMode = .byClipping
        }
    }
    private var items: [Item] = []

    override func update(_ block: NativeAssistantBlock) {
        guard case .list(let entries) = block else { return }
        while items.count > entries.count {
            let item = items.removeLast()
            item.marker.removeFromSuperview()
            item.content.teardown(); item.content.removeFromSuperview()
        }
        while items.count < entries.count {
            let item = Item(links: links)
            items.append(item); addSubview(item.marker); addSubview(item.content)
        }
        let markerFont = nativeMarkerMetrics().font
        for (item, entry) in zip(items, entries) {
            if item.marker.stringValue != entry.marker { item.marker.stringValue = entry.marker }
            if item.marker.font != markerFont { item.marker.font = markerFont }
            item.content.update(entry.blocks)
        }
    }
    private func markerWidth() -> CGFloat {
        ReplyListMetrics.columnWidth(items.map { $0.marker.stringValue })
    }
    private func rows(width: CGFloat) -> [CGFloat] {
        let contentWidth = max(1, width - markerWidth() - ReplyStyle.ListLayout.markerGap)
        let metrics = nativeMarkerMetrics()
        return items.map { max($0.content.contentHeight(width: contentWidth),
                              metrics.firstBaseline - ceil(metrics.font.ascender) + $0.marker.fittingSize.height) }
    }
    override func contentHeight(width: CGFloat) -> CGFloat {
        let rows = rows(width: width)
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            if index > 0 { height += ReplyStyle.ListLayout.itemSpacing }
            height += row
        }
        return height
    }
    override func placeContent(width: CGFloat) {
        let markerWidth = markerWidth()
        let contentWidth = max(1, width - markerWidth - ReplyStyle.ListLayout.markerGap)
        let rows = rows(width: width)
        var y: CGFloat = 0
        for (index, item) in items.enumerated() {
            if index > 0 { y += ReplyStyle.ListLayout.itemSpacing }
            let metrics = nativeMarkerMetrics()
            let markerOffset = metrics.firstBaseline - ceil(metrics.font.ascender)
            let markerSize = item.marker.fittingSize
            let markerFrame = CGRect(x: 0, y: y + markerOffset, width: markerWidth, height: markerSize.height)
            if item.marker.frame != markerFrame { item.marker.frame = markerFrame }
            let contentFrame = CGRect(x: markerWidth + ReplyStyle.ListLayout.markerGap, y: y, width: contentWidth, height: rows[index])
            if item.content.frame != contentFrame { item.content.frame = contentFrame }
            item.content.place(width: contentWidth)
            y += rows[index]
        }
    }
    override func teardown() {
        for item in items {
            item.marker.removeFromSuperview()
            item.content.teardown(); item.content.removeFromSuperview()
        }
        items = []
    }
    override func textViews() -> [ReplyTextView] { items.flatMap { $0.content.textViews() } }
}

/// A vertical stack of admitted blocks with the SwiftUI `ReplyBlocks` spacing rules.
/// Used for the assistant row body, quote contents and list item contents.
final class NativeAssistantStackView: NSView {
    private let compact: Bool
    private let links: SelectableReplyText.Coordinator
    private(set) var blocks: [NativeAssistantBlock] = []
    private var blockViews: [NativeAssistantBlockView] = []
    private var dirtyBlocks: Set<ObjectIdentifier> = []
    private var geometryWidth: CGFloat?
    private var geometryDirtyFrom: Int?
    private var placementDirtyFrom: Int?
    private var heights: [CGFloat] = []
    private var offsets: [CGFloat] = []
    private var totalHeight: CGFloat = 0
    #if TRANSCRIPT_CHECKS
    private static let incrementalGeometry = ProcessInfo.processInfo.environment["NAVIGATION_NATIVE_BODY_INCREMENTAL"] != "0"
    #else
    private static let incrementalGeometry = true
    #endif
    override var isFlipped: Bool { true }

    init(compact: Bool, links: SelectableReplyText.Coordinator) {
        self.compact = compact
        self.links = links
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeView(for block: NativeAssistantBlock) -> NativeAssistantBlockView {
        switch block {
        case .paragraphs, .heading: return NativeTextBlockView(links: links)
        case .code: return NativeCodeCardView(links: links)
        case .rule: return NativeRuleBlockView(links: links)
        case .quote: return NativeQuoteBlockView(links: links)
        case .list: return NativeListBlockView(links: links)
        }
    }
    func update(_ blocks: [NativeAssistantBlock], unchangedPrefix: Int = 0) {
        if unchangedPrefix == 0 && blocks == self.blocks { return }
        let stable = min(unchangedPrefix, blocks.count, self.blocks.count, blockViews.count)
        if stable == blocks.count && blockViews.count == blocks.count {
            self.blocks = blocks
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("native_assistant_block_stable", by: stable)
            #endif
            return
        }
        let previous = self.blocks
        let previousViewCount = blockViews.count
        var next: [NativeAssistantBlockView] = []
        var firstChange = blocks.count
        for (index, block) in blocks.enumerated() {
            if index < stable {
                next.append(blockViews[index])
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.count("native_assistant_block_stable")
                #endif
                continue
            }
            if index < blockViews.count, type(of: blockViews[index]) == makeViewType(for: block) {
                if index >= previous.count || previous[index] != block {
                    blockViews[index].update(block)
                    dirtyBlocks.insert(ObjectIdentifier(blockViews[index]))
                    firstChange = min(firstChange, index)
                    #if TRANSCRIPT_CHECKS
                    NavigationRenderMetrics.count("native_assistant_block_update")
                    #endif
                } else {
                    #if TRANSCRIPT_CHECKS
                    NavigationRenderMetrics.count("native_assistant_block_stable")
                    #endif
                }
                next.append(blockViews[index])
            } else {
                let view = makeView(for: block)
                view.update(block)
                dirtyBlocks.insert(ObjectIdentifier(view))
                firstChange = min(firstChange, index)
                next.append(view)
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.count("native_assistant_block_create")
                #endif
            }
        }
        let kept = Set(next.map { ObjectIdentifier($0) })
        for view in blockViews where !kept.contains(ObjectIdentifier(view)) {
            dirtyBlocks.remove(ObjectIdentifier(view))
            view.teardown(); view.removeFromSuperview()
        }
        if blockViews.count != next.count { firstChange = min(firstChange, next.count) }
        blockViews = next
        self.blocks = blocks
        if firstChange < blockViews.count || previousViewCount != blockViews.count || geometryDirtyFrom != nil {
            invalidateGeometry(from: firstChange)
        }
        let views = blockViews.map { $0 as NSView }
        if subviews.count != views.count || !zip(subviews, views).allSatisfy(===) {
            subviews = views
        }
    }
    private func makeViewType(for block: NativeAssistantBlock) -> NativeAssistantBlockView.Type {
        switch block {
        case .paragraphs, .heading: return NativeTextBlockView.self
        case .code: return NativeCodeCardView.self
        case .rule: return NativeRuleBlockView.self
        case .quote: return NativeQuoteBlockView.self
        case .list: return NativeListBlockView.self
        }
    }
    private func invalidateGeometry(from index: Int) {
        geometryDirtyFrom = min(geometryDirtyFrom ?? index, index)
        placementDirtyFrom = min(placementDirtyFrom ?? index, index)
    }
    private func resolveGeometry(width: CGFloat) {
        if !Self.incrementalGeometry || geometryWidth != width {
            geometryWidth = width
            geometryDirtyFrom = 0
            placementDirtyFrom = 0
        }
        guard let requested = geometryDirtyFrom else {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("native_stack_geometry_cache_hit")
            #endif
            return
        }
        let start = min(requested, blockViews.count)
        heights = Array(heights.prefix(start))
        offsets = Array(offsets.prefix(start))
        var y = start > 0 ? offsets[start - 1] + heights[start - 1] : 0
        for index in start..<blockViews.count {
            if index > 0 {
                y += NativeAssistantContent.spacing(before: blocks[index], after: blocks[index - 1], compact: compact)
            }
            offsets.append(y)
            let height = blockViews[index].contentHeight(width: width)
            heights.append(height)
            y += height
        }
        totalHeight = y
        geometryDirtyFrom = nil
        #if TRANSCRIPT_CHECKS
        NavigationRenderMetrics.count("native_stack_geometry_rebuilt_blocks", by: blockViews.count - start)
        #endif
    }
    func contentHeight(width: CGFloat) -> CGFloat {
        resolveGeometry(width: width)
        return totalHeight
    }
    func place(width: CGFloat) {
        resolveGeometry(width: width)
        let start = min(placementDirtyFrom ?? blockViews.count, blockViews.count)
        guard start < blockViews.count || !dirtyBlocks.isEmpty else {
            placementDirtyFrom = nil
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("native_stack_place_cache_hit")
            #endif
            return
        }
        for index in blockViews.indices {
            let view = blockViews[index]
            guard index >= start || dirtyBlocks.contains(ObjectIdentifier(view)) else { continue }
            let frame = CGRect(x: 0, y: offsets[index], width: width, height: heights[index])
            let sizeChanged = view.frame.size != frame.size
            if view.frame != frame { view.frame = frame }
            if sizeChanged || dirtyBlocks.contains(ObjectIdentifier(view)) {
                view.placeContent(width: width)
            }
        }
        dirtyBlocks.removeAll(keepingCapacity: true)
        placementDirtyFrom = nil
    }
    /// Return all text views to the shared pool and detach every block view.
    func teardown() {
        for view in blockViews { view.teardown(); view.removeFromSuperview() }
        blockViews = []
        blocks = []
        dirtyBlocks.removeAll(keepingCapacity: true)
        geometryWidth = nil
        geometryDirtyFrom = nil
        placementDirtyFrom = nil
        heights = []
        offsets = []
        totalHeight = 0
        subviews = []
    }
    func textViews() -> [ReplyTextView] { blockViews.flatMap { $0.textViews() } }
}
