import AppKit
import WorkbenchCore

/// A transcript entry whose text views share one selection: its paragraphs,
/// headings, list items and code blocks are separate text views.
@MainActor
protocol ReplySelectionScope: AnyObject {
    /// The entry's Markdown when it is an assistant reply, for "copy as plain text".
    var replySource: String? { get }
}

/// A user prompt bubble is its own entry when it is a row's root view.
extension NativeUserMessageView: ReplySelectionScope {
    var replySource: String? { nil }
}

/// One selection across the text views of a transcript entry.
///
/// AppKit keeps one selection per text view, and a drag cannot leave the view it
/// started in. The view the drag starts in (the anchor) keeps a real selection and
/// stays first responder. The other views show the extension with a temporary
/// background, because a view that is not first responder draws its selection in
/// the inactive color. Copy, ⌘A, the selection bar and quoting read the whole span.
@MainActor
final class ReplySelection {
    static let shared = ReplySelection()
    static let didChange = Notification.Name("PerchReplySelectionDidChange")

    private final class Extension {
        weak var view: ReplyTextView?
        let range: NSRange
        init(_ view: ReplyTextView, _ range: NSRange) { self.view = view; self.range = range }
    }
    private weak var anchor: ReplyTextView?
    private var anchorOffset = 0
    private var tracking = false
    private var extensions: [Extension] = []
    private var observers: [NSObjectProtocol] = []
    /// NSTextView's drag loop asks for a new range only when its own range changes,
    /// which stops once the pointer has left the anchor. This timer runs in the
    /// event-tracking run loop mode, so the span follows the pointer through the
    /// views below or above.
    private var trackingTimer: Timer?

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ReplySelection.shared.refreshHighlight() }
            })
        }
    }

    // MARK: Drag

    /// Any click in another text view ends the previous selection, including a
    /// word picked by double-click, so only one selection shows in the transcript.
    /// Only a plain single click can drag a span across views.
    func begin(_ view: ReplyTextView, event: NSEvent) {
        let plain = event.clickCount == 1 && event.modifierFlags.isDisjoint(with: [.shift, .command, .option, .control])
        if anchor !== view { clear(collapsingAnchor: true) } else if plain { apply([]) }
        guard Self.scope(of: view) != nil else { anchor = nil; tracking = false; return }
        anchor = view
        tracking = plain
        guard plain else { return }
        anchorOffset = view.characterIndexForInsertion(at: view.convert(event.locationInWindow, from: nil))
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { ReplySelection.shared.followPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    func end(_ view: ReplyTextView) {
        guard view === anchor else { return }
        if tracking { followPointer() }
        stopTimer()
        tracking = false
        if view.selectedRange().length == 0 && extensions.isEmpty { anchor = nil }
        NotificationCenter.default.post(name: Self.didChange, object: view)
    }

    /// One drag step: extend to the views the pointer has reached and hold the
    /// anchor's range at its edge.
    private func followPointer() {
        guard tracking, let anchor else { stopTimer(); return }
        guard let span = currentSpan(for: anchor) else {
            if !extensions.isEmpty { apply([]) }
            return
        }
        apply(span.extensions)
        if anchor.selectedRange() != span.anchorRange { anchor.setSelectedRange(span.anchorRange) }
    }

    private func stopTimer() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    /// While a drag reaches past the anchor, the anchor's range runs to its end
    /// (dragging down) or its start (dragging up), not to the pointer's column on
    /// its last line. Other views get their part of the span.
    func track(_ view: ReplyTextView, proposed: [NSValue]) -> [NSValue] {
        guard tracking, view === anchor else { return proposed }
        guard let span = currentSpan(for: view) else {
            apply([])
            return proposed
        }
        apply(span.extensions)
        return [NSValue(range: span.anchorRange)]
    }

    /// A collapsed anchor outside a drag (a click, new content, recycling) ends the span.
    func selectionChanged(_ view: ReplyTextView) {
        guard !tracking, view === anchor, view.selectedRange().length == 0 else { return }
        clear(collapsingAnchor: false)
        NotificationCenter.default.post(name: Self.didChange, object: view)
    }

    /// ⌘A selects the whole entry rather than one paragraph group.
    func selectAll(from view: ReplyTextView) {
        guard let scope = Self.scope(of: view) else { return }
        clear(collapsingAnchor: anchor !== view)
        anchor = view
        let others = Self.textViews(in: scope).filter { $0 !== view }
        apply(others.map { ($0, NSRange(location: 0, length: ($0.string as NSString).length)) })
        NotificationCenter.default.post(name: Self.didChange, object: view)
    }

    /// A recycled view leaves any span it was part of.
    func forget(_ view: ReplyTextView) {
        if view === anchor { clear(collapsingAnchor: false); return }
        guard extensions.contains(where: { $0.view === view }) else { return }
        view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: Self.fullRange(of: view))
        extensions.removeAll { $0.view === view || $0.view == nil }
    }

    // MARK: Reading the span

    /// The whole span's text in reading order, when `view` anchors a span that
    /// reaches other views; nil means the view's own selection is the selection.
    func text(from view: NSTextView) -> String? {
        guard let anchor, view === anchor, extensions.contains(where: { $0.view != nil && $0.range.length > 0 }),
              let scope = Self.scope(of: anchor) else { return nil }
        var parts: [String] = []
        for candidate in Self.textViews(in: scope) {
            let range: NSRange? = candidate === anchor ? anchor.selectedRange()
                : extensions.first(where: { $0.view === candidate })?.range
            guard let range, range.length > 0 else { continue }
            let text = candidate.string as NSString
            guard range.upperBound <= text.length else { continue }
            parts.append(text.substring(with: range))
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// The first selected line in screen coordinates, which may sit in a view above
    /// the anchor when the drag went up.
    func firstLineRect(from view: NSTextView) -> NSRect? {
        guard let anchor, view === anchor, let scope = Self.scope(of: anchor) else { return nil }
        for candidate in Self.textViews(in: scope) {
            let range: NSRange? = candidate === anchor ? anchor.selectedRange()
                : extensions.first(where: { $0.view === candidate })?.range
            guard let range, range.length > 0 else { continue }
            return candidate.firstRect(forCharacterRange: range, actualRange: nil)
        }
        return nil
    }

    // MARK: Geometry

    private struct Span {
        let anchorRange: NSRange
        let extensions: [(ReplyTextView, NSRange)]
    }

    /// The span from the anchor to the pointer, or nil while the pointer is still
    /// within the anchor's lines or in the gap next to it.
    private func currentSpan(for anchor: ReplyTextView) -> Span? {
        guard let window = anchor.window, let entry = Self.scope(of: anchor), let scope = entry as? NSView else { return nil }
        let views = Self.textViews(in: entry)
        guard views.count > 1, let anchorIndex = views.firstIndex(where: { $0 === anchor }) else { return nil }
        let pointer = Self.pointer(in: window)
        let y = Self.top(of: scope.convert(NSRect(origin: pointer, size: .zero), from: nil), in: scope).top
        let frames = views.map { Self.top(of: $0.convert($0.bounds, to: scope), in: scope) }
        let focusIndex: Int
        let offset: (ReplyTextView) -> Int
        if y > frames[anchorIndex].bottom {
            guard let index = frames.indices.last(where: { $0 > anchorIndex && frames[$0].top <= y }) else { return nil }
            focusIndex = index
            offset = { y > frames[index].bottom ? ($0.string as NSString).length : Self.offset(in: $0, at: pointer) }
        } else if y < frames[anchorIndex].top {
            guard let index = frames.indices.first(where: { $0 < anchorIndex && frames[$0].bottom >= y }) else { return nil }
            focusIndex = index
            offset = { y < frames[index].top ? 0 : Self.offset(in: $0, at: pointer) }
        } else {
            return nil
        }
        let ranges = TextSelectionSpan.ranges(
            anchor: .init(view: anchorIndex, offset: anchorOffset),
            focus: .init(view: focusIndex, offset: offset(views[focusIndex])),
            lengths: views.map { ($0.string as NSString).length })
        guard let anchorRange = ranges[anchorIndex] else { return nil }
        return Span(anchorRange: anchorRange,
                    extensions: ranges.filter { $0.key != anchorIndex }.sorted { $0.key < $1.key }.map { (views[$0.key], $0.value) })
    }

    /// The drag's latest pointer: the event NSTextView's loop last read, or the
    /// cursor between events (autoscroll steps carry no location).
    private static func pointer(in window: NSWindow) -> NSPoint {
        if let event = NSApp.currentEvent, event.window === window,
           [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            return event.locationInWindow
        }
        return window.mouseLocationOutsideOfEventStream
    }

    private static func offset(in view: ReplyTextView, at windowPoint: NSPoint) -> Int {
        view.characterIndexForInsertion(at: view.convert(windowPoint, from: nil))
    }

    /// Top and bottom of a rect in the scope, measured downward from its top.
    private static func top(of rect: NSRect, in scope: NSView) -> (top: CGFloat, bottom: CGFloat) {
        scope.isFlipped ? (rect.minY, rect.maxY) : (scope.bounds.height - rect.maxY, scope.bounds.height - rect.minY)
    }

    static func scope(of view: NSView) -> ReplySelectionScope? {
        var current = view.superview
        while let candidate = current {
            if let scope = candidate as? ReplySelectionScope { return scope }
            current = candidate.superview
        }
        return nil
    }

    /// Selectable text views of an entry in reading order: top to bottom, then
    /// leading to trailing.
    static func textViews(in scope: ReplySelectionScope) -> [ReplyTextView] {
        guard let root = scope as? NSView else { return [] }
        var found: [ReplyTextView] = []
        func collect(_ view: NSView) {
            if let text = view as? ReplyTextView {
                if text.isSelectable, !text.isHiddenOrHasHiddenAncestor, !text.string.isEmpty { found.append(text) }
                return
            }
            view.subviews.forEach(collect)
        }
        collect(root)
        let frames = found.map { top(of: $0.convert($0.bounds, to: root), in: root) }
        let lefts = found.map { $0.convert($0.bounds, to: root).minX }
        return found.indices.sorted {
            frames[$0].top != frames[$1].top ? frames[$0].top < frames[$1].top : lefts[$0] < lefts[$1]
        }.map { found[$0] }
    }

    // MARK: Highlight

    private var highlightColor: NSColor {
        guard let anchor, let window = anchor.window, window.isKeyWindow, window.firstResponder === anchor else {
            return .unemphasizedSelectedTextBackgroundColor
        }
        return .selectedTextBackgroundColor
    }

    /// Replaces the highlighted extension. An unchanged span is left alone, so the
    /// per-frame drag step does not redraw views whose part did not move.
    private func apply(_ next: [(ReplyTextView, NSRange)], force: Bool = false) {
        let next = next.filter { $0.1.length > 0 }
        if !force, next.count == extensions.count,
           zip(extensions, next).allSatisfy({ $0.view === $1.0 && $0.range == $1.1 }) { return }
        for old in extensions {
            guard let view = old.view else { continue }
            view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: Self.fullRange(of: view))
        }
        extensions = next.map { Extension($0.0, $0.1) }
        let color = highlightColor
        for item in extensions {
            item.view?.layoutManager?.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: item.range)
        }
    }

    /// The extension follows the anchor between the active and inactive colors.
    func refreshHighlight() {
        guard !extensions.isEmpty else { return }
        apply(extensions.compactMap { item in item.view.map { ($0, item.range) } }, force: true)
    }

    private func clear(collapsingAnchor: Bool) {
        stopTimer()
        apply([])
        let previous = anchor
        anchor = nil
        tracking = false
        if collapsingAnchor, let previous, previous.selectedRange().length > 0 {
            previous.setSelectedRange(NSRange(location: previous.selectedRange().location, length: 0))
        }
    }

    private static func fullRange(of view: NSTextView) -> NSRange {
        NSRange(location: 0, length: (view.string as NSString).length)
    }
}
