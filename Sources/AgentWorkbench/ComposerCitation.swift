import AppKit

/// View data only. The connection's existing paste store owns the full quote;
/// the native attachment occupies one editing character and serializes its token.
struct ComposerCitation {
    let token: String
    let label: String
    let missingMessage: String
    let load: () -> String?
}

final class ComposerCitationAttachment: NSTextAttachment {
    var citation: ComposerCitation
    init(_ citation: ComposerCitation) {
        self.citation = citation
        super.init(data: nil, ofType: nil)
        attachmentCell = ComposerCitationCell(textCell: citation.label)
    }
    required init?(coder: NSCoder) { return nil }
}

final class ComposerCitationCell: NSTextAttachmentCell {
    var maximumWidth = WorkbenchTheme.Composer.Citation.maximumWidth
    private var titleFont: NSFont { .systemFont(ofSize: WorkbenchTheme.Composer.Citation.textSize) }
    override func cellSize() -> NSSize {
        let titleWidth = (stringValue as NSString).size(withAttributes: [.font: titleFont]).width
        return NSSize(width: min(maximumWidth, ceil(titleWidth) + 49), height: WorkbenchTheme.Composer.Citation.height)
    }
    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: (NSFont.systemFont(ofSize: WorkbenchTheme.Reading.bodySize).xHeight - cellSize().height) / 2)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let frame = cellFrame.insetBy(dx: 2, dy: 0)
        WorkbenchTheme.Composer.Citation.fill.setFill()
        let radius = WorkbenchTheme.Composer.Citation.cornerRadius
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        drawSymbol("doc.text", size: 13, in: NSRect(x: frame.minX + 6, y: frame.midY - 6.5, width: 13, height: 13))
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let titleHeight = titleFont.ascender - titleFont.descender
        (stringValue as NSString).draw(in: NSRect(x: frame.minX + 23, y: frame.midY - titleHeight / 2,
                                                width: max(0, frame.width - 45), height: titleHeight),
                                      withAttributes: [.font: titleFont, .foregroundColor: WorkbenchTheme.Composer.Citation.text,
                                                       .paragraphStyle: style])
        drawSymbol("xmark", size: 11, in: NSRect(x: frame.maxX - 16.5, y: frame.midY - 5.5, width: 11, height: 11))
    }
    private func drawSymbol(_ name: String, size: CGFloat, in rect: NSRect) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return }
        let tinted = NSImage(size: rect.size, flipped: true) { bounds in
            image.draw(in: bounds)
            WorkbenchTheme.Composer.Citation.muted.setFill()
            bounds.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension DraftTextView {
    private var citationRuns: [(ComposerCitationAttachment, NSRange)] {
        guard let storage = textStorage else { return [] }
        var result: [(ComposerCitationAttachment, NSRange)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? ComposerCitationAttachment { result.append((attachment, range)) }
        }
        return result
    }

    /// Persistence, completion offsets and submission use the original draft,
    /// never AppKit's object-replacement character or a rendered chip label.
    var draftString: String {
        var value = string as NSString
        for (attachment, range) in citationRuns.reversed() {
            value = value.replacingCharacters(in: range, with: attachment.citation.token) as NSString
        }
        return value as String
    }

    var draftSelection: NSRange {
        let selection = selectedRange()
        func offset(_ index: Int) -> Int {
            index + citationRuns.filter { NSMaxRange($0.1) <= index }
                .reduce(0) { $0 + ($1.0.citation.token as NSString).length - $1.1.length }
        }
        let start = offset(selection.location)
        return NSRange(location: start, length: offset(NSMaxRange(selection)) - start)
    }

    func displaySelection(_ selection: NSRange) -> NSRange {
        func offset(_ index: Int, end: Bool) -> Int {
            var removed = 0
            for (attachment, range) in citationRuns {
                let start = range.location + removed, length = (attachment.citation.token as NSString).length
                if index <= start { break }
                if index < start + length { return range.location + (end ? range.length : 0) }
                removed += length - range.length
            }
            return max(0, index - removed)
        }
        let start = offset(selection.location, end: false)
        return NSRange(location: start, length: offset(NSMaxRange(selection), end: selection.length > 0) - start)
    }

    func renderDraft(_ value: String) -> NSAttributedString {
        let source = value as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: WorkbenchTheme.Reading.bodySize),
                                                       .foregroundColor: NSColor.labelColor]
        let result = NSMutableAttributedString(string: value, attributes: attributes)
        let references = Dictionary(citations.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        var matches: [(ComposerCitation, NSRange)] = []
        for reference in references.values {
            var remaining = NSRange(location: 0, length: source.length)
            while remaining.length > 0 {
                let range = source.range(of: reference.token, options: [], range: remaining)
                guard range.location != NSNotFound else { break }
                matches.append((reference, range))
                remaining = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
            }
        }
        for (reference, range) in matches.sorted(by: { $0.1.location > $1.1.location }) {
            let replacement = NSMutableAttributedString(attachment: ComposerCitationAttachment(reference))
            replacement.addAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
            result.replaceCharacters(in: range, with: replacement)
        }
        return result
    }

    func updateCitationWidths() {
        let width = min(WorkbenchTheme.Composer.Citation.maximumWidth, max(49, bounds.width - textContainerInset.width * 2))
        for (attachment, range) in citationRuns {
            guard let cell = attachment.attachmentCell as? ComposerCitationCell, cell.maximumWidth != width else { continue }
            cell.maximumWidth = width
            layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    func refreshCitationLabels() {
        for (attachment, range) in citationRuns {
            guard let current = citations.first(where: { $0.token == attachment.citation.token }),
                  let cell = attachment.attachmentCell as? ComposerCitationCell else { continue }
            attachment.citation = current
            guard cell.stringValue != current.label else { continue }
            cell.stringValue = current.label
            layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            needsDisplay = true
        }
    }

    var citationFrames: [(NSRange, NSRect)] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        layout.ensureLayout(for: container)
        return citationRuns.map { _, range in
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var frame = layout.boundingRect(forGlyphRange: glyphs, in: container)
            frame.origin.x += textContainerOrigin.x; frame.origin.y += textContainerOrigin.y
            return (range, frame)
        }
    }

    func activateCitation(at point: NSPoint) -> Bool {
        guard isEditable, !hasMarkedText(), let (range, frame) = citationFrames.first(where: { $0.1.contains(point) }),
              let attachment = textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil) as? ComposerCitationAttachment else { return false }
        window?.makeFirstResponder(self)
        if point.x >= frame.maxX - 20 {
            let selection = selectedRange()
            insertText("", replacementRange: range)
            func adjusted(_ index: Int) -> Int { index <= range.location ? index : max(range.location, index - range.length) }
            let start = adjusted(selection.location)
            setSelectedRange(NSRange(location: start, length: adjusted(NSMaxRange(selection)) - start))
        } else {
            guard let content = attachment.citation.load() else { onError?(attachment.citation.missingMessage); return true }
            insertText(content, replacementRange: range)
        }
        return true
    }

    /// Copy exports the selected context itself, never an attachment marker.
    func citationSelectionText() -> String {
        let selection = selectedRange()
        var value = (string as NSString).substring(with: selection) as NSString
        for (attachment, range) in citationRuns.reversed() where NSIntersectionRange(selection, range).length > 0 {
            let local = NSRange(location: range.location - selection.location, length: range.length)
            value = value.replacingCharacters(in: local, with: attachment.citation.load() ?? attachment.citation.label) as NSString
        }
        return value as String
    }
}
