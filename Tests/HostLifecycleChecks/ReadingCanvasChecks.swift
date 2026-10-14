import AppKit
import SwiftUI
import Observation

@MainActor @Observable private final class CanvasNavigationState {
    var visible = false
    var newContent = false
    var returned = 0
}
private struct CanvasNavigationFixture: View {
    let state: CanvasNavigationState
    var body: some View {
        ScrollViewReader { proxy in
            ConversationScrollView(showsReturnToLatest: state.visible, hasNewReply: state.newContent,
                                   onReturnToLatest: {
                                       state.returned += 1
                                       state.visible = false
                                       proxy.scrollTo("canvas-tail", anchor: .bottom)
                                   }) {
                KimiMarkdown(text: String(repeating: "正文阅读位置不会因导航按钮出现而改变。\n\n", count: 50))
                Color.clear.frame(height: 1).id("canvas-tail")
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
    for width in [900.0, 480.0] {
        let state = CanvasNavigationState()
        let host = NSHostingView(rootView: CanvasNavigationFixture(state: state))
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: 600))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        guard let scroll = scrollViews(host).first else { preconditionFailure("Missing conversation scroll view") }
        precondition(abs(scroll.frame.height - host.bounds.height) < 1,
                     "Floating navigation must not reserve a footer or reduce the transcript height")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 220))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = scroll.contentView.bounds
        for newContent in [false, true] {
            state.visible = true
            state.newContent = newContent
            try await Task.sleep(for: .milliseconds(100))
            precondition(scroll.contentView.bounds == before, "Showing navigation or changing its label must not move or resize the viewport")
        }
        let point = host.convert(NSPoint(x: width / 2, y: host.isFlipped ? 576 : 24), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0)!)
        }
        try await Task.sleep(for: .milliseconds(200))
        precondition(state.returned == 1 && !state.visible, "A centered click above the input area returns to latest")
        // The bottom marker precedes ConversationScrollView's 12pt outer padding.
        precondition(abs(scroll.documentView!.bounds.maxY - scroll.documentVisibleRect.maxY - 12) < 1,
                     "Return reaches the latest anchor, with only the outer padding beyond it")
        precondition(scroll.contentView.bounds.size == before.size, "Hiding the button preserves the viewport")
    }
    print("PASS: floating centered return-to-latest, full-height transcript, wide/narrow clicks and actual tail navigation")
}
