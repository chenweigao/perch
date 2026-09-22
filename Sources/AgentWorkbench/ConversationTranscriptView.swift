import AppKit
import SwiftUI
import WorkbenchCore

#if TRANSCRIPT_CHECKS
/// Nested stages are reported separately; their durations must not be summed.
enum NavigationRenderMetrics {
    static var stages: [String: (count: Int, ms: Double)] = [:]
    static func record(_ stage: String, since start: TimeInterval) {
        let old = stages[stage] ?? (0, 0)
        stages[stage] = (old.count + 1, old.ms + (CACurrentMediaTime() - start) * 1_000)
    }
    static var report: [String: Any] {
        stages.mapValues { ["count": $0.count, "ms": $0.ms] as [String: Any] }
    }
}
#endif

private let kimiPaper = Color.primary.opacity(0.035)

struct KimiMessageView: View {
    let message: KimiMessage
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    private var isUserMessage: Bool {
        message.role == "user" && !message.content.allSatisfy(\.isRuntimeContext)
    }
    private func runtimeContext(_ text: String) -> some View {
        DisclosureGroup("运行上下文") { KimiMarkdown(text: text) }.disclosureGroupStyle(WorkbenchDisclosureStyle(horizontalPadding: 0)).font(.system(size: 12)).foregroundStyle(.secondary)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            ForEach(Array(message.content.enumerated()), id: \.offset) { _, part in
                switch part.type {
                case "text":
                    if let split = part.skillContextSplit {
                        KimiMarkdown(text: split.prefix).environment(\.isConversationBodyText, true)
                        runtimeContext(split.context)
                    } else if part.isRuntimeContext {
                        runtimeContext(part.text ?? "")
                    } else { KimiMarkdown(text: part.text ?? "").environment(\.isConversationBodyText, true) }
                case "thinking": ThoughtDisclosure(text: part.thinking ?? "")
                case "tool_use":
                    if let tool = tools[part.toolCallId ?? ""] { KimiToolCard(tool: tool) }
                case "image", "file", "video":
                    KimiAttachmentView(part: part, api: api, sessionId: sessionId)
                default: EmptyView()
                }
            }
        }.padding(isUserMessage ? 15 : 0)
            .background(isUserMessage ? kimiPaper : .clear, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
            .padding(.leading, isUserMessage ? 65 : 0)
            .padding(.vertical, isUserMessage ? 10 : 0)
    }
}

/// Supplies individually identified rows to the conversation viewport.
/// Keep historical rows equatable so live tokens only invalidate their own content.
struct ConversationTranscript: View {
    let messages: [KimiMessage]
    var api: KimiAPI? = nil
    let sessionId: String
    var running: Set<String> = []
    var isRunning = false
    var liveTools: [KimiLiveTool] = []
    var online = true
    var memoryKey: String?
    // Preview/benchmark transcripts never invoke a user's configured service.
    var allowsActivitySummaries = false
    var followsLatest = true
    @State private var toolProjection = ToolVisibilityProjection()
    @State private var projection = ConversationProjection()
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @StateObject private var summaryController = ActivitySummaryController()
    @Environment(\.self) private var environment
    @State private var measured: (session: String, height: CGFloat)?
    @State private var contentOriginY: CGFloat = 0
    var body: some View {
        let visible = toolProjection.update(messages, sessionID: sessionId, live: liveTools, running: running, online: online)
        let snapshot = projection.update(visible.messages, isRunning: isRunning)
        let batch = ActivitySummaryBatch.latest(in: snapshot.entries, tools: visible.tools,
            isRunning: isRunning, enabled: summarySettings.configuration.enabled && allowsActivitySummaries && online)
        let observation = SummaryObservation(session: memoryKey ?? sessionId, batch: batch,
            running: isRunning, online: online && allowsActivitySummaries, following: followsLatest,
            settingsRevision: summarySettings.revision)
        let contents = snapshot.entries.map { entry in
            let ids = Set(entry.messages.flatMap(\.content).compactMap(\.toolCallId))
            let tools = ids.reduce(into: [String: VisibleTool]()) { result, id in
                if let value = visible.tools[id] { result[id] = value }
            }
            let summary = summarySettings.configuration.enabled ? summaryController.summaries[entry.id] : nil
            return ConversationEntryView(entry: entry, tools: tools, api: api, sessionId: sessionId,
                memoryKey: (memoryKey ?? sessionId) + ":" + entry.id, activitySummary: summary)
        }
        ConversationDocumentHost(contents: contents, navigation: snapshot.navigation, sessionId: memoryKey ?? sessionId,
                                 appearance: ConversationEntryAppearance(environment),
                                 viewport: environment.conversationViewport,
                                 contentOriginY: contentOriginY) { height in
            measured = (sessionId, height)
        }.frame(height: measured?.session == sessionId ? measured?.height : nil)
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named("conversation-content")).minY
            } action: { contentOriginY = $0 }
            .task(id: observation) {
                summaryController.observe(session: observation.session, batch: batch, running: isRunning,
                                          online: observation.online, following: followsLatest, settings: summarySettings)
            }
            .onDisappear { summaryController.cancel() }
    }
    private struct SummaryObservation: Hashable {
        let session: String
        let batch: ActivitySummaryBatch?
        let running: Bool
        let online: Bool
        let following: Bool
        let settingsRevision: Int
    }
}

private struct ConversationDocumentHost: NSViewRepresentable {
    let contents: [ConversationEntryView]
    let navigation: [ConversationTurnSummary]
    let sessionId: String
    let appearance: ConversationEntryAppearance
    let viewport: ConversationViewport?
    let contentOriginY: CGFloat
    let heightChanged: (CGFloat) -> Void
    func makeNSView(context: Context) -> ConversationDocumentView { ConversationDocumentView() }
    func updateNSView(_ view: ConversationDocumentView, context: Context) {
        view.heightChanged = heightChanged
        view.configure(contents, navigation: navigation, sessionId: sessionId, appearance: appearance,
                       viewport: viewport, contentOriginY: contentOriginY)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ConversationDocumentView, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
    static func dismantleNSView(_ view: ConversationDocumentView, coordinator: ()) {
        view.prepareForRemoval()
    }
}

/// Reserve history geometry, but only instantiate hosts intersecting the viewport.
/// Actual measurements replace estimates as rows are read. Only nearby controllers
/// survive detachment; disclosure state lives in ConversationReadingMemory.
private final class ConversationDocumentView: NSView {
    private var contents: [ConversationEntryView] = []
    private var indices: [String: Int] = [:]
    private var navigation: [ConversationTurnSummary] = []
    private var turnRows: [Int] = []
    private var heights: [CGFloat] = []
    private var geometry = ConversationRowGeometry(heights: [])
    private var offsets: [CGFloat] { geometry.offsets }
    private var controllers: [String: ConversationEntryController] = [:]
    private var mounted: Set<String> = []
    private var laidOutRange: Range<Int>?
    private static let retiredControllers = NSMutableArray()
    private static var drainingRetiredControllers = false
    private var sessionId = ""
    private var restoreTarget: ConversationReadingMemory.Position?
    private var rowAppearance: ConversationEntryAppearance?
    private weak var viewport: ConversationViewport?
    private var columnWidth: CGFloat = ReplyStyle.readingWidth
    private var disclosureRow: String?
    private var heightAnimation: (id: String, from: CGFloat, to: CGFloat, start: TimeInterval)?
    private var heightTimer: Timer?
    private var refreshing = false
    private var contentOriginY: CGFloat = 0
    private var publishedHeight: CGFloat?
    private var publicationScheduled = false
    private weak var observedClip: NSClipView?
    private var boundsObserver: NSObjectProtocol?
    var totalHeight: CGFloat { geometry.totalHeight }
    private var findObserver: NSObjectProtocol?
    #if TRANSCRIPT_CHECKS
    fileprivate var navigator: ConversationTurnNavigation? { viewport?.navigator }
    fileprivate var retainedHostCount: Int { controllers.count }
    fileprivate var mountedHostCount: Int { mounted.count }
    fileprivate static var retiredHostCount: Int { retiredControllers.count }
    fileprivate var readingAnchor: (entry: String, offset: CGFloat)? {
        guard let row = geometry.readingRow(at: viewportRect.minY), contents.indices.contains(row) else { return nil }
        return (contents[row].entry.id, viewportRect.minY - offsets[row])
    }
    #endif
    override init(frame: NSRect) {
        super.init(frame: frame)
        findObserver = NotificationCenter.default.addObserver(forName: .init("PerchRevealConversationHit"), object: nil, queue: .main) { [weak self] notice in
            guard let self, let target = notice.object as? ConversationFindTarget, target.session == self.sessionId else { return }
            self.reveal(target)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func reveal(_ target: ConversationFindTarget) {
        revealEntry(target.hit.entryID)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionId == target.session,
                  let view = self.controllers[target.hit.entryID]?.view else { return }
            // A newly mounted host may not have created its native text views yet.
            // Complete that host's layout before looking for the selected range.
            view.layoutSubtreeIfNeeded()
            var remaining = target.hit.occurrence
            func select(in view: NSView) -> Bool {
                if let text = view as? ReplyTextView, text.isConversationBodyText {
                    let source = text.string as NSString
                    var search = NSRange(location: 0, length: source.length)
                    while search.length > 0 {
                        let found = source.range(of: target.query, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                        if found.location == NSNotFound { break }
                        if remaining == 0 { text.setSelectedRange(found); text.showFindIndicator(for: found); text.scrollRangeToVisible(found); return true }
                        remaining -= 1
                        search = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
                    }
                }
                return view.subviews.contains { select(in: $0) }
            }
            _ = select(in: view)
        }
    }
    private func revealEntry(_ id: String, highlight: Bool = false) {
        guard let index = indices[id], let clip = observedClip else { return }
        ConversationReadingMemory.shared.following[sessionId] = false
        viewport?.pauseFollowing?()
        clip.scroll(to: NSPoint(x: 0, y: max(0, offsets[index] + contentOriginY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
        refreshVisibleRows()
        if highlight, let view = controllers[id]?.view {
            let marker = CALayer()
            marker.frame = view.bounds.insetBy(dx: 1, dy: 1)
            marker.cornerRadius = 12
            marker.borderWidth = 1
            marker.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
            marker.actions = ["opacity": NSNull()]
            view.layer?.addSublayer(marker)
            if rowAppearance?.reduceMotion != true {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.6
                marker.add(fade, forKey: "arrival")
                marker.opacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { marker.removeFromSuperlayer() }
        }
        saveReadingPosition()
        viewport?.refresh()
    }

    fileprivate func updateNavigator() {
        let row = geometry.readingRow(at: max(0, viewportRect.minY)) ?? 0
        var lower = 0, upper = turnRows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if turnRows[middle] <= row { lower = middle + 1 } else { upper = middle }
        }
        viewport?.navigator.update(session: sessionId, turns: navigation, current: max(0, lower - 1))
        viewport?.navigator.reveal = { [weak self] id in self?.revealEntry(id, highlight: true) }
    }
    var heightChanged: (CGFloat) -> Void = { _ in }
    override var isFlipped: Bool { true }

    func configure(_ next: [ConversationEntryView], navigation: [ConversationTurnSummary], sessionId: String,
                   appearance: ConversationEntryAppearance, viewport: ConversationViewport?,
                   contentOriginY: CGFloat) {
        // An older page changes every subsequent row's y, but not the reader's
        // message or offset inside it. Capture using the outgoing geometry.
        if self.sessionId == sessionId, let first = contents.first?.entry.id,
           next.first?.entry.id != first, next.contains(where: { $0.entry.id == first }) {
            saveReadingPosition()
            restoreTarget = ConversationReadingMemory.shared.positions[sessionId]
        }
        if self.viewport !== viewport {
            self.viewport?.remove(self)
            self.viewport = viewport
            viewport?.add(self)
        }
        if self.sessionId != sessionId {
            cancelHeightAnimation()
            saveReadingPosition()
            saveReadingHeights()
            restoreTarget = ConversationReadingMemory.shared.following[sessionId] == false ? ConversationReadingMemory.shared.positions[sessionId] : nil
            for id in mounted { controllers[id]?.view.removeFromSuperview() }
            Self.retire(Array(controllers.values))
            controllers.removeAll()
            mounted.removeAll()
            indices.removeAll()
            heights.removeAll()
            contents.removeAll()
            publishedHeight = nil
            self.sessionId = sessionId
        }
        self.contentOriginY = contentOriginY
        let previous = Dictionary(uniqueKeysWithValues: zip(contents.map { $0.entry.id }, heights))
        contents = next
        indices = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.entry.id, $0.offset) })
        self.navigation = navigation
        turnRows = navigation.compactMap { indices[$0.id] }
        heights = next.map { previous[$0.entry.id] ?? ConversationReadingMemory.shared.measuredHeights[sessionId]?[$0.entry.id] ?? 160 }
        self.rowAppearance = appearance
        for id in Array(controllers.keys) {
            guard let index = indices[id] else {
                controllers.removeValue(forKey: id)?.view.removeFromSuperview()
                mounted.remove(id)
                continue
            }
            controllers[id]?.update(next[index], appearance: appearance)
        }
        rebuildOffsets()
        observeScroll()
        restoreReadingPosition()
        refreshVisibleRows()
        publishHeight()
        viewport?.refresh()
    }
    /// Releasing hundreds of hosting graphs in the selection transaction stalls
    /// the main thread. Drain a small batch between frames, on AppKit's thread.
    func prepareForRemoval() {
        cancelHeightAnimation()
        saveReadingPosition()
        saveReadingHeights()
        for id in mounted { controllers[id]?.view.removeFromSuperview() }
        Self.retire(Array(controllers.values))
        controllers.removeAll()
        mounted.removeAll()
        viewport?.remove(self)
    }
    private static func retire(_ old: [ConversationEntryController]) {
        guard !old.isEmpty else { return }
        // A queued geometry callback from a retired host must not resize a new
        // host for the same row (or the next session) while destruction drains.
        for controller in old { controller.heightChanged = { _ in } }
        // A single drain bounds total release work even during rapid switches.
        // Mutable reference storage releases each graph when it is removed.
        retiredControllers.addObjects(from: old)
        guard !drainingRetiredControllers else { return }
        drainingRetiredControllers = true
        Task { @MainActor in
            while retiredControllers.count > 0 {
                // Short slices also need prompt rescheduling so retired graphs do not accumulate.
                try? await Task.sleep(for: .milliseconds(1))
                let deadline = ProcessInfo.processInfo.systemUptime + 0.002
                for _ in 0..<min(4, retiredControllers.count) {
                    // Drain each graph's autoreleases before checking elapsed time.
                    // Four complex rows must not consume one long main-thread slice.
                    autoreleasepool { retiredControllers.removeLastObject() }
                    if ProcessInfo.processInfo.systemUptime >= deadline { break }
                }
            }
            drainingRetiredControllers = false
        }
    }

    func measure(width: CGFloat?) -> CGSize {
        let nextWidth = max(1, width?.isFinite == true ? width! : ReplyStyle.readingWidth)
        if columnWidth != nextWidth {
            // AppKit can adjust the clip origin when wrapping changes, even if
            // no row above the reader changes height. Capture before measuring.
            if ConversationReadingMemory.shared.following[sessionId] == false, restoreTarget == nil {
                saveReadingPosition()
                let target = ConversationReadingMemory.shared.positions[sessionId]
                let session = sessionId
                // Finish AppKit's resize transaction before restoring; restoring
                // during measurement is overwritten by the clip-view adjustment.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionId == session, self.columnWidth == nextWidth,
                          ConversationReadingMemory.shared.following[session] == false else { return }
                    self.restoreTarget = target
                    self.restoreReadingPosition()
                }
            }
            laidOutRange = nil
        }
        columnWidth = nextWidth
        refreshVisibleRows()
        return CGSize(width: columnWidth, height: totalHeight)
    }
    private func rebuildOffsets() {
        laidOutRange = nil
        let spacing = contents.indices.map { index -> CGFloat in
            index + 1 < contents.count && contents[index].entry.isProcess && contents[index + 1].entry.isProcess ? 6 : 18
        }
        geometry = ConversationRowGeometry(heights: heights, spacingAfter: spacing)
    }
    private var viewportRect: CGRect {
        if let clip = observedClip {
            // Window conversion is transient while SwiftUI changes a tall
            // representable's size and origin. Both values here are in the
            // scroll content's logical coordinate space instead.
            return CGRect(x: 0, y: clip.bounds.minY - contentOriginY,
                          width: columnWidth, height: clip.bounds.height)
        }
        return CGRect(x: 0, y: 0, width: columnWidth, height: viewport?.view?.bounds.height ?? 600)
    }
    func refreshVisibleRows() {
        guard !refreshing, let appearance = rowAppearance, !contents.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        let visible = viewportRect
        var index = min(geometry.firstIntersecting(max(0, visible.minY)), contents.count - 1)
        let first = index
        let end = max(first, geometry.end(before: visible.maxY))
        // Most wheel deltas stay within the same rows. The clip view moves their
        // pixels; no hosting measurement, frame writes or reattachment is needed.
        if laidOutRange == first..<end { return }
        var nextMounted: Set<String> = []
        while index < contents.count && offsets[index] < visible.maxY {
            let content = contents[index]
            let id = content.entry.id
            let controller: ConversationEntryController
            if let existing = controllers[id] {
                controller = existing
            } else {
                controller = ConversationEntryController(content: content, appearance: appearance, disclosureChanged: { [weak self] animated in self?.beginDisclosureChange(id, animated: animated) }) { [weak self] height in
                    self?.rowHeightChanged(id, height: height)
                }
                controllers[id] = controller
            }
            // Give a cold host its real window and width before asking SwiftUI
            // for its size. Measuring detached builds a graph that attachment
            // immediately invalidates and lays out again.
            if controller.view.superview !== self {
                controller.layout(frame: CGRect(x: 0, y: offsets[index], width: columnWidth, height: heights[index]), contentHeight: heights[index])
                addSubview(controller.view)
            }
            let height = controller.measure(width: columnWidth).height
            updateHeight(id, height: height)
            controller.layout(frame: CGRect(x: 0, y: offsets[index], width: columnWidth, height: heights[index]), contentHeight: height)
            nextMounted.insert(id)
            index += 1
        }
        for id in mounted.subtracting(nextMounted) { controllers[id]?.view.removeFromSuperview() }
        mounted = nextMounted
        laidOutRange = first..<index
        let retained = geometry.retainedRows(around: first..<index)
        var retired: [ConversationEntryController] = []
        for id in Array(controllers.keys) where !mounted.contains(id) {
            if let row = indices[id], retained.contains(row) { continue }
            if let controller = controllers.removeValue(forKey: id) { retired.append(controller) }
        }
        Self.retire(retired)
        publishHeight()
    }
    private func beginDisclosureChange(_ id: String, animated: Bool) {
        laidOutRange = nil
        viewport?.pauseFollowing?()
        if let previous = heightAnimation, previous.id != id, let index = indices[previous.id] {
            heights[index] = previous.to
            rebuildOffsets()
        }
        cancelHeightAnimation()
        disclosureRow = animated ? id : nil
    }
    private func cancelHeightAnimation() {
        heightTimer?.invalidate(); heightTimer = nil
        heightAnimation = nil; disclosureRow = nil
    }
    private func updateHeight(_ id: String, height: CGFloat) {
        guard let index = indices[id], heightAnimation?.id != id, heights[index] != height else { return }
        if ConversationReadingMemory.shared.following[sessionId] == false,
           let reading = geometry.readingRow(at: viewportRect.minY), index < reading {
            saveReadingPosition()
            restoreTarget = ConversationReadingMemory.shared.positions[sessionId]
        }
        if disclosureRow == id {
            disclosureRow = nil
            heightAnimation = (id, heights[index], height, ProcessInfo.processInfo.systemUptime)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.advanceHeightAnimation() }
            heightTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            heights[index] = height
            rebuildOffsets()
        }
    }
    private func advanceHeightAnimation() {
        guard let animation = heightAnimation, let index = indices[animation.id] else { cancelHeightAnimation(); return }
        let progress = min(1, (ProcessInfo.processInfo.systemUptime - animation.start) / ConversationReadingMemory.disclosureDuration)
        let eased = progress * progress * (3 - 2 * progress)
        heights[index] = animation.from + (animation.to - animation.from) * eased
        if progress == 1 { cancelHeightAnimation() }
        rebuildOffsets()
        refreshVisibleRows()
        publishHeight()
    }
    private func rowHeightChanged(_ id: String, height: CGFloat) {
        updateHeight(id, height: height)
        publishHeight()
        restoreReadingPosition()
        viewport?.refresh()
    }
    private func publishHeight() {
        guard !publicationScheduled, publishedHeight != totalHeight else { return }
        publicationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publicationScheduled = false
            guard self.publishedHeight != self.totalHeight else { return }
            self.publishedHeight = self.totalHeight
            self.invalidateIntrinsicContentSize()
            self.heightChanged(self.totalHeight)
        }
    }
    override func setFrameSize(_ size: NSSize) {
        let changed = frame.size != size
        super.setFrameSize(size)
        if size.width > 0 {
            if columnWidth != size.width { laidOutRange = nil }
            columnWidth = size.width
        }
        if changed { viewport?.refresh() }
        restoreReadingPosition()
    }
    override func setFrameOrigin(_ point: NSPoint) {
        let changed = frame.origin != point
        super.setFrameOrigin(point)
        if changed { viewport?.refresh() }
    }
    override func layout() {
        super.layout()
        restoreReadingPosition()
    }
    private func saveReadingPosition() {
        guard restoreTarget == nil, !sessionId.isEmpty, let clip = observedClip,
              let index = geometry.readingRow(at: max(0, clip.bounds.minY - contentOriginY)),
              contents.indices.contains(index) else { return }
        ConversationReadingMemory.shared.positions[sessionId] = .init(entry: contents[index].entry.id,
            index: index, offset: clip.bounds.minY - contentOriginY - offsets[index])
    }
    private func saveReadingHeights() {
        guard !sessionId.isEmpty else { return }
        ConversationReadingMemory.shared.measuredHeights[sessionId] = Dictionary(uniqueKeysWithValues: zip(contents.map { $0.entry.id }, heights))
    }
    private func restoreReadingPosition() {
        guard let target = restoreTarget, let clip = observedClip, bounds.height >= totalHeight - 1, !contents.isEmpty else { return }
        let index = indices[target.entry] ?? min(target.index, contents.count - 1)
        let y = max(0, offsets[index] + target.offset + contentOriginY)
        clip.scroll(to: NSPoint(x: 0, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
        restoreTarget = nil
        refreshVisibleRows()
    }
    private func observeScroll() {
        let clip = enclosingScrollView?.contentView
        guard observedClip !== clip else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        observedClip = clip
        boundsObserver = nil
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
        ) { [weak self] _ in self?.viewport?.refresh(); self?.saveReadingPosition() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScroll()
        viewport?.refresh()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeScroll()
    }
    deinit {
        heightTimer?.invalidate()
        if let findObserver { NotificationCenter.default.removeObserver(findObserver) }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
}

#if TRANSCRIPT_CHECKS
extension ConversationTranscript {
    static func navigator(in root: NSView) -> ConversationTurnNavigation? {
        if let document = root as? ConversationDocumentView { return document.navigator }
        for view in root.subviews {
            if let navigation = navigator(in: view) { return navigation }
        }
        return nil
    }
    static func readingAnchor(in root: NSView) -> (entry: String, offset: CGFloat)? {
        if let document = root as? ConversationDocumentView { return document.readingAnchor }
        for view in root.subviews {
            if let anchor = readingAnchor(in: view) { return anchor }
        }
        return nil
    }
    /// Fixture-only inspection includes detached hosts, which a view-tree count misses.
    static func retainedHosts(in root: NSView) -> (retained: Int, mounted: Int, retired: Int)? {
        if let document = root as? ConversationDocumentView {
            return (document.retainedHostCount, document.mountedHostCount, ConversationDocumentView.retiredHostCount)
        }
        for view in root.subviews {
            if let counts = retainedHosts(in: view) { return counts }
        }
        return nil
    }
}
#endif

/// Only the environment values used by these rows cross the hosting boundary.
/// Value equality lets an appearance change update rows without resetting every
/// historical host on each streamed token.
private struct ConversationEntryAppearance: Equatable {
    let colorScheme: ColorScheme
    let layoutDirection: LayoutDirection
    let displayScale: CGFloat
    let dynamicTypeSize: DynamicTypeSize
    let reduceMotion: Bool
    let isEnabled: Bool
    init(_ environment: EnvironmentValues) {
        colorScheme = environment.colorScheme
        layoutDirection = environment.layoutDirection
        displayScale = environment.displayScale
        dynamicTypeSize = environment.dynamicTypeSize
        reduceMotion = environment.accessibilityReduceMotion || environment.conversationReduceMotion
        isEnabled = environment.isEnabled
    }
}

private struct HostedConversationEntry: View {
    let content: ConversationEntryView
    let appearance: ConversationEntryAppearance
    var disclosureChanged: (Bool) -> Void = { _ in }
    var sizeChanged: (CGSize) -> Void = { _ in }
    var body: some View {
        content.equatable().environment(\.conversationMemoryKey, content.memoryKey).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
            .environment(\.conversationDisclosureWillChange, disclosureChanged)
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.layoutDirection, appearance.layoutDirection)
            .environment(\.displayScale, appearance.displayScale)
            .environment(\.dynamicTypeSize, appearance.dynamicTypeSize)
            .environment(\.conversationReduceMotion, appearance.reduceMotion)
            .environment(\.isEnabled, appearance.isEnabled)
            // Match Perch's current ink and monochrome disclosure/control tint.
            .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.23))
            .tint(Color(red: 0.16, green: 0.16, blue: 0.17))
    }
}

private final class ConversationEntryController: NSViewController {
    private let host: NSHostingController<HostedConversationEntry>
    private var content: ConversationEntryView
    private var appearance: ConversationEntryAppearance
    private var generation = 0
    private var sizes: [(width: CGFloat, height: CGFloat)] = []
    private var pendingSize: (size: CGSize, generation: Int)?
    private var notificationScheduled = false
    private var publishedHeight: CGFloat?
    private var widthMeasurementScheduled = false
    var heightChanged: (CGFloat) -> Void
    private let disclosureChanged: (Bool) -> Void

    init(content: ConversationEntryView, appearance: ConversationEntryAppearance,
         disclosureChanged: @escaping (Bool) -> Void, heightChanged: @escaping (CGFloat) -> Void) {
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("host_create", since: start) }
        #endif
        self.content = content
        self.appearance = appearance
        self.heightChanged = heightChanged
        self.disclosureChanged = disclosureChanged
        host = NSHostingController(rootView: HostedConversationEntry(
            content: content, appearance: appearance))
        super.init(nibName: nil, bundle: nil)
        host.sizingOptions = []
        host.safeAreaRegions = []
        setRoot()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let container = ConversationEntryContainer()
        container.identifier = NSUserInterfaceItemIdentifier(content.entry.id)
        addChild(host)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.addSubview(host.view)
        container.widthChanged = { [weak self] in self?.committedWidthChanged() }
        // The row already owns its measured frame; its sole child fills it.
        // Avoid rebuilding an Auto Layout constraint graph on viewport changes.
        view = container
    }
    func layout(frame: CGRect, contentHeight: CGFloat) {
        view.frame = frame
        host.view.frame = CGRect(x: 0, y: 0, width: frame.width, height: contentHeight)
    }
    private func committedWidthChanged() {
        // A detached host cannot report geometry after a window/sidebar resize.
        // Measure the committed width after this layout pass, including offscreen
        // rows, so their reserved heights are correct before scrolling them in.
        guard !widthMeasurementScheduled else { return }
        widthMeasurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.widthMeasurementScheduled = false
            let width = self.view.bounds.width
            guard width > 0 else { return }
            let size = self.measure(width: width)
            self.report(size, generation: self.generation)
        }
    }
    func update(_ next: ConversationEntryView, appearance nextAppearance: ConversationEntryAppearance) {
        guard content != next || appearance != nextAppearance else { return }
        content = next
        appearance = nextAppearance
        generation += 1
        publishedHeight = nil
        sizes.removeAll(keepingCapacity: true)
        setRoot()
    }
    private func setRoot() {
        let version = generation
        host.rootView = HostedConversationEntry(content: content, appearance: appearance, disclosureChanged: { [weak self] animated in
            self?.sizes.removeAll(keepingCapacity: true)
            self?.disclosureChanged(animated)
        }) { [weak self] size in
            self?.contentSizeChanged(size, generation: version)
        }
    }
    func measure(width proposed: CGFloat?) -> CGSize {
        let width = max(1, proposed?.isFinite == true ? proposed! : ReplyStyle.readingWidth)
        let height: CGFloat
        if let cached = sizes.first(where: { $0.width == width }) {
            height = cached.height
        } else {
            #if TRANSCRIPT_CHECKS
            let start = CACurrentMediaTime()
            defer { NavigationRenderMetrics.record("host_measure", since: start) }
            #endif
            height = ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            if sizes.count == 8 { sizes.removeFirst() }
            sizes.append((width, height))
        }
        let size = CGSize(width: width, height: height)
        // Disclosure and attachment state can change without changing the entry.
        // Publish the newly measured height without synchronously writing state
        // during SwiftUI's layout pass.
        if publishedHeight != height && abs(width - view.bounds.width) < 0.5 {
            report(size, generation: generation)
        }
        return size
    }
    private func contentSizeChanged(_ size: CGSize, generation version: Int) {
        guard version == generation, size.width > 0, size.height.isFinite,
              abs(size.width - view.bounds.width) < 0.5 else { return }
        let height = ceil(size.height)
        // Local state (disclosures, loaded images) can resize a row without a
        // new message. Replace the cache before another scroll pass reads it.
        if sizes.first(where: { $0.width == size.width })?.height != height {
            sizes.removeAll(keepingCapacity: true)
            sizes.append((size.width, height))
        }
        report(size, generation: version)
    }
    private func report(_ size: CGSize, generation version: Int) {
        guard version == generation, size.width > 0, size.height.isFinite else { return }
        if pendingSize?.generation == version && pendingSize?.size == size { return }
        pendingSize = (size, version)
        guard !notificationScheduled else { return }
        notificationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notificationScheduled = false
            guard let report = self.pendingSize else { return }
            self.pendingSize = nil
            // Ignore obsolete content and speculative widths used by sizeThatFits.
            guard report.generation == self.generation,
                  abs(report.size.width - self.view.bounds.width) < 0.5 else { return }
            let height = ceil(report.size.height)
            guard self.publishedHeight != height else { return }
            self.publishedHeight = height
            self.heightChanged(height)
        }
    }
}

/// A concrete native viewport avoids relying on NSView.visibleRect: SwiftUI's
/// scroll clipping is not always represented by an enclosing NSClipView.
final class ConversationViewport {
    fileprivate weak var view: NSView?
    var pauseFollowing: (() -> Void)?
    let navigator = ConversationTurnNavigation()
    private let rows = NSHashTable<NSView>.weakObjects()
    private var scheduled = false
    fileprivate func add(_ row: NSView) { rows.add(row); refresh() }
    fileprivate func remove(_ row: NSView) { rows.remove(row); refresh() }
    func refresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            // Coalesce scroll and layout updates into one document pass.
            for row in self.rows.allObjects {
                if let document = row as? ConversationDocumentView {
                    document.refreshVisibleRows()
                    document.updateNavigator()
                }
            }
            if self.rows.allObjects.isEmpty {
                self.navigator.update(session: "", turns: [], current: 0)
                self.navigator.reveal = nil
            }
        }
    }
}

private struct ConversationViewportKey: EnvironmentKey {
    static let defaultValue: ConversationViewport? = nil
}
extension EnvironmentValues {
    var conversationViewport: ConversationViewport? {
        get { self[ConversationViewportKey.self] }
        set { self[ConversationViewportKey.self] = newValue }
    }
}

struct ConversationViewportView: NSViewRepresentable {
    let viewport: ConversationViewport
    var onPauseFollowing: () -> Void = {}
    func makeNSView(context: Context) -> MarkerView { viewport.pauseFollowing = onPauseFollowing; return MarkerView(viewport: viewport) }
    func updateNSView(_ view: MarkerView, context: Context) { viewport.pauseFollowing = onPauseFollowing; viewport.refresh() }
    final class MarkerView: NSView {
        private let viewport: ConversationViewport
        init(viewport: ConversationViewport) {
            self.viewport = viewport
            super.init(frame: .zero)
            viewport.view = self
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewport.refresh() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); viewport.refresh() }
        override func setFrameOrigin(_ origin: NSPoint) { super.setFrameOrigin(origin); viewport.refresh() }
    }
}

/// The document alone mounts visible rows. Keep a row's hosting subtree attached
/// while its frame changes so disclosure layout cannot blank it for one pass.
private final class ConversationEntryContainer: NSView {
    override var isFlipped: Bool { true }
    var widthChanged: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = bounds.width
        super.setFrameSize(newSize)
        if bounds.width != previousWidth { widthChanged?() }
    }
}

/// Live tokens update their own row, not the historical SwiftUI subtree.
private struct ConversationEntryView: View, Equatable {
    let entry: ConversationTimelineEntry
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    let memoryKey: String
    var activitySummary: String? = nil
    @RememberedExpansion("commentary") private var commentaryExpanded
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.tools == rhs.tools && lhs.api === rhs.api
            && lhs.sessionId == rhs.sessionId && lhs.memoryKey == rhs.memoryKey
            && lhs.activitySummary == rhs.activitySummary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                switch entry.presentation {
                case .activity:
                    KimiActivityView(entry: entry, tools: tools, api: api, sessionId: sessionId, summary: activitySummary)
                case .commentary:
                    DisclosureGroup("此前的进度说明 · \(entry.messages.count) 条", isExpanded: $commentaryExpanded) {
                        if commentaryExpanded { VStack(alignment: .leading, spacing: 12) {
                            ForEach(entry.messages) { message in
                                KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId)
                            }
                        }.padding(.top, 10) }
                    }.disclosureGroupStyle(WorkbenchDisclosureStyle()).font(.system(size: 12)).foregroundStyle(.secondary)
                case .thinkingDetails:
                    ThoughtDisclosure(text: entry.messages.flatMap(\.content).compactMap(\.thinking).joined(separator: "\n\n"))
                case .thinkingPreview, .thinkingRecord:
                    ThoughtOutput(messages: entry.messages, finished: entry.presentation == .thinkingRecord)
                        .id(entry.presentation == .thinkingRecord)
                case .emptyOutput:
                    Text("本轮未返回文字回复，可展开工具记录查看结果。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                default:
                    if entry.presentation == .record {
                        Text("过程记录 · 未返回最终回复").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(entry.messages) { message in
                        KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId)
                    }
                    if entry.messages.first?.role == "assistant" && entry.presentation != .progress {
                        let text = entry.messages.flatMap(\.content).compactMap(\.text).joined(separator: "\n\n")
                        if !text.isEmpty { ReplyCopyButton(text: text) }
                    }
                }
            }
    }
}

/// Keep live, historical and popover thoughts in the same TextKit style.
private enum ThoughtTextStyle {
    static let attributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13, weight: .light), toHaveTrait: .italicFontMask)
        return [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
    }()
}

private struct ThoughtText: View {
    let text: String
    var body: some View {
        SelectableReplyText(attributed: NSAttributedString(string: text, attributes: ThoughtTextStyle.attributes))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThoughtToggle: View {
    let title: String
    @Binding var expanded: Bool
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }.disclosureGroupStyle(WorkbenchDisclosureStyle(horizontalPadding: 0))
    }
}

private struct ThoughtDisclosure: View {
    let text: String
    @RememberedExpansion("thought") private var expanded
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ThoughtToggle(title: "Thoughts", expanded: $expanded)
            if expanded { ThoughtText(text: text) }
        }
    }
}

private struct ThoughtOutput: View {
    let messages: [KimiMessage]
    let finished: Bool
    private var fullText: String { messages.flatMap(\.content).compactMap(\.thinking).joined(separator: "\n\n") }
    @RememberedExpansion("live-thought", initial: true) private var expanded
    @State private var showFullText = false
    @State private var previewOverflows = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                ThoughtToggle(title: finished ? "Thoughts · No response" : "Thinking", expanded: $expanded)
                if expanded && !finished && previewOverflows {
                    Button { showFullText = true } label: {
                        Label("View full thoughts", systemImage: "arrow.up.right")
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }
            }
            if expanded && finished {
                ThoughtText(text: fullText)
            } else if expanded {
                ThinkingTextViewport(text: fullText, overflows: $previewOverflows)
            }
        }
        .popover(isPresented: $showFullText, arrowEdge: .top) {
            ScrollView { ThoughtText(text: fullText).padding(16) }
                .frame(width: 480, height: 300)
        }
    }
}

/// TextKit keeps wrapped layout for existing text while a reasoning stream appends.
/// Reuse TextKit layout to fit short thoughts and cap a growing preview at 76 pt.
private struct ThinkingTextViewport: NSViewRepresentable {
    let text: String
    @Binding var overflows: Bool
    final class Coordinator {
        var previous = ""
        let attributes = ThoughtTextStyle.attributes
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> FollowingThoughtScrollView {
        let scroll = FollowingThoughtScrollView()
        scroll.drawsBackground = false
        // The preview follows the stream; wheel gestures scroll the conversation.
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 76))
        view.isEditable = false
        view.enabledTextCheckingTypes = 0
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: FollowingThoughtScrollView, context: Context) {
        scroll.overflowChanged = { if overflows != $0 { overflows = $0 } }
        guard context.coordinator.previous != text,
              let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let prior = context.coordinator.previous
        if text.utf8.starts(with: prior.utf8) {
            let suffix = (text as NSString).substring(from: (prior as NSString).length)
            storage.append(NSAttributedString(string: suffix, attributes: context.coordinator.attributes))
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: context.coordinator.attributes))
        }
        context.coordinator.previous = text
        scroll.scheduleFollow()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FollowingThoughtScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 760
        return CGSize(width: width, height: min(76, nsView.textHeight(width: width)))
    }
}

/// A live preview, not a second reading surface. Full thoughts have their own popover.
private final class FollowingThoughtScrollView: NSScrollView {
    var overflowChanged: (Bool) -> Void = { _ in }

    func textHeight(width: CGFloat) -> CGFloat {
        guard let text = documentView as? NSTextView, let container = text.textContainer,
              let layout = text.layoutManager else { return 0 }
        text.setFrameSize(NSSize(width: width, height: text.frame.height))
        layout.ensureLayout(for: container)
        text.sizeToFit()
        return text.frame.height
    }
    private var followScheduled = false

    override func scrollWheel(with event: NSEvent) {
        // A nested NSScrollView otherwise consumes the wheel while only a few
        // thought lines move. Keep transcript navigation consistent under text.
        enclosingScrollView?.scrollWheel(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { scheduleFollow() }
    }
    func scheduleFollow() {
        guard !followScheduled else { return }
        followScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.followScheduled = false
            guard let text = self.documentView as? NSTextView else { return }
            self.layoutSubtreeIfNeeded()
            if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
            text.sizeToFit()
            self.overflowChanged(text.bounds.height > self.contentView.bounds.height + 0.5)
            let bottom = max(0, text.bounds.maxY - self.contentView.bounds.height)
            self.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            self.reflectScrolledClipView(self.contentView)
        }
    }
}
