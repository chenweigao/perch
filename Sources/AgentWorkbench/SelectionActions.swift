import AppKit
import SwiftUI
import WorkbenchCore

/// Actions for text selected in the transcript.
///
/// Selection is observed through AppKit's shared notification rather than by
/// modifying the reply views, so the transcript keeps its own layout, measurement
/// and selection behaviour untouched.
@MainActor
final class SelectionActionsController: NSObject {
    static let shared = SelectionActionsController()
    /// Set by the host. Absent means the current session cannot take a quote, and
    /// the action is hidden rather than shown as a no-op.
    var quoteHandler: ((String) -> Void)?
    var quoteAvailable: (() -> Bool)?

    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private weak var source: NSTextView?

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observe(center, NSTextView.didChangeSelectionNotification) { [weak self] note in
            self?.selectionChanged(note.object as? NSTextView)
        }
        // Scrolling and resizing move the text under a panel that is positioned in
        // screen coordinates, so the anchor is recomputed instead of left behind.
        observe(center, NSView.boundsDidChangeNotification) { [weak self] _ in self?.reanchor() }
        observe(center, NSWindow.didResizeNotification) { [weak self] _ in self?.reanchor() }
        observe(center, NSWindow.didResignKeyNotification) { [weak self] note in
            guard (note.object as? NSWindow) !== self?.panel else { return }
            self?.hide()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping (Notification) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { action(note) }
        })
    }

    /// Only non-editable text views offer these actions, which keeps the composer
    /// and any field editor out of scope.
    private func selectionChanged(_ textView: NSTextView?) {
        guard let textView, !textView.isEditable, textView.isSelectable else { return }
        guard textView.selectedRange().length > 0, !selectedText(in: textView).isEmpty else {
            if textView === source { hide() }
            return
        }
        source = textView
        show(for: textView)
    }

    private func selectedText(in textView: NSTextView) -> String {
        let range = textView.selectedRange()
        guard range.length > 0, range.upperBound <= (textView.string as NSString).length else { return "" }
        return (textView.string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The selection's first line in screen coordinates, or nil once it has scrolled
    /// out of the window so the bar does not float over unrelated content.
    private func anchor(for textView: NSTextView) -> NSRect? {
        let range = textView.selectedRange()
        guard range.length > 0, let window = textView.window else { return nil }
        let rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard rect.width > 0 || rect.height > 0, window.frame.intersects(rect) else { return nil }
        return rect
    }

    private func show(for textView: NSTextView) {
        guard let rect = anchor(for: textView) else { hide(); return }
        let text = selectedText(in: textView)
        guard !text.isEmpty else { hide(); return }
        let bar = SelectionActionsBar(
            canQuote: quoteAvailable?() ?? false,
            onCopy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self?.hide()
            },
            onQuote: { [weak self] in
                self?.quoteHandler?(text)
                self?.hide()
            })
        let hosting = NSHostingView(rootView: bar)
        hosting.layout()
        let size = hosting.fittingSize

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: origin(above: rect, size: size), size: size), display: true)
        if !panel.isVisible { textView.window?.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func origin(above rect: NSRect, size: NSSize) -> NSPoint {
        var x = rect.midX - size.width / 2
        var y = rect.maxY + 8
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            // No room above the first line means the selection is at the top of the
            // screen, so the bar goes below it instead of off-screen.
            if y + size.height > screen.visibleFrame.maxY { y = rect.minY - size.height - 8 }
        }
        return NSPoint(x: x, y: y)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovable = false
        // Clicking an action must not pull focus out of the composer.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        return panel
    }

    private func reanchor() {
        guard let panel, panel.isVisible, let source else { return }
        guard source.selectedRange().length > 0, let rect = anchor(for: source) else { hide(); return }
        panel.setFrameOrigin(origin(above: rect, size: panel.frame.size))
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// The floating bar itself. Uses the app's existing glass surface so it matches the
/// other floating controls and respects the reduce-transparency setting.
private struct SelectionActionsBar: View {
    let canQuote: Bool
    let onCopy: () -> Void
    let onQuote: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            action("复制文本", systemImage: "doc.on.doc", action: onCopy)
            if canQuote {
                Divider().frame(height: 14)
                action("引用", systemImage: "quote.opening", action: onQuote)
            }
        }.padding(.horizontal, 5).padding(.vertical, 4)
            .workbenchFloatingSurface()
            .padding(6)
            .fixedSize()
    }

    private func action(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        SelectionActionButton(title: title, systemImage: systemImage, action: action)
    }
}

private struct SelectionActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }.padding(.horizontal, 9).padding(.vertical, 6).contentShape(Rectangle())
                .background(hovered ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(title)
    }
}
