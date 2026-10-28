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
        } else {
            // The bottom marker precedes ConversationScrollView's 12pt outer padding.
            precondition(abs(scroll.documentView!.bounds.maxY - scroll.documentVisibleRect.maxY - 12) < 1,
                         "Return reaches the latest anchor, with only the outer padding beyond it")
        }
        precondition(scroll.contentView.bounds.size == before.size, "Hiding the button preserves the viewport")
    }
    print("PASS: floating centered return-to-latest, full-height transcript under the composer bar, wide/narrow clicks and actual tail navigation")
}
