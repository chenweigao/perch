import AppKit
import SwiftUI
import Observation
import WorkbenchCore

/// Monospaced diff with added/removed lines tinted. Colour is supplementary: the
/// original +/- markers stay in the text so the diff is readable without it. Size
/// and line spacing are the reply code style's, as for files in the same panel.
private struct DiffText: View {
    let diff: String
    init(_ diff: String) { self.diff = diff }
    var body: some View {
        SelectableReplyText(attributed: Self.attributed(diff))
    }
    static func attributed(_ diff: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = ReplyStyle.codeLineSpacing
        let font = NSFont.monospacedSystemFont(ofSize: ReplyStyle.codeSize, weight: .regular)
        let result = NSMutableAttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let colour: NSColor
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                colour = .secondaryLabelColor
            } else if line.hasPrefix("@@") {
                colour = WorkbenchTheme.diffHunk
            } else if line.hasPrefix("+") {
                colour = WorkbenchTheme.diffAdded
            } else if line.hasPrefix("-") {
                colour = WorkbenchTheme.diffRemoved
            } else {
                colour = ReplyStyle.nativeInk
            }
            result.append(NSAttributedString(string: String(line) + "\n", attributes: [
                .font: font, .foregroundColor: colour, .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}

/// File and diff text in the reply code style. The text view holds exactly the
/// source, so selection, copy, quotes and feedback all read source offsets. Line
/// numbers are a separate, unselectable column in the scroll view's vertical ruler:
/// the scroll view tiles it beside the clip view, so it scrolls vertically with the
/// code but never sideways, and no frame of ours follows the scroll position.
struct RemoteSourceText: NSViewRepresentable {
    let text: String
    let line: Int?
    var diff = false
    var numbered = false
    /// Embedded inspectors inherit their card's surface; full readers keep the
    /// native text background by default.
    var transparentBackground = false
    var onSelection: ((NSRange) -> Void)? = nil
    var initialOffset: Double? = nil
    var onSaveOffset: ((Double) -> Void)? = nil
    var findQuery = ""
    var findIndex = 0
    var sourcePath = ""
    var lineNavigation = 0
    /// Diffs carry their own line numbers in hunk headers.
    private var showsGutter: Bool { numbered && !diff }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSaveOffset: ((Double) -> Void)?
        var highlighting: CodeHighlightController?
        var search: FileSearchController?
        var text: String?
        var diff = false
        var sourcePath = ""
        var findQuery = ""
        var findIndex = 0
        var line: Int?
        var lineNavigation = 0
        var onSelection: ((NSRange) -> Void)?
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            let callback = onSelection
            DispatchQueue.main.async { callback?(range) }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.search?.cancel(); coordinator.highlighting?.reset()
        let save = coordinator.onSaveOffset, offset = Double(scroll.contentView.bounds.origin.y)
        DispatchQueue.main.async { save?(offset) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SourceScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = !transparentBackground
        // TextKit 1 from the start: sizing below and the gutter read its layout.
        let view = NSTextView(usingTextLayoutManager: false); view.isEditable = false; view.isSelectable = true
        view.drawsBackground = !transparentBackground
        view.identifier = NSUserInterfaceItemIdentifier("PerchReviewSource")
        view.delegate = context.coordinator
        let highlighting = CodeHighlightController(view: view)
        context.coordinator.highlighting = highlighting
        context.coordinator.search = FileSearchController(view: view, highlighting: highlighting)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.layoutManager?.backgroundLayoutEnabled = false
        // The vertical ruler is the gutter; the text view must not claim it.
        view.usesRuler = false
        view.textContainer?.lineFragmentPadding = 0
        // TextKit estimates the document extent and lays out only requested ranges.
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        scroll.verticalRulerView = RemoteSourceGutter(scrollView: scroll, source: view)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        scroll.drawsBackground = !transparentBackground
        view.drawsBackground = !transparentBackground
        let coordinator = context.coordinator
        coordinator.onSelection = onSelection
        coordinator.onSaveOffset = onSaveOffset
        let textChanged = coordinator.text != text || coordinator.diff != diff
        let languageChanged = coordinator.sourcePath != sourcePath
        let gutterChanged = scroll.rulersVisible != showsGutter
        let findChanged = coordinator.findQuery != findQuery || coordinator.findIndex != findIndex
        guard textChanged || languageChanged || gutterChanged || coordinator.line != line || coordinator.lineNavigation != lineNavigation || findChanged else { return }
        if textChanged {
            coordinator.text = text; coordinator.diff = diff
            view.textStorage?.setAttributedString(diff ? DiffText.attributed(text) : RemoteSourceStyle.code(text))
        }
        if textChanged || languageChanged {
            coordinator.sourcePath = sourcePath
            coordinator.highlighting?.update(source: text, language: diff ? "" : CodeLanguage.file(sourcePath))
        }
        if textChanged || gutterChanged {
            // Numbers are built once per text, and only while shown.
            if showsGutter { (scroll.verticalRulerView as? RemoteSourceGutter)?.showNumbers(for: text) }
            scroll.rulersVisible = showsGutter
            // Beside the gutter its trailing padding is the gap before the code.
            view.textContainerInset = NSSize(width: showsGutter ? 0 : RemoteSourceMetrics.inset, height: RemoteSourceMetrics.inset)
            scroll.tile()
        }
        coordinator.findQuery = findQuery; coordinator.findIndex = findIndex
        coordinator.search?.update(text: text, query: findQuery, index: findIndex)
        // Showing or hiding the numbers keeps the reader's place and selection.
        guard textChanged || coordinator.line != line || coordinator.lineNavigation != lineNavigation else { return }
        coordinator.line = line; coordinator.lineNavigation = lineNavigation
        guard let line, let range = RemoteFileContent.lineRange(in: text, line: line) else {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            if let initialOffset {
                // A new SwiftUI host has no viewport yet. Restore after native
                // sizing, just as line navigation below waits for attachment.
                DispatchQueue.main.async {
                    guard coordinator.text == text, coordinator.line == line, coordinator.lineNavigation == lineNavigation else { return }
                    scroll.layoutSubtreeIfNeeded()
                    let offset = min(max(0, initialOffset), max(0, view.frame.height - scroll.contentSize.height))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            } else { view.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
            return
        }
        view.setSelectedRange(range)
        DispatchQueue.main.async {
            guard coordinator.text == text, coordinator.line == line, coordinator.lineNavigation == lineNavigation else { return }
            view.scrollRangeToVisible(range)
        }
    }
}

/// File panel code geometry; the gutter takes the reply code card's paddings.
private enum RemoteSourceMetrics {
    /// Around the code, and before it while the gutter is hidden.
    static let inset: CGFloat = 14
}

/// The reply code and gutter styles with one fixed line height. A line set in a
/// fallback font (CJK, emoji) is otherwise taller than its number, and the two
/// columns drift apart down the file.
@MainActor enum RemoteSourceStyle {
    static let lineHeight: CGFloat = {
        guard let font = ReplyTextAttributes.code(" ").attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return 0 }
        return NSLayoutManager().defaultLineHeight(for: font)
    }()
    static func code(_ text: String) -> NSAttributedString { fixed(ReplyTextAttributes.code(text)) }
    /// Clipped, never wrapped: the column is exactly as wide as the widest number.
    static func gutter(_ lines: Int) -> NSAttributedString { fixed(ReplyTextAttributes.codeGutter(lines), clipping: true) }
    /// Lines as TextKit and `RemoteFileContent.lineRange` break them: LF, CR, CRLF,
    /// U+2028. A final terminator ends the last line instead of starting one, as in
    /// `CodeLineNumbers`, which cannot count files: CRLF is one Swift `Character`.
    static func lineCount(_ text: String) -> Int {
        let source = text as NSString
        var count = 0, location = 0
        while location < source.length {
            location = NSMaxRange(source.lineRange(for: NSRange(location: location, length: 0)))
            count += 1
        }
        return max(1, count)
    }
    private static func fixed(_ attributed: NSAttributedString, clipping: Bool = false) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let base = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        guard let style = base?.mutableCopy() as? NSMutableParagraphStyle else { return attributed }
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        if clipping { style.lineBreakMode = .byClipping }
        let result = NSMutableAttributedString(attributedString: attributed)
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// Numbers follow the source's actual visible fragments. Independent estimated
/// document heights would drift when TextKit lays out noncontiguous ranges.
final class RemoteSourceGutter: NSRulerView {
    private weak var codeView: NSTextView?
    private var numberedText: String?
    private var lineStarts = [0]
    private var attributes: [NSAttributedString.Key: Any] = [:]

    init(scrollView: NSScrollView, source: NSTextView) {
        codeView = source
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        reservedThicknessForMarkers = 0; reservedThicknessForAccessoryView = 0
        clipsToBounds = true; setAccessibilityElement(false)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    func showNumbers(for text: String) {
        guard numberedText != text else { return }
        numberedText = text; lineStarts = []
        let source = text as NSString
        var offset = 0
        while offset < source.length {
            lineStarts.append(offset)
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
        }
        if lineStarts.isEmpty { lineStarts = [0] }
        attributes = RemoteSourceStyle.gutter(1).attributes(at: 0, effectiveRange: nil)
        let widest = NSAttributedString(string: String(lineStarts.count), attributes: attributes)
        ruleThickness = ReplyStyle.Code.gutterLeading + ceil(widest.size().width) + ReplyStyle.Code.gutterTrailing
        needsDisplay = true
    }
    func lineNumber(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(1, low)
    }
    override func draw(_ dirtyRect: NSRect) {
        let area = dirtyRect.intersection(bounds)
        (codeView?.backgroundColor ?? .textBackgroundColor).setFill(); area.fill()
        guard let codeView, let layout = codeView.layoutManager, let container = codeView.textContainer else { return }
        let origin = convert(codeView.textContainerOrigin, from: codeView)
        let rows = NSRect(x: 0, y: area.minY - origin.y, width: max(1, codeView.visibleRect.width), height: area.height)
        let glyphs = layout.glyphRange(forBoundingRect: rows, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            let line = self.lineNumber(at: layout.characterIndexForGlyph(at: range.location))
            let number = NSAttributedString(string: String(line), attributes: self.attributes)
            number.draw(at: NSPoint(x: self.ruleThickness - ReplyStyle.Code.gutterTrailing - number.size().width,
                                    y: origin.y + rect.minY))
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    @objc private func clipDidScroll(_ notification: Notification) { needsDisplay = true }
}

private final class SourceScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let view = documentView as? NSTextView else { return }
        if view.minSize != contentSize { view.minSize = contentSize }
    }
}
