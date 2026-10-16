import AppKit
import SwiftUI
import WorkbenchCore

/// Actions for text selected in the transcript.
///
/// Selection is observed through AppKit's shared notification rather than by
/// modifying the reply views, so the transcript keeps its own layout, measurement
/// and selection behaviour untouched. A selection that spans several text views of
/// an entry (ReplySelection) is read as one.
///
/// The bar appears once a selection settles: after the mouse button is released,
/// or shortly after a keyboard change. It is built once and only moved afterwards,
/// and it steps aside while the transcript scrolls instead of trailing it.
@MainActor
final class SelectionActionsController: NSObject {
    static let shared = SelectionActionsController()
    /// Set by the host. Absent means the current session cannot take a quote, and
    /// the action is hidden rather than shown as a no-op.
    var quoteHandler: ((String) -> Void)?
    var quoteAvailable: (() -> Bool)?

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    /// What the hosted bar was built for; it is rebuilt only when these change.
    private var hostedCanQuote: Bool?
    private var hostedLocale: Locale?
    private var observers: [NSObjectProtocol] = []
    private weak var source: NSTextView?
    private var pending: DispatchWorkItem?

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observe(center, NSTextView.didChangeSelectionNotification) { [weak self] note in
            self?.selectionChanged(note.object as? NSTextView)
        }
        // A span across views changes without its anchor's selection changing.
        observe(center, ReplySelection.didChange) { [weak self] note in
            self?.selectionChanged(note.object as? NSTextView)
        }
        // The panel lives in screen coordinates while the text scrolls under it.
        // Following every scroll step lags a frame behind, so step aside instead
        // and come back once the transcript is still.
        observe(center, NSView.boundsDidChangeNotification) { [weak self] note in
            guard let self, let clip = note.object as? NSClipView, let source = self.source,
                  source.isDescendant(of: clip) else { return }
            self.suspend()
        }
        observe(center, NSWindow.didResizeNotification) { [weak self] _ in self?.suspend() }
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
        guard let textView, textView.identifier?.rawValue != "PerchReviewSource", !textView.isEditable, textView.isSelectable else { hide(); return }
        guard textView.selectedRange().length > 0, !selectedText(in: textView).isEmpty else {
            if textView === source { hide(); source = nil }
            return
        }
        source = textView
        // During a drag the selection changes on every pointer step; the bar waits.
        if Self.mouseIsDown { suspend() } else { schedule(after: 0.12) }
    }

    private static var mouseIsDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showIfSettled() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func showIfSettled() {
        pending = nil
        guard let source, source.selectedRange().length > 0 else { return }
        // Still dragging: look again shortly; the bar appears once the button is up.
        if Self.mouseIsDown { schedule(after: 0.1); return }
        show(for: source)
    }

    /// Text and quote read the selection when an action runs, so the bar does not
    /// need rebuilding as the selection changes.
    private func currentText() -> String? {
        guard let source, source.selectedRange().length > 0 else { return nil }
        let text = selectedText(in: source)
        return text.isEmpty ? nil : text
    }

    private func selectedText(in textView: NSTextView) -> String {
        if let span = ReplySelection.shared.text(from: textView) { return span }
        let range = textView.selectedRange()
        guard range.length > 0, range.upperBound <= (textView.string as NSString).length else { return "" }
        return (textView.string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The selection's first line in screen coordinates, or nil once it has scrolled
    /// out of the window so the bar does not float over unrelated content.
    private func anchor(for textView: NSTextView) -> NSRect? {
        let range = textView.selectedRange()
        guard range.length > 0, !textView.isHiddenOrHasHiddenAncestor, let window = textView.window else { return nil }
        let rect = ReplySelection.shared.firstLineRect(from: textView)
            ?? textView.firstRect(forCharacterRange: range, actualRange: nil)
        let visible = window.convertToScreen(textView.convert(textView.visibleRect, to: nil))
        let transcript = textView.enclosingScrollView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? visible
        guard rect.width > 0 || rect.height > 0, transcript.intersects(rect) || visible.intersects(rect) else { return nil }
        return rect
    }

    private func show(for textView: NSTextView) {
        guard let rect = anchor(for: textView), currentText() != nil, let window = textView.window else { hide(); return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = hostedBar()
        if panel.contentView !== hosting { panel.contentView = hosting }
        let size = hosting.fittingSize
        let frame = NSRect(origin: origin(above: rect, size: size), size: size)
        if panel.isVisible && panel.parent === window {
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    /// One hosting view, rebuilt only when quoting availability or the language changes.
    private func hostedBar() -> NSHostingView<AnyView> {
        let canQuote = quoteAvailable?() ?? false
        let locale = AppLanguage.current.resolvedLocale
        if let hosting, hostedCanQuote == canQuote, hostedLocale == locale { return hosting }
        let bar = SelectionActionsBar(canQuote: canQuote,
                                      onCopy: { [weak self] in self?.copySelection() },
                                      onQuote: { [weak self] in self?.quoteSelection() })
        let view = NSHostingView(rootView: AnyView(bar.environment(\.locale, locale)))
        view.layout()
        hosting = view
        hostedCanQuote = canQuote
        hostedLocale = locale
        return view
    }

    private func copySelection() {
        if let text = currentText() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        hide()
    }

    private func quoteSelection() {
        if let text = currentText() { quoteHandler?(text) }
        hide()
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

    /// Out of the way while the text moves; back after a short pause.
    private func suspend() {
        if let panel, panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        guard source != nil else { return }
        schedule(after: 0.15)
    }

    func hide() {
        pending?.cancel()
        pending = nil
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
                .background(hovered ? Color.primary.opacity(WorkbenchTheme.Fill.hover) : .clear,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(title)
    }
}
