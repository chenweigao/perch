import AppKit
import SwiftUI
import WorkbenchCore

/// Shared reading metrics keep Kimi, OMP and Qoder aligned with their composers.
enum ReplyStyle {
    static let readingWidth: CGFloat = 700
    static let bodySize: CGFloat = 14
    static let lineHeightRatio: CGFloat = 1.625
    static let ink = Color.primary.opacity(0.88)
    static let paper = Color.primary.opacity(0.035)
}

struct KimiMarkdown: View {
    let text: String
    var body: some View { ReplyContent(text: text).equatable() }
}

/// Static history is not reparsed when the surrounding conversation streams updates.
private struct ReplyContent: View, Equatable {
    let text: String
    private var blocks: [ReplyBlock] {
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("markdown_parse", since: start) }
        #endif
        return ReplyDocument.parse(text)
    }
    var body: some View {
        ReplyBlocks(blocks: blocks)
            .foregroundStyle(ReplyStyle.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReplyBlocks: View {
    let blocks: [ReplyBlock]
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                ReplyBlockContent(block: block).equatable().padding(.top, index == 0 ? 0 : spacing(before: block, after: index > 0 ? blocks[index - 1] : nil))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                        AnyView(ReplyBlocks(blocks: item.blocks, compact: true))
                    }
                }
            }
        case .quote(let blocks):
            AnyView(ReplyBlocks(blocks: blocks, compact: true))
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
    private func measure(width: CGFloat?, subviews: Subviews) -> (size: CGSize, rows: [CGSize], offsets: [CGFloat]) {
        // SwiftUI also probes the maximum size with an infinite proposal.
        let columnWidth = width.flatMap { $0.isFinite ? $0 : nil }
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
        return (CGSize(width: columnWidth ?? rows.map(\.width).max() ?? 0, height: height), rows, offsets)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measure(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY + measured.offsets[index]),
                                  anchor: .topLeading, proposal: ProposedViewSize(measured.rows[index]))
        }
    }
}

private struct ReplyInkKey: EnvironmentKey {
    static let defaultValue = NSColor.labelColor.withAlphaComponent(0.88)
}
private extension EnvironmentValues {
    var replyInk: NSColor {
        get { self[ReplyInkKey.self] }
        set { self[ReplyInkKey.self] = newValue }
    }
}

private struct ReplyText: View {
    @Environment(\.replyInk) private var ink
    let runs: [ReplyInline]
    var size: CGFloat = ReplyStyle.bodySize
    var weight: NSFont.Weight = .regular
    var alignment: TextAlignment = .leading
    var lineHeight: CGFloat? = nil
    private var attributed: NSAttributedString {
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
        for run in runs {
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
        for (range, reference) in ConversationFileReference.matches(in: result.string) {
            if result.attribute(.link, at: range.location, effectiveRange: nil) == nil {
                result.addAttribute(.link, value: reference.url, range: range)
            }
        }
        return result
    }
    var body: some View {
        SelectableReplyText(attributed: attributed)
            .alignmentGuide(.firstTextBaseline) { _ in
                let font = NSFont.systemFont(ofSize: size)
                let naturalHeight = ceil(font.ascender - font.descender + font.leading)
                // TextKit adds minimum-line-height leading above the glyph baseline.
                return ceil(font.ascender) + max(0, (lineHeight ?? size * ReplyStyle.lineHeightRatio) - naturalHeight)
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
    init(attributed: NSAttributedString) { self.attributed = attributed }
    init(_ text: String, font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular), lineSpacing: CGFloat = 4) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing
        attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.88), .paragraphStyle: paragraph
        ])
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), url.scheme == "perch-file" else { return false }
            NotificationCenter.default.post(name: .init("PerchOpenConversationFile"), object: url)
            return true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ReplyTextView {
        // The enclosing conversation owns viewport layout; each short paragraph
        // needs selection and drawing, not another TextKit 2 viewport controller.
        let view = ReplyTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.delegate = context.coordinator
        view.enabledTextCheckingTypes = 0
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.linkTextAttributes = [.foregroundColor: NSColor(red: 0.18, green: 0.36, blue: 0.55, alpha: 1)]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: ReplyTextView, context: Context) { view.isConversationBodyText = isConversationBodyText; view.update(attributed) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReplyTextView, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}

final class ReplyTextView: NSTextView {
    var isConversationBodyText = false
    // SwiftUI alternates minimum, ideal and final width proposals. Retain those
    // sizes together; a single last-width cache remeasures unchanged history.
    private var measurements: [(width: CGFloat, size: CGSize)] = []
    func update(_ value: NSAttributedString) {
        guard let storage = textStorage, !storage.isEqual(to: value) else { return }
        storage.setAttributedString(value)
        measurements.removeAll(keepingCapacity: true)
    }
    func measure(width proposed: CGFloat?) -> CGSize {
        // A nil proposal is the ideal unwrapped width used by code and wide tables.
        let width = max(1, proposed?.isFinite == true ? proposed! : 1_000_000)
        if let cached = measurements.first(where: { $0.width == width }) { return cached.size }
        guard let storage = textStorage else { return .zero }
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("text_measure", since: start) }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                ReplyCopyButton(text: source, label: "复制代码")
            }.padding(.horizontal, 14).padding(.vertical, 5)
            Rectangle().fill(.primary.opacity(0.055)).frame(height: 1)
            ScrollView(.horizontal) {
                SelectableReplyText(source, font: .monospacedSystemFont(ofSize: 13, weight: .regular), lineSpacing: 5)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(14)
            }
        }.background(ReplyStyle.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.055)))
    }
}

private struct ReplyTable: View {
    let headers: [[ReplyInline]]
    let rows: [[[ReplyInline]]]
    let alignments: [ReplyAlignment]
    private let minimumCellWidth: CGFloat = 100
    private let cellPadding: CGFloat = 12
    var body: some View {
        // Fit the viewport first; only the minimum column widths can cause overflow.
        ScrollView(.horizontal) {
            grid.containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                max(width, CGFloat(headers.count) * (minimumCellWidth + cellPadding * 2))
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
    private var grid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            row(headers, header: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                Rectangle().fill(.primary.opacity(0.06)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                row(cells, header: false)
            }
        }
    }
    private func row(_ cells: [[ReplyInline]], header: Bool) -> some View {
        GridRow(alignment: .top) {
            ForEach(Array(headers.indices), id: \.self) { column in
                let alignment: Alignment = alignments[column] == .trailing ? .trailing : alignments[column] == .center ? .center : .leading
                ReplyText(runs: column < cells.count ? cells[column] : [], size: 13, weight: header ? .medium : .regular,
                          alignment: alignments[column] == .trailing ? .trailing : alignments[column] == .center ? .center : .leading)
                    .frame(minWidth: minimumCellWidth, maxWidth: .infinity, alignment: alignment)
                    .padding(.horizontal, cellPadding).padding(.vertical, 10)
            }
        }
    }
}
