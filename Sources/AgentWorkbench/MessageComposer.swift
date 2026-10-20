import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension URL {
    /// Image files keep the attachment pipeline; everything else can become a
    /// @-reference when the composer offers one.
    var isImageFile: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) ?? false
    }
}

/// Keys the composer hands to an attached palette before acting on them itself.
/// Kept minimal so the composer stays a text editor rather than a menu host.
/// Arrows say whether the caret is on the draft's first (Up) or last (Down)
/// visual line: suggestion lists move either way, while prompt recall leaves the
/// draft only from that edge line so the caret can move through the text.
enum ComposerKey: Equatable { case up(fromFirstLine: Bool), down(fromLastLine: Bool), enter, tab, escape }


/// AppKit owns the editing buffer while the input method is composing. Streaming
/// updates may refresh SwiftUI, but must never replace marked text with a draft.
struct MessageComposer: View {
    @Binding var text: String
    var placeholder = "Continue this task…"
    var accessibilityLabel = "Message"
    var canSend: Bool
    var onSend: () -> Void
    /// The next-turn send that ⌘Return takes while a turn runs. Nil keeps
    /// ⌘Return the same as Return.
    var onQueue: (() -> Void)? = nil
    var onFiles: (([URL]) -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    /// Local projects turn pasted non-image files into @-references at the caret.
    var fileReference: ((URL) -> String?)? = nil
    /// Lets an attached suggestion list claim navigation keys. Returning false leaves
    /// the key to normal editing, so the composer stays a text editor.
    var onKey: ((ComposerKey) -> Bool)? = nil
    /// Long plain-text pastes hand their content here; a returned token is
    /// inserted instead of the full text.
    var onLongPaste: ((String) -> String?)? = nil
    var onEditSelection: ((String, NSRange) -> Void)? = nil
    var selectionAfterReplacement: NSRange? = nil
    var minimumHeight: CGFloat = 40
    @State private var height: CGFloat = 40

    var body: some View {
        ComposerEditor(text: $text, height: $height, placeholder: placeholder,
                       accessibilityLabel: accessibilityLabel, canSend: canSend,
                       onSend: onSend, onFiles: onFiles, onError: onError, onKey: onKey, onQueue: onQueue, onLongPaste: onLongPaste, fileReference: fileReference, onEditSelection: onEditSelection, selectionAfterReplacement: selectionAfterReplacement, minimumHeight: minimumHeight)
            .frame(height: max(minimumHeight, height))
    }
}

struct ComposerEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let accessibilityLabel: String
    let canSend: Bool
    let onSend: () -> Void
    let onFiles: (([URL]) -> Void)?
    let onError: ((String) -> Void)?
    let onKey: ((ComposerKey) -> Bool)?
    var onQueue: (() -> Void)? = nil
    var onLongPaste: ((String) -> String?)? = nil
    var fileReference: ((URL) -> String?)? = nil

    var onEditSelection: ((String, NSRange) -> Void)? = nil
    var selectionAfterReplacement: NSRange? = nil

    var minimumHeight: CGFloat = 40

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = DraftTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.syncDraft(text)
        editor.placeholder = placeholder
        editor.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = editor
        context.coordinator.editor = editor
        context.coordinator.observeFocus()
        editor.onLayout = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        updateNSView(scroll, context: context)
        DispatchQueue.main.async { [weak editor] in
            guard let editor else { return }
            if editor.isEditable { editor.window?.makeFirstResponder(editor) }
            context.coordinator.measure()
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = coordinator.editor else { return }
        editor.minSize = NSSize(width: 0, height: minimumHeight)
        editor.isEditable = isEnabled
        editor.canSend = canSend && isEnabled
        editor.placeholder = placeholder
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.onSend = onSend
        editor.onFiles = onFiles
        editor.onError = onError
        editor.onKey = onKey
        editor.onQueue = onQueue
        editor.onLongPaste = onLongPaste
        editor.fileReference = fileReference
        editor.syncDraft(text, selection: selectionAfterReplacement)
        coordinator.measure()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        weak var editor: DraftTextView?
        private var focusObserver: NSObjectProtocol?
        init(_ parent: ComposerEditor) { self.parent = parent }
        deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
        func observeFocus() {
            focusObserver = NotificationCenter.default.addObserver(forName: .init("PerchFocusComposer"), object: nil, queue: .main) { [weak self] _ in
                guard let editor = self?.editor, editor.isEditable, !editor.isHiddenOrHasHiddenAncestor,
                      let window = editor.window, window.isKeyWindow else { return }
                window.makeFirstResponder(editor)
            }
        }
        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            // Only committed input enters SwiftUI's draft. The marked range stays
            // entirely inside NSTextView until the input method finishes it.
            if !editor.hasMarkedText(), parent.text != editor.string { parent.text = editor.string }
            editor.needsDisplay = true
            publishSelection()
            measure()
        }
        func textViewDidChangeSelection(_ notification: Notification) { publishSelection() }
        private func publishSelection() {
            guard let editor, !editor.hasMarkedText(), let callback = parent.onEditSelection else { return }
            let text = editor.string, range = editor.selectedRange()
            DispatchQueue.main.async { callback(text, range) }
        }
        func measure() {
            guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let measured = max(parent.minimumHeight, min(180, ceil(layout.usedRect(for: container).height + 8)))
            guard measured != parent.height else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.height != measured else { return }
                self.parent.height = measured
            }
        }
    }
}

final class DraftTextView: NSTextView {
    private let draftUndoManager = UndoManager()
    override var undoManager: UndoManager? { draftUndoManager }
    /// Follows the run state (it says what Return does), so a change redraws an
    /// empty draft and reaches VoiceOver, which cannot see the drawn text.
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            if string.isEmpty { needsDisplay = true }
        }
    }
    var canSend = false
    var onSend: (() -> Void)?
    /// ⌘Return's next-turn send; nil sends ⌘Return through `onSend`.
    var onQueue: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onError: ((String) -> Void)?
    var onLayout: (() -> Void)?
    var onKey: ((ComposerKey) -> Bool)?
    var onLongPaste: ((String) -> String?)?
    /// Non-image pasted/dropped files become this reference token at the caret
    /// instead of an attachment (local projects); nil keeps everything as
    /// attachments (remote hosts, where a local path is meaningless).
    var fileReference: ((URL) -> String?)?

    func syncDraft(_ value: String, selection: NSRange? = nil) {
        guard !hasMarkedText(), string != value else { return }
        string = value
        // Programmatic replacements are a completed send, quote, or completion.
        // Resume typing after the replacement; undo must not revive a sent draft.
        setSelectedRange(selection ?? NSRange(location: (value as NSString).length, length: 0))
        undoManager?.removeAllActions()
        needsDisplay = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout?()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: 0, y: 4), withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }
    /// Returns false during composition so Return stays with the input method.
    /// ⌘Return takes the next-turn send when there is one, otherwise the same send
    /// as Return; either way one key press calls exactly one of them.
    func handleReturn(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == 36 || keyCode == 76 else { return false }
        guard isEditable, !hasMarkedText() else { return false }
        if modifiers.contains(.shift) || modifiers.contains(.option) { return false }
        guard canSend else { return true }
        if modifiers.contains(.command), let onQueue { onQueue() } else { onSend?() }
        return true
    }
    /// Whether an empty-selection caret is on the draft's first and last visual
    /// lines, read from this view's layout so a soft-wrapped line counts as a line.
    /// An empty draft is on both; a selection is on neither. The composer lays out
    /// with TextKit 1: `Coordinator.measure()` reads `layoutManager`, which moves
    /// an NSTextView out of TextKit 2, and this reads the same layout manager.
    func caretLine() -> (isFirst: Bool, isLast: Bool) {
        let text = string as NSString
        guard text.length > 0 else { return (true, true) }
        let caret = selectedRange()
        guard caret.length == 0 else { return (false, false) }
        guard let layout = layoutManager, let container = textContainer else { return (true, true) }
        layout.ensureLayout(for: container)
        let glyphs = layout.numberOfGlyphs
        guard glyphs > 0 else { return (true, true) }
        // A final line break leaves an empty extra line below the last glyph.
        let endsWithEmptyLine = layout.extraLineFragmentTextContainer != nil
        if caret.location >= text.length && endsWithEmptyLine { return (false, true) }
        // The caret is on the line of the character after it. At the end of the
        // text, and upstream at a soft wrap (drawn at the end of the earlier line),
        // it is on the line of the character before it.
        var character = min(caret.location, text.length - 1)
        if caret.location > 0 && caret.location < text.length && selectionAffinity == .upstream {
            let previous = Unicode.Scalar(text.character(at: caret.location - 1))
            let afterLineBreak = previous.map { CharacterSet.newlines.contains($0) } ?? false
            if !afterLineBreak { character = caret.location - 1 }
        }
        var line = NSRange(location: 0, length: 0)
        _ = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: &line)
        return (line.location == 0, !endsWithEmptyLine && NSMaxRange(line) >= glyphs)
    }
    /// An attached suggestion list sees navigation keys first, but never while the
    /// input method is composing, so Return still commits Chinese text.
    func handleNavigation(_ event: NSEvent) -> Bool {
        guard isEditable, let onKey, !hasMarkedText() else { return false }
        // Arrow events include numericPad/function; Caps Lock is not a shortcut.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 126: return onKey(.up(fromFirstLine: caretLine().isFirst))
        case 125: return onKey(.down(fromLastLine: caretLine().isLast))
        case 36, 76: return onKey(.enter)
        case 48: return onKey(.tab)
        case 53: return onKey(.escape)
        default: return false
        }
    }
    override func keyDown(with event: NSEvent) {
        if handleNavigation(event) { return }
        if handleReturn(keyCode: event.keyCode, modifiers: event.modifierFlags) { return }
        super.keyDown(with: event)
    }
    // AppKit validates Paste before dispatching it. Plain-text editors must
    // advertise attachment types as well as implement how to read them.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        guard isEditable, onFiles != nil else { return super.readablePasteboardTypes }
        return [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }
    override func readSelection(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard isEditable else { return false }
        // Plain text arrives under either the modern or the legacy type name.
        if (type == .string || type.rawValue == "NSStringPboardType"), let onLongPaste,
           let text = board.string(forType: .string), let token = onLongPaste(text) {
            insertText(token, replacementRange: selectedRange())
            return true
        }
        guard let onFiles else { return super.readSelection(from: board, type: type) }
        if type == .fileURL,
           let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // Paste and drop share this route (ccgui clipboard parity): images
            // enter the attachment pipeline, other files become @-references
            // when the composer offers fileReference, else attach as before.
            var attached: [URL] = []
            var referenced = false
            for url in urls {
                if !url.isImageFile, let token = fileReference?(url) {
                    insertText(token, replacementRange: selectedRange())
                    referenced = true
                } else {
                    attached.append(url)
                }
            }
            if !attached.isEmpty { onFiles(attached) }
            if referenced || !attached.isEmpty { return true }
        }
        if type == .png || type == .tiff,
           let data = board.data(forType: type),
           let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            do { onFiles([try ComposerAttachments.saveImageToTemp(png)]) }
            catch { onError?(error.localizedDescription) }
            return true
        }
        return super.readSelection(from: board, type: type)
    }
}

/// Shared attachment helpers: pasted images get readable names, and additions
/// are validated before they reach a connection's upload path.
enum ComposerAttachments {
    static let maximumAttachmentBytes = 200 * 1024 * 1024
    static func saveImageToTemp(_ png: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentWorkbenchAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
        let file = folder.appendingPathComponent("pasted-image-\(stamp)-\(UUID().uuidString.prefix(4)).png")
        try png.write(to: file, options: .atomic)
        return file
    }
    /// Returns the localization key of a refusal reason, or nil when the file can
    /// be attached. This file compiles without WorkbenchCore (scripts/check-composer.sh),
    /// so callers look the key up with `L(key:)`.
    static func refusal(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return "Only regular files can be attached." }
        if let size = values.fileSize, size > maximumAttachmentBytes {
            return "Files over 200 MB cannot be uploaded as attachments."
        }
        return nil
    }
}

struct ComposerAttachment: View {
    let file: URL
    let onRemove: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?
    /// Decoding is keyed on the file and the display, not on draft edits: a
    /// keystroke must never re-read or re-decode the attachment.
    private struct ThumbnailRequest: Equatable {
        let file: URL
        let scale: CGFloat
    }
    var body: some View {
        HStack(spacing: 8) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else { Image(systemName: "doc").frame(width: 30, height: 34).foregroundStyle(.secondary) }
            Text(file.lastPathComponent).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 130)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove attachment")
                .accessibilityLabel("Remove attachment")
        }.padding(6).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .task(id: ThumbnailRequest(file: file, scale: displayScale)) {
                guard file.isImageFile else { return }
                // Full screenshots decode in tens of milliseconds; keep that off
                // the typing path and bound the bitmap to the chip's size.
                thumbnail = try? await AttachmentImageDecoder.shared.image(url: file, maxPixels: 38 * 2 * displayScale)
            }
    }
}
