import AppKit
import SwiftUI
import WorkbenchCore

/// Bounded native blocks for completed assistant messages: paragraphs, headings,
/// code cards, rules, paragraph-only quotes and paragraph/list items. Tables,
/// attachments and nested content outside this set keep the SwiftUI renderer.
enum NativeAssistantBlock: Equatable {
    case paragraphs(NSAttributedString)
    case heading(NSAttributedString)
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
    struct Preparation {
        let blocks: [ReplyBlock]
        let content: [NativeAssistantBlock]?
    }

    /// Completed assistant text with plain structure. `allowsRichBlocks` exists for
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
        let content = build(blocks, allowsRichBlocks: allowsRichBlocks)
        #if TRANSCRIPT_CHECKS
        if content == nil { NavigationRenderMetrics.count("row_parse_rejected") }
        #endif
        return Preparation(blocks: blocks, content: content)
    }

    private static func build(_ blocks: [ReplyBlock], allowsRichBlocks: Bool) -> [NativeAssistantBlock]? {
        guard !blocks.isEmpty else { return nil }
        var result: [NativeAssistantBlock] = []
        var pending: [[ReplyInline]] = []
        func flush() {
            guard !pending.isEmpty else { return }
            for start in stride(from: 0, to: pending.count, by: 8) {
                result.append(.paragraphs(ReplyTextAttributes.paragraphs(Array(pending[start..<min(start + 8, pending.count)]))))
            }
            pending = []
        }
        for block in blocks {
            switch block {
            case .paragraph(let runs):
                guard runs.contains(where: { !$0.text.isEmpty }) else { return nil }
                pending.append(runs)
            case .heading(let level, let runs):
                guard allowsRichBlocks else { return nil }
                flush()
                result.append(.heading(ReplyTextAttributes.paragraphs([runs],
                    size: level == 1 ? ReplyStyle.bodySize + 2 : ReplyStyle.bodySize,
                    weight: .medium, lineHeight: 24)))
            case .code(let language, let code):
                guard allowsRichBlocks else { return nil }
                flush()
                result.append(.code(language: language, source: code, text: ReplyTextAttributes.code(code)))
            case .rule:
                guard allowsRichBlocks else { return nil }
                flush(); result.append(.rule)
            case .quote(let inner):
                guard allowsRichBlocks, let quoted = compactParagraphs(inner) else { return nil }
                flush(); result.append(.quote(quoted))
            case .list(let items):
                guard allowsRichBlocks, let list = listItems(items, depth: 1) else { return nil }
                flush(); result.append(.list(list))
            case .table:
                return nil
            }
        }
        flush()
        return result.isEmpty ? nil : result
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
            ReplyTextAttributes.paragraphs(Array(paragraphs[$0..<min($0 + 8, paragraphs.count)]), paragraphSpacing: 8)
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
                    blocks.append(.paragraphs(ReplyTextAttributes.paragraphs(Array(pending[start..<min(start + 8, pending.count)]), paragraphSpacing: 8)))
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

    /// Mirrors `ReplyBlocks.spacing(before:after:)`; spacing is applied above each block.
    static func spacing(before block: NativeAssistantBlock, after previous: NativeAssistantBlock?, compact: Bool) -> CGFloat {
        guard let previous else { return 0 }
        if case .rule = previous { return 28 }
        if case .heading = previous { return 7 }
        if case .paragraphs = previous, case .paragraphs = block { return compact ? 8 : 12 }
        switch block {
        case .heading: return compact ? 14 : 22
        case .rule: return 28
        case .code: return compact ? 10 : 18
        default: return compact ? 6 : 12
        }
    }
}

private let nativeMarkerFont = NSFont.systemFont(ofSize: ReplyStyle.bodySize)
/// First-baseline offset of a body `ReplyText` from its top, matching the SwiftUI
/// alignment guide so list markers align exactly with wrapped content.
private let nativeContentFirstBaseline: CGFloat = {
    let natural = ceil(nativeMarkerFont.ascender - nativeMarkerFont.descender + nativeMarkerFont.leading)
    return ceil(nativeMarkerFont.ascender) + max(0, ReplyStyle.bodySize * ReplyStyle.lineHeightRatio - natural)
}()

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
        case .heading(let attributed): value = attributed
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
    override func contentHeight(width: CGFloat) -> CGFloat { 1 }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

private final class NativeCodeCardView: NativeAssistantBlockView {
    private let label = NSTextField(labelWithString: "")
    private let copy: NSHostingView<ReplyCopyButton>
    private let separator = NSView()
    private let scroll = NSScrollView()
    private let document = NSView()
    private var codeText: ReplyTextView?
    private var gutter: ReplyTextView?
    private var language = ""
    private var source = ""

    override init(links: SelectableReplyText.Coordinator) {
        copy = NSHostingView(rootView: ReplyCopyButton(text: "", label: "复制代码"))
        super.init(links: links)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        copy.sizingOptions = []
        copy.safeAreaRegions = []
        separator.wantsLayer = true
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        for view in [label, copy, separator, scroll] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func update(_ block: NativeAssistantBlock) {
        guard case .code(let language, let source, let text) = block else { return }
        if language != self.language { self.language = language; label.stringValue = language.isEmpty ? "代码" : language }
        if source != self.source {
            self.source = source
            copy.rootView = ReplyCopyButton(text: source, label: "复制代码")
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
    override func contentHeight(width: CGFloat) -> CGFloat { 34 + 1 + textSize().height + 28 }
    override func placeContent(width: CGFloat) {
        let text = textSize()
        let gutter = gutterSize()
        let codeX = 14 + (gutter.width > 0 ? gutter.width + 8 : 0)
        let labelSize = label.fittingSize
        let labelFrame = CGRect(x: 14, y: 5 + (24 - labelSize.height) / 2,
                                width: min(labelSize.width, max(0, width - 14 - 14 - 24 - 8)), height: labelSize.height)
        if label.frame != labelFrame { label.frame = labelFrame }
        let copyFrame = CGRect(x: width - 14 - 24, y: 5, width: 24, height: 24)
        if copy.frame != copyFrame { copy.frame = copyFrame }
        let separatorFrame = CGRect(x: 0, y: 34, width: width, height: 1)
        if separator.frame != separatorFrame { separator.frame = separatorFrame }
        separator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        let scrollFrame = CGRect(x: 0, y: 35, width: width, height: text.height + 28)
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        let documentFrame = CGRect(x: 0, y: 0, width: codeX + text.width + 14, height: text.height + 28)
        if document.frame != documentFrame { document.frame = documentFrame }
        if let gutterView = self.gutter {
            let frame = CGRect(x: 12, y: 14, width: gutter.width, height: gutter.height)
            if gutterView.frame != frame { gutterView.frame = frame }
        }
        if let codeText {
            let frame = CGRect(x: codeX, y: 14, width: text.width, height: text.height)
            if codeText.frame != frame { codeText.frame = frame }
        }
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
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor.labelColor.withAlphaComponent(0.055).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
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
    private func textWidth(_ width: CGFloat) -> CGFloat { max(1, width - 21) }
    override func contentHeight(width: CGFloat) -> CGFloat {
        let content = texts.reduce(0) { $0 + $1.measure(width: textWidth(width)).height }
        return 14 + content + CGFloat(max(0, texts.count - 1)) * 8
    }
    override func placeContent(width: CGFloat) {
        var y: CGFloat = 7
        for text in texts {
            let height = text.measure(width: textWidth(width)).height
            let frame = CGRect(x: 21, y: y, width: textWidth(width), height: height)
            if text.frame != frame { text.frame = frame }
            y += height + 8
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
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 2, height: bounds.height), xRadius: 1, yRadius: 1).fill()
    }
}

private final class NativeListBlockView: NativeAssistantBlockView {
    private final class Item {
        let marker = NSTextField(labelWithString: "")
        let content: NativeAssistantStackView
        init(links: SelectableReplyText.Coordinator) {
            content = NativeAssistantStackView(compact: true, links: links)
            marker.font = nativeMarkerFont
            marker.textColor = ReplyStyle.nativeInk
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
        for (item, entry) in zip(items, entries) {
            if item.marker.stringValue != entry.marker { item.marker.stringValue = entry.marker }
            item.content.update(entry.blocks)
        }
    }
    private func markerWidth() -> CGFloat {
        items.map { $0.marker.fittingSize.width }.max().map { max(18, ceil($0)) } ?? 18
    }
    private func rows(width: CGFloat) -> [CGFloat] {
        let contentWidth = max(1, width - markerWidth() - 9)
        return items.map { max($0.content.contentHeight(width: contentWidth),
                              nativeContentFirstBaseline - nativeMarkerFont.ascender + $0.marker.fittingSize.height) }
    }
    override func contentHeight(width: CGFloat) -> CGFloat {
        let rows = rows(width: width)
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let multiline = max(rows[index - 1], row) > ReplyStyle.bodySize * ReplyStyle.lineHeightRatio * 1.5
                height += multiline ? 6 : 2
            }
            height += row
        }
        return height
    }
    override func placeContent(width: CGFloat) {
        let markerWidth = markerWidth()
        let contentWidth = max(1, width - markerWidth - 9)
        let rows = rows(width: width)
        var y: CGFloat = 0
        for (index, item) in items.enumerated() {
            if index > 0 {
                let multiline = max(rows[index - 1], rows[index]) > ReplyStyle.bodySize * ReplyStyle.lineHeightRatio * 1.5
                y += multiline ? 6 : 2
            }
            let markerOffset = nativeContentFirstBaseline - nativeMarkerFont.ascender
            let markerSize = item.marker.fittingSize
            let markerFrame = CGRect(x: 0, y: y + markerOffset, width: markerWidth, height: markerSize.height)
            if item.marker.frame != markerFrame { item.marker.frame = markerFrame }
            let contentFrame = CGRect(x: markerWidth + 9, y: y, width: contentWidth, height: rows[index])
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
    func update(_ blocks: [NativeAssistantBlock]) {
        guard blocks != self.blocks else { return }
        self.blocks = blocks
        var next: [NativeAssistantBlockView] = []
        for (index, block) in blocks.enumerated() {
            if index < blockViews.count, type(of: blockViews[index]) == makeViewType(for: block) {
                blockViews[index].update(block)
                next.append(blockViews[index])
            } else {
                let view = makeView(for: block)
                view.update(block)
                next.append(view)
            }
        }
        let kept = Set(next.map { ObjectIdentifier($0) })
        for view in blockViews where !kept.contains(ObjectIdentifier(view)) {
            view.teardown(); view.removeFromSuperview()
        }
        blockViews = next
        subviews = blockViews.map { $0 as NSView }
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
    func contentHeight(width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        for (index, view) in blockViews.enumerated() {
            if index > 0 {
                height += NativeAssistantContent.spacing(before: blocks[index], after: blocks[index - 1], compact: compact)
            }
            height += view.contentHeight(width: width)
        }
        return height
    }
    func place(width: CGFloat) {
        var y: CGFloat = 0
        for (index, view) in blockViews.enumerated() {
            if index > 0 {
                y += NativeAssistantContent.spacing(before: blocks[index], after: blocks[index - 1], compact: compact)
            }
            let height = view.contentHeight(width: width)
            let frame = CGRect(x: 0, y: y, width: width, height: height)
            if view.frame != frame { view.frame = frame }
            view.placeContent(width: width)
            y += height
        }
    }
    /// Return all text views to the shared pool and detach every block view.
    func teardown() {
        for view in blockViews { view.teardown(); view.removeFromSuperview() }
        blockViews = []
        blocks = []
        subviews = []
    }
    func textViews() -> [ReplyTextView] { blockViews.flatMap { $0.textViews() } }
}
