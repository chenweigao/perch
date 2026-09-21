import AppKit
import SwiftUI

/// AppKit owns the editing buffer while the input method is composing. Streaming
/// updates may refresh SwiftUI, but must never replace marked text with a draft.
struct MessageComposer: View {
    @Binding var text: String
    var placeholder = "继续这个任务，或提出新的想法…"
    var accessibilityLabel = "消息"
    var canSend: Bool
    var onSend: () -> Void
    var onFiles: (([URL]) -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    /// Lets an attached suggestion list claim navigation keys. Returning false leaves
    /// the key to normal editing, so the composer stays a text editor.
    var onKey: ((ComposerKey) -> Bool)? = nil
    @State private var height: CGFloat = 40

    var body: some View {
        ComposerEditor(text: $text, height: $height, placeholder: placeholder,
                       accessibilityLabel: accessibilityLabel, canSend: canSend,
                       onSend: onSend, onFiles: onFiles, onError: onError, onKey: onKey)
            .frame(height: height)
    }
}

struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let accessibilityLabel: String
    let canSend: Bool
    let onSend: () -> Void
    let onFiles: (([URL]) -> Void)?
    let onError: ((String) -> Void)?
    let onKey: ((ComposerKey) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = DraftTextView(frame: .zero)
        editor.isRichText = false
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
        editor.string = text
        editor.placeholder = placeholder
        editor.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = editor
        context.coordinator.editor = editor
        editor.onLayout = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        updateNSView(scroll, context: context)
        DispatchQueue.main.async { [weak editor] in
            guard let editor else { return }
            editor.window?.makeFirstResponder(editor)
            context.coordinator.measure()
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = coordinator.editor else { return }
        editor.canSend = canSend
        editor.onSend = onSend
        editor.onFiles = onFiles
        editor.onError = onError
        editor.onKey = onKey
        editor.syncDraft(text)
        coordinator.measure()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        weak var editor: DraftTextView?
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            // Only committed input enters SwiftUI's draft. The marked range stays
            // entirely inside NSTextView until the input method finishes it.
            if !editor.hasMarkedText(), parent.text != editor.string { parent.text = editor.string }
            editor.needsDisplay = true
            measure()
        }
        func measure() {
            guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let measured = min(180, max(40, ceil(layout.usedRect(for: container).height + 8)))
            guard measured != parent.height else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.height != measured else { return }
                self.parent.height = measured
            }
        }
    }
}

final class DraftTextView: NSTextView {
    var placeholder = ""
    var canSend = false
    var onSend: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onError: ((String) -> Void)?
    var onLayout: (() -> Void)?
    var onKey: ((ComposerKey) -> Bool)?

    func syncDraft(_ value: String) {
        guard !hasMarkedText(), string != value else { return }
        string = value
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
    func handleReturn(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == 36 || keyCode == 76 else { return false }
        guard !hasMarkedText() else { return false }
        if modifiers.contains(.shift) || modifiers.contains(.option) { return false }
        if canSend { onSend?() }
        return true
    }
    /// An attached suggestion list sees navigation keys first, but never while the
    /// input method is composing, so Return still commits Chinese text.
    func handleNavigation(_ event: NSEvent) -> Bool {
        guard let onKey, !hasMarkedText() else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 126: return onKey(.up)
        case 125: return onKey(.down)
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
    override func paste(_ sender: Any?) {
        guard let onFiles else { super.paste(sender); return }
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles(urls)
            return
        }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentWorkbenchAttachments", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("粘贴图片-\(UUID().uuidString.prefix(8)).png")
                try png.write(to: file, options: .atomic)
                onFiles([file])
            } catch { onError?(error.localizedDescription) }
            return
        }
        super.paste(sender)
    }
}

struct ComposerAttachment: View {
    let file: URL
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            if let image = NSImage(contentsOf: file), image.isValid {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else { Image(systemName: "doc").frame(width: 30, height: 34).foregroundStyle(.secondary) }
            Text(file.lastPathComponent).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 130)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("移除附件")
        }.padding(6).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}
