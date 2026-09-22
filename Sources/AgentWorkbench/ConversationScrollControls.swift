import AppKit
import SwiftUI
import WorkbenchCore

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
                .overlay(alignment: .leading) {
                    ConversationTurnNavigator(model: conversationViewport.navigator)
                }
        }
    }
    var body: some View {
        if #available(macOS 15, *) {
            scroll.onScrollGeometryChange(for: CGSize.self) { $0.contentSize } action: { _, size in
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

/// Separate observation keeps hover and current-turn changes out of the
/// transcript's SwiftUI graph. Only the native document supplies positions.
final class ConversationTurnNavigation: ObservableObject {
    struct Snapshot: Equatable {
        var session = ""
        var turns: [ConversationTurnSummary] = []
        var current = 0
    }
    @Published private(set) var snapshot = Snapshot()
    var current: Int { snapshot.current }
    var reveal: ((String) -> Void)?

    func update(session: String, turns: [ConversationTurnSummary], current: Int) {
        let next = Snapshot(session: session, turns: turns, current: current)
        if snapshot != next { snapshot = next }
    }
    func select(_ index: Int) {
        guard snapshot.turns.indices.contains(index) else { return }
        reveal?(snapshot.turns[index].id)
    }
}

private struct ConversationTurnNavigator: View {
    @ObservedObject var model: ConversationTurnNavigation
    var body: some View {
        if model.snapshot.turns.count > 1 {
            ConversationTurnRail(turns: model.snapshot.turns, current: model.current, select: model.select)
                .id(model.snapshot.session)
        }
    }
}

private struct ConversationTurnRail: View {
    let turns: [ConversationTurnSummary]
    let current: Int
    let select: (Int) -> Void
    @State private var hovered: Int?
    @FocusState private var focused: Bool
    private let railWidth: CGFloat = 32
    private var count: Int { turns.count }

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - 32)
            let step = min(14, height / CGFloat(count))
            let trackHeight = step * CGFloat(count)
            let availableWidth = max(1, geometry.size.width - railWidth - 12)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    // Dense histories share painted ticks, while hit testing and
                    // keyboard navigation still address every individual turn.
                    let ticks = min(count, max(1, Int(trackHeight / 5)))
                    for tick in 0..<ticks {
                        let y = (CGFloat(tick) + 0.5) * trackHeight / CGFloat(ticks)
                        context.fill(Path(CGRect(x: 12, y: y, width: 7, height: 2)), with: .color(.secondary.opacity(0.3)))
                    }
                    let y = (CGFloat(current) + 0.5) * step
                    context.fill(Path(CGRect(x: 9, y: y, width: 17, height: 2)), with: .color(.primary.opacity(0.8)))
                    if let hovered {
                        let y = (CGFloat(hovered) + 0.5) * step
                        context.fill(Path(CGRect(x: 9, y: y, width: 17, height: 2)), with: .color(.primary.opacity(0.55)))
                    }
                }
                .frame(width: railWidth, height: trackHeight)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = index(at: point.y, step: step)
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture { point in
                    focused = true
                    select(index(at: point.y, step: step))
                }
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.upArrow) { hovered = nil; select(max(0, current - 1)); return .handled }
                .onKeyPress(.downArrow) { hovered = nil; select(min(count - 1, current + 1)); return .handled }
                .onKeyPress(.escape) { focused = false; hovered = nil; return .handled }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Conversation turns"))
                .accessibilityValue(Text("\(current + 1) / \(count): \(turns[current].prompt)"))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: select(min(count - 1, current + 1))
                    case .decrement: select(max(0, current - 1))
                    @unknown default: break
                    }
                }
                if let index = hovered, turns.indices.contains(index) {
                    let turn = turns[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(index + 1) / \(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Group {
                            if turn.prompt.isEmpty { Text("Attachment") }
                            else { Text(turn.prompt) }
                        }.font(.system(size: 12, weight: .medium)).lineLimit(2)
                        if !turn.reply.isEmpty {
                            Text(turn.reply).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .padding(12).frame(width: min(340, availableWidth), alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.09)))
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
                    .offset(x: railWidth, y: min(max(0, (CGFloat(index) + 0.5) * step - 28), max(0, height - 150)))
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }.padding(.vertical, 16)
        }
    }
    private func index(at y: CGFloat, step: CGFloat) -> Int {
        min(count - 1, max(0, Int(y / step)))
    }
}
