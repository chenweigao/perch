import AppKit
import SwiftUI
import WorkbenchCore

/// Only user scrolling changes follow mode; growing streamed content must not disable it.
struct ConversationScrollObserver: NSViewRepresentable {
    let onScroll: (Bool) -> Void
    var onNearTop: () -> Void = {}
    func makeNSView(context: Context) -> ObserverView { ObserverView(onScroll: onScroll, onNearTop: onNearTop) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll; view.onNearTop = onNearTop }

    final class ObserverView: NSView {
        var onScroll: (Bool) -> Void
        var onNearTop: () -> Void
        private var observations: [NSObjectProtocol] = []
        private var wheelMonitor: Any?
        private var wheelGeneration = 0
        init(onScroll: @escaping (Bool) -> Void, onNearTop: @escaping () -> Void = {}) {
            self.onScroll = onScroll; self.onNearTop = onNearTop
            super.init(frame: .zero)
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let self, let scroll = self.enclosingScrollView,
                          notification.object as? NSScrollView === scroll else { return }
                    if notification.name == NSScrollView.willStartLiveScrollNotification {
                        self.onScroll(false)
                    } else {
                        self.resumeIfAtBottom()
                        self.loadIfNearTop()
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
            // A downward event with the content already pinned at the tail cannot
            // move anything. Dropping follow first would flash the return button
            // and churn transcript state on every momentum tick; resume directly.
            if deltaY < 0, let scroll = enclosingScrollView, let document = scroll.documentView,
               document.bounds.maxY - scroll.documentVisibleRect.maxY <= 1 {
                resumeIfAtBottom()
                return
            }
            wheelGeneration += 1
            let generation = wheelGeneration
            onScroll(false)
            // Wheel mice may have no live-scroll phase. Resume only after an explicit
            // downward event has been applied, never from a content-size change.
            if deltaY > 0 {
                DispatchQueue.main.async { [weak self] in self?.loadIfNearTop() }
            }
            if deltaY < 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.wheelGeneration == generation else { return }
                    self.resumeIfAtBottom()
                }
            }
        }
        /// Start loading before the reader hits the wall: one viewport ahead,
        /// so a page arrives while the loaded remainder is still being read.
        private func loadIfNearTop() {
            guard let scroll = enclosingScrollView else { return }
            let visible = scroll.documentVisibleRect
            guard visible.minY <= max(480, visible.height) else { return }
            onNearTop()
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

/// The 32 pt pill is a capsule in every state: the glass surface (radius 16), its
/// hairline and the hit shape share it, so clicks just outside the circle still
/// reach the transcript text below.
struct ReturnToLatestButton: View {
    let isVisible: Bool
    var hasNewReply = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        // Mount glass only when shown: opacity toggling can leave its pixels
        // invisible on macOS 27 while the accessibility hit target remains.
        if isVisible {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                    if hasNewReply { Text("有新内容") }
                }.font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, hasNewReply ? 12 : 0)
                    .frame(width: hasNewReply ? nil : 32, height: 32)
                    .workbenchFloatingSurface()
                    .overlay(Capsule().fill(Color.primary.opacity(hovered && isVisible ? WorkbenchTheme.Fill.hover : 0)))
                    .overlay(Capsule().strokeBorder(.primary.opacity(WorkbenchTheme.Stroke.hairline)))
                    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                    .contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("return-to-latest")
                .help(hasNewReply ? Text("有新内容，返回最新") : Text("返回最新"))
                .accessibilityLabel(hasNewReply ? Text("有新内容，返回最新") : Text("返回最新"))
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hasNewReply)
        }
    }
}

/// Keep transcript placement eager: native text caches bound repeated measurement,
/// without SwiftUI lazy phase resolution or system-table accessibility traversal.
struct ConversationScrollView<Content: View>: View {
    var showsScrollIndicator = false
    var hasOlderHistory = false
    var onScroll: (Bool) -> Void = { _ in }
    var onContentSizeChange: () -> Void = {}
    var onNearTop: () -> Void = {}
    var showsReturnToLatest = false
    var hasNewReply = false
    var onReturnToLatest: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @State private var contentSize = CGSize.zero
    @State private var conversationViewport = ConversationViewport()
    private var scroll: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: ReplyStyle.entrySpacing) { content }
                    .environment(\.conversationViewport, conversationViewport)
                    .padding(.vertical, 12)
                    .frame(width: min(ReplyStyle.readingWidth, max(1, viewport.size.width - 72)), alignment: .leading)
                    .padding(.horizontal, 36).frame(maxWidth: .infinity)
                    .coordinateSpace(name: "conversation-content")
                    .background {
                        ConversationScrollObserver(onScroll: { following in
                            conversationViewport.userScrolled()
                            onScroll(following)
                        }, onNearTop: onNearTop)
                    }
            }.scrollIndicators(showsScrollIndicator ? .automatic : .hidden, axes: .vertical)
                .background(ConversationViewportView(viewport: conversationViewport, onPauseFollowing: { onScroll(false) }, onNearTop: onNearTop))
                .overlay(alignment: .leading) {
                    ConversationTurnNavigator(model: conversationViewport.navigator, hasOlderHistory: hasOlderHistory)
                }
                .overlay(alignment: .bottomLeading) {
                    ConversationBookmarksMenu(navigator: conversationViewport.navigator)
                        .padding(.leading, 40).padding(.bottom, 6)
                }
        }
    }
    var body: some View {
        scroll.onScrollGeometryChange(for: CGSize.self) { $0.contentSize } action: { _, size in
            contentSize = size
        }.task(id: contentSize) {
            await Task.yield()
            if !Task.isCancelled { onContentSizeChange() }
        }.overlay(alignment: .bottom) {
            if let onReturnToLatest {
                // Only the button floats over the transcript; there is no reserved
                // footer or full-width surface intercepting the reading area.
                ReturnToLatestButton(isVisible: showsReturnToLatest, hasNewReply: hasNewReply, action: onReturnToLatest)
                    .padding(.bottom, 8)
            }
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
    @Published private(set) var selectedID: String?
    let hover = ConversationTurnHover()
    private var selectionTask: Task<Void, Never>?
    var current: Int { snapshot.current }
    var reveal: ((String) -> Void)?

    func update(session: String, turns: [ConversationTurnSummary], current: Int) {
        if snapshot.session != session {
            selectionTask?.cancel()
            selectedID = nil
            hover.reset()
        } else if snapshot.turns.count != turns.count { hover.reset() }
        let next = Snapshot(session: session, turns: turns, current: current)
        if snapshot != next { snapshot = next }
    }
    func select(_ index: Int) {
        guard snapshot.turns.indices.contains(index) else { return }
        let id = snapshot.turns[index].id
        let session = snapshot.session
        selectionTask?.cancel()
        selectedID = id
        // Publish selection before mounting cold Markdown rows. Rapid choices
        // in the same event turn coalesce to the user's final destination.
        selectionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.snapshot.session == session else { return }
            self.reveal?(id)
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            self.selectedID = nil
        }
    }
    deinit { selectionTask?.cancel() }
}

/// Dwell only on entry or when moving out of the expanded neighborhood. Once
/// open, neighboring excerpts switch immediately and share one card position.
final class ConversationTurnHover: ObservableObject {
    @Published private(set) var index: Int?
    @Published private(set) var focus: ConversationTurnRailGeometry.Focus?
    @Published private(set) var previewY: CGFloat?
    private var opening: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var candidate: Int?

    func move(y: CGFloat, count: Int, height: CGFloat) {
        closing?.cancel(); closing = nil
        let geometry = ConversationTurnRailGeometry(count: count, height: height, focus: focus)
        let next = geometry.index(at: y)
        if index != next { index = next }
        if previewY != nil && geometry.expanded.contains(next) {
            opening?.cancel(); opening = nil; candidate = nil
            return
        }
        guard candidate != next else { return }
        candidate = next
        opening?.cancel()
        opening = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self else { return }
            self.focus = .init(index: next, y: y)
            self.previewY = y
            self.candidate = nil
        }
    }
    func leave() {
        opening?.cancel(); opening = nil; candidate = nil
        closing?.cancel()
        closing = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            self?.reset()
        }
    }
    func reset() {
        opening?.cancel(); closing?.cancel()
        opening = nil; closing = nil; candidate = nil
        index = nil; focus = nil; previewY = nil
    }
    deinit { opening?.cancel(); closing?.cancel() }
}

private struct ConversationTurnNavigator: View {
    @ObservedObject var model: ConversationTurnNavigation
    var hasOlderHistory = false
    var body: some View {
        if model.snapshot.turns.count > 1 {
            ConversationTurnRail(turns: model.snapshot.turns, current: model.current, hasOlderHistory: hasOlderHistory,
                                 selectedID: model.selectedID, hover: model.hover, select: model.select)
                .id(model.snapshot.session)
        }
    }
}

/// Jump list of the reader's bookmarked turns, in rail order. Hidden until the
/// first bookmark exists so quiet conversations gain no chrome.
private struct ConversationBookmarksMenu: View {
    @ObservedObject var navigator: ConversationTurnNavigation
    @UILocalization private var L
    private var store: ConversationBookmarksStore { .shared }
    var body: some View {
        let session = navigator.snapshot.session
        let marked = navigator.snapshot.turns.filter { store.isBookmarked($0.id, in: session) }
        if !marked.isEmpty, !session.isEmpty {
            Menu {
                ForEach(marked) { turn in
                    // The turn rail's preview names an attachment-only turn the same way.
                    Button(turn.prompt.isEmpty ? L("Attachment") : String(turn.prompt.prefix(80))) {
                        if let index = navigator.snapshot.turns.firstIndex(where: { $0.id == turn.id }) {
                            navigator.select(index)
                        }
                    }
                }
            } label: {
                Image(systemName: "bookmark.fill").font(.system(size: 12))
                    .frame(width: 30, height: 30)
                    .workbenchFloatingSurface()
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(WorkbenchTheme.Stroke.hairline)))
                    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("已收藏的轮次").accessibilityLabel("已收藏的轮次")
        }
    }
}

private struct ConversationTurnRail: View {
    let turns: [ConversationTurnSummary]
    let current: Int
    let hasOlderHistory: Bool
    let selectedID: String?
    @ObservedObject var hover: ConversationTurnHover
    let select: (Int) -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A lens transition glides painted ticks from the previous mapping to the
    /// committed one; nil means settled. Selection always uses the committed
    /// mapping, so motion never moves hit targets.
    @State private var glideFrom: ConversationTurnRailGeometry?
    @State private var glideProgress: Double = 1
    private let railWidth: CGFloat = 32
    private var count: Int { turns.count }

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - 32)
            let plain = ConversationTurnRailGeometry(count: count, height: height)
            let layout = ConversationTurnRailGeometry(count: count, height: height, focus: hover.focus)
            let selected = selectedID.flatMap { id in turns.firstIndex { $0.id == id } }
            let availableWidth = max(1, geometry.size.width - railWidth - 12)
            ZStack(alignment: .topLeading) {
                ConversationTurnMarks(layout: layout, from: glideFrom, progress: glideProgress,
                                      current: current, selected: selected,
                                      hovered: hover.index, focus: hover.focus?.index, keyboardFocused: focused,
                                      reduceMotion: reduceMotion)
                .frame(width: railWidth, height: layout.height)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hover.move(y: point.y, count: count, height: height)
                    case .ended: hover.leave()
                    }
                }
                .onTapGesture { point in
                    focused = true
                    select(layout.index(at: point.y))
                }
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.upArrow) { hover.reset(); select(max(0, (selected ?? current) - 1)); return .handled }
                .onKeyPress(.downArrow) { hover.reset(); select(min(count - 1, (selected ?? current) + 1)); return .handled }
                .onKeyPress(.escape) { focused = false; hover.reset(); return .handled }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(hasOlderHistory ? "Loaded conversation turns" : "Conversation turns"))
                .accessibilityValue(Text("\(current + 1) / \(count): \(turns[current].prompt)"))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: select(min(count - 1, current + 1))
                    case .decrement: select(max(0, current - 1))
                    @unknown default: break
                    }
                }
                if let index = hover.index, let previewY = hover.previewY, turns.indices.contains(index) {
                    let turn = turns[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(index + 1) / \(count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                        Group {
                            if turn.prompt.isEmpty { Text("Attachment") }
                            else { Text(turn.prompt) }
                        }.font(.system(size: 12, weight: .medium)).lineLimit(2)
                        if !turn.reply.isEmpty {
                            Text(turn.reply).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .transaction { $0.animation = nil } // Neighbor text changes without crossfading.
                    .padding(12).frame(width: min(340, availableWidth), height: 136, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card)
                        .strokeBorder(.primary.opacity(WorkbenchTheme.Stroke.hairline)))
                    .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
                    .offset(x: railWidth, y: min(max(0, previewY - 28), max(0, height - 136)))
                    .allowsHitTesting(false).accessibilityHidden(true)
                    .transition(.opacity)
                }
            }.padding(.vertical, 16)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover.previewY != nil)
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: glideProgress)
                .onChange(of: hover.focus) { old, focus in
                    guard !reduceMotion else { glideFrom = nil; glideProgress = 1; return }
                    // Glide from the mapping the pointer just left: the resting
                    // rail, the previous lens, or the lens mid-scan.
                    glideFrom = old.map { ConversationTurnRailGeometry(count: count, height: height, focus: $0) } ?? plain
                    withTransaction(Transaction(animation: nil)) { glideProgress = 0 }
                    withAnimation(.smooth(duration: 0.22)) { glideProgress = 1 }
                }
                .onChange(of: height) { _, _ in hover.reset() }
                .onDisappear { hover.reset() }
        }
    }
}

/// Bounded drawing for dense histories. Painted ticks interpolate from the
/// previous mapping to the committed one while a transition runs; selection
/// and committed marks always use the committed mapping, so motion never
/// moves targets.
private struct ConversationTurnMarks: View {
    let layout: ConversationTurnRailGeometry
    let from: ConversationTurnRailGeometry?
    let progress: Double
    let current: Int
    let selected: Int?
    let hovered: Int?
    let focus: Int?
    let keyboardFocused: Bool
    let reduceMotion: Bool
    /// Where a tick is drawn this frame: settled on the committed mapping, or
    /// gliding from the previous one.
    private func paintedY(for index: Int) -> CGFloat {
        let target = layout.y(for: index)
        guard let from, progress < 1 else { return target }
        return from.y(for: index) + (target - from.y(for: index)) * progress
    }
    var body: some View {
        ZStack {
            Canvas { context, _ in
                for y in layout.ticks {
                    let index = layout.index(at: y)
                    let strength = focus.map { layout.expanded.contains(index) ? max(0, 1 - CGFloat(abs(index - $0)) / 5) : 0 } ?? 0
                    let width = 7 + 6 * strength
                    context.fill(Path(roundedRect: CGRect(x: 16 - width / 2, y: paintedY(for: index), width: width, height: 2), cornerRadius: 1),
                                 with: .color(.primary.opacity(0.24 + 0.12 * Double(strength))))
                }
            }
            // Opacity is composited without rebuilding paths every animation
            // frame. Hit targets and the current/selected marker never animate.
            .opacity(focus == nil ? 0.75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: focus != nil)
            Canvas { context, _ in
                func tick(y: CGFloat, width: CGFloat, opacity: Double, height: CGFloat = 2) {
                    context.fill(Path(roundedRect: CGRect(x: 16 - width / 2, y: y, width: width, height: height), cornerRadius: height / 2),
                                 with: .color(.primary.opacity(opacity)))
                }
                if let hovered, hovered != selected {
                    let y = paintedY(for: hovered)
                    context.fill(Path(roundedRect: CGRect(x: 4, y: y - 6, width: 24, height: 14), cornerRadius: WorkbenchTheme.Radius.chip),
                                 with: .color(.primary.opacity(WorkbenchTheme.Fill.hover)))
                    tick(y: y, width: 14, opacity: 0.55)
                }
                tick(y: layout.y(for: current), width: 20, opacity: 0.85)
                if keyboardFocused {
                    let y = layout.y(for: selected ?? current)
                    context.stroke(Path(roundedRect: CGRect(x: 3, y: y - 7, width: 26, height: 16), cornerRadius: WorkbenchTheme.Radius.chip),
                                   with: .color(.primary.opacity(0.18)), lineWidth: 1)
                }
                if let selected {
                    let y = layout.y(for: selected)
                    context.fill(Path(roundedRect: CGRect(x: 3, y: y - 7, width: 26, height: 16), cornerRadius: WorkbenchTheme.Radius.chip),
                                 with: .color(.primary.opacity(WorkbenchTheme.Fill.selected)))
                    tick(y: y, width: 20, opacity: 1, height: 2.5)
                }
            }
        }
    }
}
