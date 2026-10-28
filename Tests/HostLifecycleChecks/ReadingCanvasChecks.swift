import AppKit
import SwiftUI
import Observation

@MainActor @Observable private final class CanvasNavigationState {
    var visible = false
    var newContent = false
    var returned = 0
    var tail = CGRect.zero
    var bar = CGRect.zero
}
private struct CanvasNavigationFixture: View {
    let state: CanvasNavigationState
    /// A stand-in for the activity bar and composer floating over the transcript.
    var barHeight: CGFloat?
    private var transcript: some View {
        Group {
            KimiMarkdown(text: String(repeating: "正文阅读位置不会因导航按钮出现而改变。\n\n", count: 50))
            Color.clear.frame(height: 1).id("canvas-tail")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.tail = $0 }
        }
    }
    var body: some View {
        ScrollViewReader { proxy in
            let returnToLatest = {
                state.returned += 1
                state.visible = false
                proxy.scrollTo("canvas-tail", anchor: .bottom)
            }
            if let barHeight {
                ConversationScrollView(showsReturnToLatest: state.visible, hasNewReply: state.newContent,
                                       onReturnToLatest: returnToLatest) {
                    transcript
                } bar: {
                    Color.clear.frame(height: barHeight)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.bar = $0 }
                }
            } else {
                ConversationScrollView(showsReturnToLatest: state.visible, hasNewReply: state.newContent,
                                       onReturnToLatest: returnToLatest) { transcript }
            }
        }
    }
}
/// The first horizontal rule between `top` and `bottom` (host coordinates from
/// the top), or nil: one pixel row darker than the rows 3 pt above and below it
/// across most of `xRange`. Text never darkens a whole row this way.
@MainActor func horizontalRule(in host: NSView, from top: CGFloat, to bottom: CGFloat,
                               xRange: ClosedRange<CGFloat>? = nil) -> CGFloat? {
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsHigh) / max(1, host.bounds.height)
    func luminance(_ x: Int, _ row: Int) -> CGFloat {
        guard row >= 0, row < bitmap.pixelsHigh,
              let color = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { return 1 }
        let a = color.alphaComponent
        // Over white, as the card draws it.
        return 0.2126 * (color.redComponent * a + 1 - a) + 0.7152 * (color.greenComponent * a + 1 - a)
            + 0.0722 * (color.blueComponent * a + 1 - a)
    }
    let span = xRange ?? (host.bounds.width * 0.1)...(host.bounds.width * 0.9)
    let columns = Array(stride(from: Int(span.lowerBound * scale), to: Int(span.upperBound * scale), by: 4))
    guard !columns.isEmpty else { return nil }
    let reach = Int((3 * scale).rounded())
    for row in Int(top * scale)...Int(bottom * scale) {
        let darker = columns.filter { x in
            let value = luminance(x, row)
            return value < luminance(x, row - reach) - 0.03 && value < luminance(x, row + reach) - 0.03
        }.count
        if Double(darker) / Double(columns.count) > 0.8 { return CGFloat(row) / scale }
    }
    return nil
}

@MainActor func checkReadingCanvas() async throws {
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    for (width, barHeight) in [(900.0, nil), (480.0, nil), (900.0, 120.0)] as [(CGFloat, CGFloat?)] {
        let state = CanvasNavigationState()
        let host = NSHostingView(rootView: CanvasNavigationFixture(state: state, barHeight: barHeight))
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: 600))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        guard let scroll = scrollViews(host).first else { preconditionFailure("Missing conversation scroll view") }
        precondition(abs(scroll.frame.height - host.bounds.height) < 1,
                     "Floating navigation and the composer bar must not reserve a footer or reduce the transcript height: scroll=\(scroll.frame), host=\(host.bounds)")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 220))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = scroll.contentView.bounds
        for newContent in [false, true] {
            state.visible = true
            state.newContent = newContent
            try await Task.sleep(for: .milliseconds(100))
            precondition(scroll.contentView.bounds == before, "Showing navigation or changing its label must not move or resize the viewport")
        }
        let fromBottom = 24 + (barHeight ?? 0)
        let point = host.convert(NSPoint(x: width / 2, y: host.isFlipped ? 600 - fromBottom : fromBottom), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0)!)
        }
        try await Task.sleep(for: .milliseconds(200))
        precondition(state.returned == 1 && !state.visible, "A centered click above the input area returns to latest")
        if barHeight != nil {
            // The transcript runs beneath the bar, but its tail stops on the bar's top edge.
            precondition(state.bar.height > 1 && state.tail.maxY <= state.bar.minY + 1 && state.tail.minY >= state.bar.minY - 40,
                         "Return must land the tail just above the composer bar, not beneath it: tail=\(state.tail), bar=\(state.bar)")
            // The reply fades into the bar; no hard scroll-edge divider crosses the transcript.
            let rule = horizontalRule(in: host, from: state.bar.minY - 4, to: state.bar.minY + 4)
            precondition(rule == nil, "The composer bar must not draw a divider across the transcript: y=\(String(describing: rule))")
        } else {
            // The bottom marker precedes ConversationScrollView's 12pt outer padding.
            precondition(abs(scroll.documentView!.bounds.maxY - scroll.documentVisibleRect.maxY - 12) < 1,
                         "Return reaches the latest anchor, with only the outer padding beyond it")
        }
        precondition(scroll.contentView.bounds.size == before.size, "Hiding the button preserves the viewport")
    }
    print("PASS: floating centered return-to-latest, full-height transcript under the composer bar, wide/narrow clicks and actual tail navigation")
}
