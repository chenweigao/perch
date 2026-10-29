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
                }.font(.system(size: ReplyStyle.labelSize, weight: .medium))
                    .padding(.horizontal, hasNewReply ? 12 : 0)
                    .frame(width: hasNewReply ? nil : 32, height: 32)
                    .workbenchFloatingSurface()
                    .overlay(Capsule().fill(hovered && isVisible ? WorkbenchTheme.Fill.hover : .clear))
                    .overlay(Capsule().strokeBorder(WorkbenchTheme.Stroke.hairline))
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
///
/// `bar` (activity bar, notices and the composer) floats over the transcript's
/// bottom edge as a safe-area bar: the reply scrolls beneath the composer glass
/// with a soft fade, and the tail stops above the bar. A fixed top gutter keeps
/// scrolled text away from the sheet's rounded top edge without an extra overlay.
struct ConversationScrollView<Content: View, Bar: View>: View {
    var showsScrollIndicator = false
    var hasOlderHistory = false
    var onScroll: (Bool) -> Void = { _ in }
    var onContentSizeChange: () -> Void = {}
    var onNearTop: () -> Void = {}
    var showsReturnToLatest = false
    var hasNewReply = false
    var onReturnToLatest: (() -> Void)? = nil
    let content: Content
    let bar: Bar
    @State private var contentSize = CGSize.zero
    @State private var conversationViewport = ConversationViewport()

    init(showsScrollIndicator: Bool = false, hasOlderHistory: Bool = false,
         onScroll: @escaping (Bool) -> Void = { _ in }, onContentSizeChange: @escaping () -> Void = {},
         onNearTop: @escaping () -> Void = {}, showsReturnToLatest: Bool = false, hasNewReply: Bool = false,
         onReturnToLatest: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder bar: () -> Bar) {
        self.showsScrollIndicator = showsScrollIndicator
        self.hasOlderHistory = hasOlderHistory
        self.onScroll = onScroll
        self.onContentSizeChange = onContentSizeChange
        self.onNearTop = onNearTop
        self.showsReturnToLatest = showsReturnToLatest
        self.hasNewReply = hasNewReply
        self.onReturnToLatest = onReturnToLatest
        self.content = content()
        self.bar = bar()
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: ReplyStyle.entrySpacing) { content }
                    .environment(\.conversationViewport, conversationViewport)
                    .padding(.vertical, 12)
                    .frame(width: min(ReplyStyle.readingWidth, max(1, viewport.size.width - 2 * ReplyStyle.horizontalPadding)), alignment: .leading)
                    // Center the reading column in the card's current viewport.
                    // Opening the inspector changes this viewport, not host identity.
                    .padding(.horizontal, ReplyStyle.horizontalPadding)
                    .frame(width: viewport.size.width, alignment: .center)
                    .coordinateSpace(name: "conversation-content")
                    .background {
                        ConversationScrollObserver(onScroll: { following in
                            conversationViewport.userScrolled()
                            onScroll(following)
                        }, onNearTop: onNearTop)
                    }
            }.scrollIndicators(showsScrollIndicator ? .automatic : .hidden, axes: .vertical)
                .scrollEdgeEffectHidden(true, for: .top)
                .background(ConversationViewportView(viewport: conversationViewport, onPauseFollowing: { onScroll(false) }, onNearTop: onNearTop))
                .overlay(alignment: .leading) {
                    ConversationTurnNavigator(model: conversationViewport.navigator, hasOlderHistory: hasOlderHistory)
                }
                .modifier(ConversationBottomBar(bar: bar, controls: floatingControls))
        }.padding(.top, WorkbenchTheme.Reading.topGutter)
    }

    /// Bookmarks and return-to-latest float just above the bar (or the bottom
    /// edge without one). Only the controls themselves take clicks; there is no
    /// reserved footer or full-width surface intercepting the reading area.
    private var floatingControls: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                ConversationBookmarksMenu(navigator: conversationViewport.navigator)
                    .padding(.leading, 40)
                Spacer(minLength: 0)
            }.padding(.bottom, 6)
            if let onReturnToLatest {
                ReturnToLatestButton(isVisible: showsReturnToLatest, hasNewReply: hasNewReply, action: onReturnToLatest)
                    .padding(.bottom, 8)
            }
        }.frame(maxWidth: .infinity)
    }

    var body: some View {
        transcript.onScrollGeometryChange(for: CGSize.self) { $0.contentSize } action: { _, size in
            contentSize = size
        }.task(id: contentSize) {
            await Task.yield()
            if !Task.isCancelled { onContentSizeChange() }
        }
    }
}

extension ConversationScrollView where Bar == EmptyView {
    init(showsScrollIndicator: Bool = false, hasOlderHistory: Bool = false,
         onScroll: @escaping (Bool) -> Void = { _ in }, onContentSizeChange: @escaping () -> Void = {},
         onNearTop: @escaping () -> Void = {}, showsReturnToLatest: Bool = false, hasNewReply: Bool = false,
         onReturnToLatest: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(showsScrollIndicator: showsScrollIndicator, hasOlderHistory: hasOlderHistory,
                  onScroll: onScroll, onContentSizeChange: onContentSizeChange, onNearTop: onNearTop,
                  showsReturnToLatest: showsReturnToLatest, hasNewReply: hasNewReply,
                  onReturnToLatest: onReturnToLatest, content: content, bar: { EmptyView() })
    }
}

/// Without a bar the floating controls sit on the transcript's bottom edge. With
/// one, the bar becomes the scroll view's bottom safe-area bar, so content insets
/// and scroll-to-bottom follow its height, and the controls ride on its top edge.
///
/// The system scroll-edge effect is off: inside the workspace's split view macOS
/// draws it as a hard pocket with a divider across the card, whatever style is
/// asked for. A plain gradient in the card's own color fades the reply into the
/// bar instead — no divider, no offscreen mask over the transcript.
private struct ConversationBottomBar<Bar: View, Controls: View>: ViewModifier {
    let bar: Bar
    let controls: Controls
    static var fadeHeight: CGFloat { 28 }
    @ViewBuilder func body(content: Content) -> some View {
        if Bar.self == EmptyView.self {
            content.overlay(alignment: .bottom) { controls }
        } else {
            content
                .scrollEdgeEffectHidden(true, for: .bottom)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    bar.frame(maxWidth: .infinity)
                        .background(alignment: .bottom) {
                            VStack(spacing: 0) {
                                LinearGradient(colors: [WorkbenchTheme.contentBackground.opacity(0),
                                                        WorkbenchTheme.contentBackground],
                                               startPoint: .top, endPoint: .bottom)
                                    .frame(height: Self.fadeHeight)
                                WorkbenchTheme.contentBackground
                            }
                            .padding(.top, -Self.fadeHeight)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                        .overlay(alignment: .top) {
                            controls.alignmentGuide(.top) { $0[.bottom] }
                        }
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
                                 selected: model.selectedID.flatMap { id in model.snapshot.turns.firstIndex { $0.id == id } },
                                 hover: model.hover, select: model.select)
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
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(WorkbenchTheme.Stroke.hairline))
                    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("已收藏的轮次").accessibilityLabel("已收藏的轮次")
        }
    }
}

struct ConversationTurnRail: View {
    let turns: [ConversationTurnSummary]
    let current: Int
    let hasOlderHistory: Bool
    let selected: Int?
    @ObservedObject var hover: ConversationTurnHover
    let select: (Int) -> Void
    let reduceMotionOverride: Bool?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.conversationReduceMotion) private var conversationReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? (systemReduceMotion || conversationReduceMotion) }
    private let railWidth: CGFloat = 32
    private var count: Int { turns.count }

    init(turns: [ConversationTurnSummary], current: Int, hasOlderHistory: Bool, selected: Int?,
         hover: ConversationTurnHover, select: @escaping (Int) -> Void, reduceMotionOverride: Bool? = nil) {
        self.turns = turns; self.current = current; self.hasOlderHistory = hasOlderHistory
        self.selected = selected; self.hover = hover; self.select = select
        self.reduceMotionOverride = reduceMotionOverride
    }

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - 32)
            let layout = ConversationTurnRailGeometry(count: count, height: height, focus: hover.focus)
            let availableWidth = max(1, geometry.size.width - railWidth - 12)
            ZStack(alignment: .topLeading) {
                ConversationTurnMarks(layout: layout, current: current, selected: selected,
                                      hovered: hover.index, keyboardFocused: focused)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hover.focus)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: hover.index)
                .frame(width: railWidth, height: layout.height)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hover.move(y: point.y, count: count, height: height)
                    case .ended: hover.leave()
                    }
                }
                .onTapGesture { point in
                    if !focused { focused = true }
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
                    ConversationTurnPreviewPlacement(anchorY: previewY, railWidth: railWidth) {
                        ConversationTurnPreview(turn: turns[index])
                            .frame(width: min(340, availableWidth))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                    .transition(.opacity)
                }
            }.padding(.vertical, 16)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover.previewY != nil)
                .onChange(of: height) { _, _ in hover.reset() }
                .onDisappear { hover.reset() }
        }
    }
}

/// Intrinsic-height text, without a counter or actions competing with the excerpt.
struct ConversationTurnPreview: View {
    let turn: ConversationTurnSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if turn.prompt.isEmpty { Text("Attachment") }
                else { Text(turn.prompt) }
            }.font(.system(size: ReplyStyle.labelSize, weight: .medium)).lineLimit(1)
            if !turn.reply.isEmpty {
                Text(turn.reply).font(.system(size: ReplyStyle.labelSize))
                    .foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card)
            .strokeBorder(WorkbenchTheme.Stroke.hairline))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

/// Measure and clamp in the same layout pass, including the first hover at the
/// bottom edge. No geometry-to-state feedback or fixed empty card height.
private struct ConversationTurnPreviewPlacement: Layout {
    let anchorY: CGFloat
    let railWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let size = card.sizeThatFits(.unspecified)
        let y = min(max(0, anchorY - 24), max(0, bounds.height - size.height))
        card.place(at: CGPoint(x: bounds.minX + railWidth + 8, y: bounds.minY + y),
                   proposal: ProposedViewSize(size))
    }
}

/// Only the bounded Canvas interpolates. Fractional band boundaries preserve
/// continuity when a lens opens, moves, reverses or closes mid-animation.
/// Hit testing continues to use the committed geometry, never animated targets.
private struct ConversationTurnMarks: View, Animatable {
    let layout: ConversationTurnRailGeometry
    let current: Int
    let selected: Int?
    let hovered: Int?
    let keyboardFocused: Bool
    var top: CGFloat
    var bottom: CGFloat
    var lower: CGFloat
    var upper: CGFloat
    var emphasis: CGFloat
    var hoverPosition: CGFloat

    init(layout: ConversationTurnRailGeometry, current: Int, selected: Int?, hovered: Int?, keyboardFocused: Bool) {
        self.layout = layout; self.current = current; self.selected = selected
        self.hovered = hovered; self.keyboardFocused = keyboardFocused
        top = layout.top; bottom = layout.bottom
        lower = CGFloat(layout.expanded.lowerBound); upper = CGFloat(layout.expanded.upperBound)
        emphasis = hovered == nil ? 0 : 1
        hoverPosition = CGFloat(hovered ?? current)
    }

    typealias AnimatableData = AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>>
    var animatableData: AnimatableData {
        get { .init(.init(top, bottom), .init(.init(lower, upper), .init(emphasis, hoverPosition))) }
        set {
            top = newValue.first.first; bottom = newValue.first.second
            lower = newValue.second.first.first; upper = newValue.second.first.second
            emphasis = newValue.second.second.first; hoverPosition = newValue.second.second.second
        }
    }

    private func paintedY(for index: Int) -> CGFloat {
        let center = CGFloat(index) + 0.5
        if center < lower { return center * top / lower }
        if center >= upper {
            return bottom + (center - upper) * (layout.height - bottom) / (CGFloat(layout.count) - upper)
        }
        return top + (center - lower) * (bottom - top) / (upper - lower)
    }

    var body: some View {
        Canvas { context, _ in
            #if TRANSCRIPT_CHECKS
            ConversationTurnRailProbe.sample?(emphasis, hoverPosition)
            #endif
            func tick(y: CGFloat, width: CGFloat, opacity: Double, height: CGFloat = 2) {
                context.fill(Path(roundedRect: CGRect(x: 16 - width / 2, y: y, width: width, height: height), cornerRadius: height / 2),
                             with: .color(.primary.opacity(opacity)))
            }
            for y in layout.ticks {
                let index = layout.index(at: y)
                let strength = max(0, 1 - abs(CGFloat(index) - hoverPosition) / 5) * emphasis
                tick(y: paintedY(for: index), width: 7 + 9 * strength,
                     opacity: 0.20 + 0.22 * Double(strength))
            }
            // Separate hover/current/selection layers can coexist. Centering
            // every width around x=16 keeps the rail from shifting sideways.
            if let hovered, hovered != selected {
                let y = paintedY(for: hovered)
                context.fill(Path(roundedRect: CGRect(x: 4, y: y - 6, width: 24, height: 14), cornerRadius: WorkbenchTheme.Radius.chip),
                             with: .color(WorkbenchTheme.Fill.hover.opacity(Double(emphasis))))
                tick(y: y, width: 16, opacity: 0.55 * Double(emphasis))
            }
            tick(y: paintedY(for: current), width: 20, opacity: 0.85)
            if keyboardFocused {
                let y = paintedY(for: selected ?? current)
                context.stroke(Path(roundedRect: CGRect(x: 3, y: y - 7, width: 26, height: 16), cornerRadius: WorkbenchTheme.Radius.chip),
                               with: .color(.primary.opacity(0.18)), lineWidth: 1)
            }
            if let selected {
                let y = paintedY(for: selected)
                context.fill(Path(roundedRect: CGRect(x: 3, y: y - 7, width: 26, height: 16), cornerRadius: WorkbenchTheme.Radius.chip),
                             with: .color(WorkbenchTheme.Fill.selected))
                tick(y: y, width: 20, opacity: 1, height: 2.5)
            }
        }
    }
}

#if TRANSCRIPT_CHECKS
/// Fixture-only render samples; absent from the shipping app. This verifies
/// interpolation reaches Canvas, not merely that state toggled its endpoints.
enum ConversationTurnRailProbe {
    static var sample: ((CGFloat, CGFloat) -> Void)?
}
#endif
