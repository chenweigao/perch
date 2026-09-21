import AppKit
import SwiftUI
import WorkbenchCore

private let kimiPaper = Color.primary.opacity(0.035)

struct KimiMessageView: View {
    let message: KimiMessage
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    private var isUserMessage: Bool {
        message.role == "user" && !message.content.allSatisfy(\.isRuntimeContext)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            ForEach(Array(message.content.enumerated()), id: \.offset) { _, part in
                switch part.type {
                case "text":
                    if part.isRuntimeContext {
                        DisclosureGroup("运行上下文") { KimiMarkdown(text: part.text ?? "") }.font(.system(size: 11)).foregroundStyle(.secondary)
                    } else { KimiMarkdown(text: part.text ?? "") }
                case "thinking": DisclosureGroup("思考过程") { KimiMarkdown(text: part.thinking ?? "") }.font(.system(size: 12)).foregroundStyle(.secondary)
                case "tool_use":
                    if let tool = tools[part.toolCallId ?? ""] { KimiToolCard(tool: tool) }
                case "image", "file", "video":
                    KimiAttachmentView(part: part, api: api, sessionId: sessionId)
                default: EmptyView()
                }
            }
        }.padding(isUserMessage ? 15 : 0).frame(maxWidth: .infinity, alignment: .leading)
            .background(isUserMessage ? kimiPaper : .clear, in: RoundedRectangle(cornerRadius: 16))
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
    @State private var toolProjection = ToolVisibilityProjection()
    @State private var projection = ConversationProjection()
    @Environment(\.self) private var environment
    @State private var measured: (session: String, height: CGFloat)?
    @State private var contentOriginY: CGFloat = 0
    var body: some View {
        let visible = toolProjection.update(messages, sessionID: sessionId, live: liveTools, running: running, online: online)
        let snapshot = projection.update(visible.messages, isRunning: isRunning)
        let contents = snapshot.entries.map { entry in
            let ids = Set(entry.messages.flatMap(\.content).compactMap(\.toolCallId))
            let tools = ids.reduce(into: [String: VisibleTool]()) { result, id in
                if let value = visible.tools[id] { result[id] = value }
            }
            return ConversationEntryView(entry: entry, tools: tools, api: api, sessionId: sessionId)
        }
        ConversationDocumentHost(contents: contents, sessionId: sessionId,
                                 appearance: ConversationEntryAppearance(environment),
                                 viewport: environment.conversationViewport,
                                 contentOriginY: contentOriginY) { height in
            measured = (sessionId, height)
        }.frame(height: measured?.session == sessionId ? measured?.height : nil)
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named("conversation-content")).minY
            } action: { contentOriginY = $0 }
    }
}

private struct ConversationDocumentHost: NSViewRepresentable {
    let contents: [ConversationEntryView]
    let sessionId: String
    let appearance: ConversationEntryAppearance
    let viewport: ConversationViewport?
    let contentOriginY: CGFloat
    let heightChanged: (CGFloat) -> Void
    func makeNSView(context: Context) -> ConversationDocumentView { ConversationDocumentView() }
    func updateNSView(_ view: ConversationDocumentView, context: Context) {
        view.heightChanged = heightChanged
        view.configure(contents, sessionId: sessionId, appearance: appearance,
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
/// Actual measurements replace estimates as rows are read. Controllers retain
/// disclosure state when detached; no SwiftUI lazy-layout phases are involved.
private final class ConversationDocumentView: NSView {
    private var contents: [ConversationEntryView] = []
    private var indices: [String: Int] = [:]
    private var heights: [CGFloat] = []
    private var offsets: [CGFloat] = []
    private var controllers: [String: ConversationEntryController] = [:]
    private var mounted: Set<String> = []
    private static let retiredControllers = NSMutableArray()
    private static var drainingRetiredControllers = false
    private var sessionId = ""
    private var rowAppearance: ConversationEntryAppearance?
    private weak var viewport: ConversationViewport?
    private var columnWidth: CGFloat = ReplyStyle.readingWidth
    private var refreshing = false
    private var contentOriginY: CGFloat = 0
    private var publishedHeight: CGFloat?
    private var publicationScheduled = false
    private weak var observedClip: NSClipView?
    private var boundsObserver: NSObjectProtocol?
    private(set) var totalHeight: CGFloat = 0
    var heightChanged: (CGFloat) -> Void = { _ in }
    override var isFlipped: Bool { true }

    func configure(_ next: [ConversationEntryView], sessionId: String,
                   appearance: ConversationEntryAppearance, viewport: ConversationViewport?,
                   contentOriginY: CGFloat) {
        self.contentOriginY = contentOriginY
        if self.viewport !== viewport {
            self.viewport?.remove(self)
            self.viewport = viewport
            viewport?.add(self)
        }
        if self.sessionId != sessionId {
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
        let previous = Dictionary(uniqueKeysWithValues: zip(contents.map { $0.entry.id }, heights))
        contents = next
        indices = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.entry.id, $0.offset) })
        heights = next.map { previous[$0.entry.id] ?? 160 }
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
        refreshVisibleRows()
        publishHeight()
    }
    /// Releasing hundreds of hosting graphs in the selection transaction stalls
    /// the main thread. Drain a small batch between frames, on AppKit's thread.
    func prepareForRemoval() {
        for id in mounted { controllers[id]?.view.removeFromSuperview() }
        Self.retire(Array(controllers.values))
        controllers.removeAll()
        mounted.removeAll()
        viewport?.remove(self)
    }
    private static func retire(_ old: [ConversationEntryController]) {
        guard !old.isEmpty else { return }
        // A single drain bounds total release work even during rapid switches.
        // Mutable reference storage releases each graph when it is removed.
        retiredControllers.addObjects(from: old)
        guard !drainingRetiredControllers else { return }
        drainingRetiredControllers = true
        Task { @MainActor in
            while retiredControllers.count > 0 {
                try? await Task.sleep(for: .milliseconds(10))
                autoreleasepool {
                    for _ in 0..<min(4, retiredControllers.count) {
                        retiredControllers.removeLastObject()
                    }
                }
            }
            drainingRetiredControllers = false
        }
    }

    func measure(width: CGFloat?) -> CGSize {
        columnWidth = max(1, width?.isFinite == true ? width! : ReplyStyle.readingWidth)
        refreshVisibleRows()
        return CGSize(width: columnWidth, height: totalHeight)
    }
    private func rebuildOffsets() {
        var y: CGFloat = 0
        offsets = heights.map { height in
            defer { y += height + 18 }
            return y
        }
        totalHeight = max(0, y - (heights.isEmpty ? 0 : 18))
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
        var index = offsets.indices.first { offsets[$0] + heights[$0] > max(0, visible.minY) }
            ?? max(0, contents.count - 1)
        var nextMounted: Set<String> = []
        while index < contents.count && offsets[index] < visible.maxY {
            let content = contents[index]
            let id = content.entry.id
            let controller: ConversationEntryController
            if let existing = controllers[id] {
                controller = existing
            } else {
                controller = ConversationEntryController(content: content, appearance: appearance) { [weak self] height in
                    self?.rowHeightChanged(id, height: height)
                }
                controllers[id] = controller
            }
            let height = controller.measure(width: columnWidth).height
            if heights[index] != height {
                heights[index] = height
                rebuildOffsets()
            }
            controller.view.frame = CGRect(x: 0, y: offsets[index], width: columnWidth, height: height)
            if controller.view.superview !== self { addSubview(controller.view) }
            nextMounted.insert(id)
            index += 1
        }
        for id in mounted.subtracting(nextMounted) { controllers[id]?.view.removeFromSuperview() }
        mounted = nextMounted
        publishHeight()
    }
    private func rowHeightChanged(_ id: String, height: CGFloat) {
        guard let index = indices[id], heights[index] != height else { return }
        heights[index] = height
        rebuildOffsets()
        publishHeight()
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
        super.setFrameSize(size)
        if size.width > 0 { columnWidth = size.width }
        refreshVisibleRows()
    }
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        refreshVisibleRows()
    }
    override func layout() {
        super.layout()
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
        ) { [weak self] _ in self?.refreshVisibleRows() }
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
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
}

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
        reduceMotion = environment.accessibilityReduceMotion
        isEnabled = environment.isEnabled
    }
}

private struct HostedConversationEntry: View {
    let content: ConversationEntryView
    let appearance: ConversationEntryAppearance
    var sizeChanged: (CGSize) -> Void = { _ in }
    var body: some View {
        content.equatable().fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.layoutDirection, appearance.layoutDirection)
            .environment(\.displayScale, appearance.displayScale)
            .environment(\.dynamicTypeSize, appearance.dynamicTypeSize)
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
    private var mounted = false
    private var widthMeasurementScheduled = false
    var heightChanged: (CGFloat) -> Void

    init(content: ConversationEntryView, appearance: ConversationEntryAppearance,
         heightChanged: @escaping (CGFloat) -> Void) {
        self.content = content
        self.appearance = appearance
        self.heightChanged = heightChanged
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
        host.view.autoresizingMask = [.width, .height]
        container.visibilityChanged = { [weak self] visible in self?.setVisible(visible) }
        container.widthChanged = { [weak self] in self?.committedWidthChanged() }
        // The row already owns its measured frame; its sole child fills it.
        // Avoid rebuilding an Auto Layout constraint graph on viewport changes.
        view = container
    }
    func setViewport(_ viewport: ConversationViewport?) {
        (view as? ConversationEntryContainer)?.setViewport(viewport)
    }
    private func setVisible(_ visible: Bool) {
        guard visible != mounted else { return }
        mounted = visible
        if visible {
            host.view.frame = view.bounds
            view.addSubview(host.view)
        } else {
            host.view.removeFromSuperview()
        }
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
        host.rootView = HostedConversationEntry(content: content, appearance: appearance) { [weak self] size in
            self?.report(size, generation: version)
        }
    }
    func measure(width proposed: CGFloat?) -> CGSize {
        let width = max(1, proposed?.isFinite == true ? proposed! : ReplyStyle.readingWidth)
        let height: CGFloat
        if content.hasStableHeight, let cached = sizes.first(where: { $0.width == width }) {
            height = cached.height
        } else {
            height = ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            if content.hasStableHeight {
                if sizes.count == 8 { sizes.removeFirst() }
                sizes.append((width, height))
            }
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
    private let rows = NSHashTable<NSView>.weakObjects()
    private var scheduled = false
    fileprivate func add(_ row: NSView) { rows.add(row); refresh() }
    fileprivate func remove(_ row: NSView) { rows.remove(row) }
    func refresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            // Convert the viewport once per pass. Every visible scroll tick walks
            // this for each registered row otherwise.
            let window = self.view?.window
            let viewportRect = self.view.map { $0.convert($0.bounds, to: nil) }
            for row in self.rows.allObjects {
                if let document = row as? ConversationDocumentView { document.refreshVisibleRows() }
                else { (row as? ConversationEntryContainer)?.updateVisibility(viewport: viewportRect, viewportWindow: window) }
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
    func makeNSView(context: Context) -> MarkerView { MarkerView(viewport: viewport) }
    func updateNSView(_ view: MarkerView, context: Context) { viewport.refresh() }
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

/// Preserve every row's frame and state, but keep offscreen NSTextView subtrees
/// out of AppKit's scroll geometry, tracking-area and accessibility traversal.
private final class ConversationEntryContainer: NSView {
    var visibilityChanged: ((Bool) -> Void)?
    var widthChanged: (() -> Void)?
    private weak var viewport: ConversationViewport?
    private var lastVisibility: Bool?
    func setViewport(_ next: ConversationViewport?) {
        guard viewport !== next else { return }
        viewport?.remove(self)
        viewport = next
        next?.add(self)
        updateVisibility()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateVisibility()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateVisibility()
    }
    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = bounds.width
        super.setFrameSize(newSize)
        if bounds.width != previousWidth { widthChanged?() }
        updateVisibility()
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        updateVisibility()
    }
    override func layout() {
        super.layout()
        updateVisibility()
    }
    /// `viewport` is the marker rect already converted to window coordinates by a
    /// batched refresh; nil means this row has to convert it itself.
    func updateVisibility(viewport viewportRect: CGRect? = nil, viewportWindow: NSWindow? = nil) {
        let visible: Bool
        if let window, let viewportRect, viewportWindow === window {
            visible = convert(bounds, to: nil).intersects(viewportRect)
        } else if let window, let marker = viewport?.view, marker.window === window {
            visible = convert(bounds, to: nil).intersects(marker.convert(marker.bounds, to: nil))
        } else if let window, let content = window.contentView {
            // Standalone reading previews do not install a scroll viewport.
            visible = convert(bounds, to: nil).intersects(content.convert(content.bounds, to: nil))
        } else {
            visible = false
        }
        guard lastVisibility != visible else { return }
        lastVisibility = visible
        visibilityChanged?(visible)
    }
}

/// Live tokens update their own row, not the historical SwiftUI subtree.
private struct ConversationEntryView: View, Equatable {
    let entry: ConversationTimelineEntry
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    // Only rows whose height is wholly determined by message values may cache
    // across measurements. Disclosure state and loaded attachments are local.
    var hasStableHeight: Bool {
        switch entry.presentation {
        case .message, .progress, .record:
            return entry.messages.allSatisfy { message in
                message.content.allSatisfy { $0.type == "text" && !$0.isRuntimeContext }
            }
        case .emptyOutput: return true
        default: return false
        }
    }
    @State private var commentaryExpanded = false
    @State private var thinkingExpanded = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.tools == rhs.tools && lhs.api === rhs.api
            && lhs.sessionId == rhs.sessionId
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                switch entry.presentation {
                case .activity:
                    KimiActivityView(entry: entry, tools: tools, api: api, sessionId: sessionId)
                case .commentary:
                    DisclosureGroup("此前的进度说明 · \(entry.messages.count) 条", isExpanded: $commentaryExpanded) {
                        if commentaryExpanded { VStack(alignment: .leading, spacing: 12) {
                            ForEach(entry.messages) { message in
                                KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId)
                            }
                        }.padding(.top, 10) }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                case .thinkingDetails:
                    DisclosureGroup("思考记录", isExpanded: $thinkingExpanded) {
                        if thinkingExpanded { KimiMarkdown(text: entry.messages.flatMap(\.content).compactMap(\.thinking).joined(separator: "\n\n"))
                            .padding(.top, 10) }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                case .thinkingPreview, .thinkingRecord:
                    ThoughtOutput(messages: entry.messages, finished: entry.presentation == .thinkingRecord)
                        .id(entry.presentation == .thinkingRecord)
                case .emptyOutput:
                    Text("本轮未返回文字回复，可展开执行过程查看工具结果。")
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

private struct ThoughtOutput: View {
    let messages: [KimiMessage]
    let finished: Bool
    private var fullText: String { messages.flatMap(\.content).compactMap(\.thinking).joined(separator: "\n\n") }
    private var current: String { messages.last?.content.compactMap(\.thinking).joined(separator: "\n\n") ?? "" }
    @State private var expanded = true
    @State private var showFullText = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text(finished ? "思考记录 · 未返回正文" : "思考中")
                    Spacer(minLength: 0)
                    Text(expanded ? "收起" : "展开").font(.system(size: 10))
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            if expanded && finished {
                KimiMarkdown(text: fullText)
            } else if expanded {
                ThinkingTextViewport(text: current).frame(height: 76)
                Button("查看全部思考") { showFullText = true }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .popover(isPresented: $showFullText, arrowEdge: .top) {
            if showFullText { ScrollView { SelectableReplyText(fullText, font: NSFontManager.shared.convert(.systemFont(ofSize: 13, weight: .light), toHaveTrait: .italicFontMask), lineSpacing: 5).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                .frame(width: 480, height: 300) }
        }
    }
}

/// TextKit keeps wrapped layout for existing text while a reasoning stream appends.
/// The fixed viewport never asks SwiftUI to measure the full, growing document.
private struct ThinkingTextViewport: NSViewRepresentable {
    let text: String
    final class Coordinator {
        var previous = ""
        let attributes: [NSAttributedString.Key: Any] = {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13, weight: .light), toHaveTrait: .italicFontMask)
            return [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        }()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> FollowingThoughtScrollView {
        let scroll = FollowingThoughtScrollView()
        scroll.drawsBackground = false
        // Keep wheel/trackpad scrolling without flashing a scroller on every token.
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
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: FollowingThoughtScrollView, context: Context) {
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
        CGSize(width: proposal.width ?? 760, height: 76)
    }
}

/// Follow only within the thought viewport. Reading older thoughts pauses following.
private final class FollowingThoughtScrollView: NSScrollView {
    private var followsLatest = true
    private var followScheduled = false
    private var scrollObservation: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollObservation = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification, object: self, queue: .main
        ) { [weak self] _ in
            guard let self, let document = self.documentView else { return }
            self.followsLatest = document.bounds.maxY - self.documentVisibleRect.maxY < 12
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) } }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { scheduleFollow() }
    }
    func scheduleFollow() {
        guard followsLatest, !followScheduled else { return }
        followScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.followScheduled = false
            guard self.followsLatest, let text = self.documentView as? NSTextView else { return }
            self.layoutSubtreeIfNeeded()
            if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
            text.sizeToFit()
            let bottom = max(0, text.bounds.maxY - self.contentView.bounds.height)
            self.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            self.reflectScrolledClipView(self.contentView)
        }
    }
}
