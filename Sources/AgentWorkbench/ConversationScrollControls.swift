import AppKit
import SwiftUI

/// Only user scrolling changes follow mode; growing streamed content must not disable it.
struct ConversationScrollObserver: NSViewRepresentable {
    let onScroll: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(onScroll: onScroll) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll }

    final class ObserverView: NSView {
        var onScroll: (Bool) -> Void
        private var observations: [NSObjectProtocol] = []
        private var wheelMonitor: Any?
        private var wheelGeneration = 0
        init(onScroll: @escaping (Bool) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let self, let scroll = self.enclosingScrollView,
                          notification.object as? NSScrollView === scroll else { return }
                    if notification.name == NSScrollView.willStartLiveScrollNotification {
                        self.onScroll(false)
                    } else {
                        self.resumeIfAtBottom()
                    }
                })
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
            guard window != nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, let scroll = self.enclosingScrollView,
                      scroll.visibleRect.contains(scroll.convert(event.locationInWindow, from: nil)),
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
                self.userScrolled(deltaY: event.scrollingDeltaY)
                return event // Observe intent without consuming or forwarding the gesture.
            }
        }
        /// Pause before AppKit moves the clip view. Otherwise a streamed height
        /// update can snap back to the bottom before the old 40-point threshold is crossed.
        func userScrolled(deltaY: CGFloat) {
            wheelGeneration += 1
            let generation = wheelGeneration
            onScroll(false)
            // Wheel mice may have no live-scroll phase. Resume only after an explicit
            // downward event has been applied, never from a content-size change.
            if deltaY < 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.wheelGeneration == generation else { return }
                    self.resumeIfAtBottom()
                }
            }
        }
        private func resumeIfAtBottom() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView,
                  document.bounds.maxY - scroll.documentVisibleRect.maxY <= 1 else { return }
            onScroll(true)
        }
        deinit {
            observations.forEach(NotificationCenter.default.removeObserver)
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        }
    }
}

struct ReturnToLatestButton: View {
    let isVisible: Bool
    var hasNewReply = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                if hasNewReply { Text("New reply") }
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 32)
                .workbenchFloatingSurface()
                .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        }.buttonStyle(.plain).help("Return to latest reply").accessibilityLabel("Return to latest reply")
            .padding(.bottom, 8)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible).accessibilityHidden(!isVisible)
            .disabled(!isVisible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isVisible)
    }
}

/// Keep transcript placement eager: native text caches bound repeated measurement,
/// without SwiftUI lazy phase resolution or system-table accessibility traversal.
struct ConversationScrollView<Content: View>: View {
    var showsScrollIndicator = false
    var onScroll: (Bool) -> Void = { _ in }
    var onContentSizeChange: () -> Void = {}
    @ViewBuilder let content: Content
    @State private var contentSize = CGSize.zero
    @State private var conversationViewport = ConversationViewport()
    private var scroll: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .environment(\.conversationViewport, conversationViewport)
                    .padding(.vertical, 12)
                    .frame(width: min(ReplyStyle.readingWidth, max(1, viewport.size.width - 72)), alignment: .leading)
                    .padding(.horizontal, 36).frame(maxWidth: .infinity)
                    .coordinateSpace(name: "conversation-content")
                    .background {
                        ConversationScrollObserver(onScroll: onScroll)
                    }
            }.scrollIndicators(showsScrollIndicator ? .automatic : .hidden, axes: .vertical)
                .background(ConversationViewportView(viewport: conversationViewport, onPauseFollowing: { onScroll(false) }))
        }
    }
    var body: some View {
        if #available(macOS 15, *) {
            scroll.onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, _ in
                conversationViewport.refresh()
            }.onScrollGeometryChange(for: CGSize.self) { $0.contentSize } action: { _, size in
                contentSize = size
            }.task(id: contentSize) {
                await Task.yield()
                if !Task.isCancelled { onContentSizeChange() }
            }
        } else {
            scroll
        }
    }
}
