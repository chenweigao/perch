import AppKit
import SwiftUI

/// Only user scrolling changes follow mode; growing streamed content must not disable it.
struct ConversationScrollObserver: NSViewRepresentable {
    let onScroll: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(onScroll: onScroll) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll }

    final class ObserverView: NSView {
        var onScroll: (Bool) -> Void
        private var observation: NSObjectProtocol?
        init(onScroll: @escaping (Bool) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
            observation = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self, let scroll = self.enclosingScrollView,
                      notification.object as? NSScrollView === scroll,
                      let document = scroll.documentView else { return }
                self.onScroll(document.bounds.maxY - scroll.documentVisibleRect.maxY < 40)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}

struct ReturnToLatestButton: View {
    var hasNewReply = false
    let action: () -> Void
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
    }
}

/// Keep transcript placement eager: native text caches bound repeated measurement,
/// without SwiftUI lazy phase resolution or system-table accessibility traversal.
struct ConversationScrollView<Content: View>: View {
    var showsScrollIndicator = false
    var onScroll: (Bool) -> Void = { _ in }
    var onContentSizeChange: () -> Void = {}
    @ViewBuilder let content: Content
    @State private var userScrolling = false
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
                        if #unavailable(macOS 15) { ConversationScrollObserver(onScroll: onScroll) }
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
            }.onScrollPhaseChange { _, phase, context in
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if userScrolling { onScroll(context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 40) }
            }.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 40
            } action: { _, atBottom in
                if userScrolling { onScroll(atBottom) }
            }
        } else {
            scroll
        }
    }
}
