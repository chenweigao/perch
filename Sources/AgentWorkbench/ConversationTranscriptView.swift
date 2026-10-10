import AppKit
import SwiftUI
import WorkbenchCore

#if TRANSCRIPT_CHECKS
/// Nested stages are reported separately; their durations must not be summed.
enum NavigationRenderMetrics {
    static var stages: [String: (count: Int, ms: Double)] = [:]
    /// Occurrences only. A lifecycle event must not be reported as a duration:
    /// taking the start timestamp at the record call always reads ~0.0ms, which is
    /// how native-row parsing became invisible under `markdown_parse`.
    static var counters: [String: Int] = [:]
    static func record(_ stage: String, since start: TimeInterval) {
        let old = stages[stage] ?? (0, 0)
        stages[stage] = (old.count + 1, old.ms + (CACurrentMediaTime() - start) * 1_000)
    }
    static func count(_ key: String, by amount: Int = 1) { counters[key, default: 0] += amount }
    static var report: [String: Any] {
        stages.mapValues { ["count": $0.count, "ms": $0.ms] as [String: Any] }
    }
    /// Reported separately from `report` so an occurrence can never be read as a
    /// 0.0ms duration.
    static var counterReport: [String: Any] { counters }
}
#endif

private let kimiPaper = Color.primary.opacity(0.035)

/// Compaction marks a context boundary, not a message: a slim divider row with
/// the agent's handoff notes folded behind it.
private struct CompactionSummaryRow: View {
    let text: String
    @RememberedExpansion("compaction") private var expanded
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    divider
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 10, weight: .medium))
                        Text("上下文已压缩").font(.system(size: 11))
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                    }.foregroundStyle(.secondary).fixedSize()
                    divider
                }.contentShape(Rectangle())
            }.buttonStyle(WorkbenchDisclosureButtonStyle())
                .accessibilityValue(Text(expanded ? "已展开" : "已收起"))
            if expanded {
                KimiMarkdown(text: CompactionSummaryDisplay.humanText(text))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }
        }
    }
    private var divider: some View {
        Color.primary.opacity(0.12).frame(height: 1)
    }
}

struct KimiMessageView: View {
    let message: KimiMessage
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    var markdownPreparation: ReplyMarkdownPreparation? = nil
    /// The hosting entry's id doubles as the turn's bookmark id for user rows.
    var entryID: String? = nil
    @Environment(\.conversationActionContext) private var actionContext
    @Environment(\.conversationMemoryKey) private var memoryKey
    private var isUserMessage: Bool { message.isUserPrompt }
    /// The message's visible text, the same source search excerpts read.
    private var visibleText: String {
        message.content.filter { $0.type == "text" && !$0.isRuntimeContext }
            .map { $0.skillContextSplit?.prefix ?? $0.text ?? "" }.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func runtimeContext(_ text: String) -> some View {
        DisclosureGroup("运行上下文") { KimiMarkdown(text: text) }.disclosureGroupStyle(WorkbenchDisclosureStyle(horizontalPadding: 0)).font(.system(size: 12)).foregroundStyle(.secondary)
    }
    private func compactionSummary(_ text: String) -> some View {
        CompactionSummaryRow(text: text)
    }
    var body: some View {
        if isUserMessage {
            UserMessageLayout {
                content.environment(\.replyLineHeight, UserMessageStyle.lineHeight)
                    .padding(.horizontal, UserMessageStyle.horizontalPadding)
                    .padding(.vertical, UserMessageStyle.verticalPadding)
                    .background(kimiPaper, in: RoundedRectangle(cornerRadius: UserMessageStyle.cornerRadius))
            }.padding(.top, UserMessageStyle.topSpacing)
                .contextMenu {
                    if let actionContext, !visibleText.isEmpty {
                        UserMessageContextMenu(context: actionContext, text: visibleText,
                                               bookmark: entryID.map { (turn: $0, session: memoryKey) })
                    }
                }
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(message.content.enumerated()), id: \.offset) { _, part in
                switch part.type {
                case "text":
                    if message.isCompactionSummary {
                        compactionSummary(part.text ?? "")
                    } else if let split = part.skillContextSplit {
                        KimiMarkdown(text: split.prefix).environment(\.isConversationBodyText, true)
                        runtimeContext(split.context)
                    } else if part.isRuntimeContext {
                        runtimeContext(part.text ?? "")
                    } else {
                        KimiMarkdown(text: part.text ?? "", sessionID: sessionId, messageID: message.id,
                                     preparation: markdownPreparation)
                            .environment(\.isConversationBodyText, true)
                    }
                case "thinking": ThoughtDisclosure(text: part.thinking ?? "")
                case "tool_use":
                    if let tool = tools[part.toolCallId ?? ""] { KimiToolCard(tool: tool) }
                case "image", "file", "video":
                    KimiAttachmentView(part: part, api: api, sessionId: sessionId)
                default: EmptyView()
                }
            }
        }
    }
}

private struct UserMessageLayout: Layout {
    private func measure(width: CGFloat, subview: LayoutSubview) -> CGSize {
        let idealWidth = subview.sizeThatFits(.unspecified).width
        return subview.sizeThatFits(ProposedViewSize(width: min(idealWidth, width * UserMessageStyle.maxWidthRatio), height: nil))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ReplyStyle.readingWidth)
        return CGSize(width: width, height: measure(width: width, subview: subviews[0]).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = measure(width: bounds.width, subview: subviews[0])
        subviews[0].place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                          proposal: ProposedViewSize(size))
    }
}

/// Supplies individually identified rows to the conversation viewport.
/// Keep historical rows equatable so live tokens only invalidate their own content.
/// Complete inputs of the hosted rows. Snapshot identity is safe because its
/// values are immutable; external summaries and action context remain explicit.
private struct ConversationContentIdentity: Equatable {
    let snapshot: ConversationPresentationModel.Snapshot
    let narratives: [String: ActivityNarrativeRow]
    let api: KimiAPI?
    let session: String
    let memoryKey: String
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot === rhs.snapshot && lhs.narratives == rhs.narratives
            && lhs.api === rhs.api && lhs.session == rhs.session && lhs.memoryKey == rhs.memoryKey
    }
}

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
    var historyEpoch: String?
    var isSuspended = false
    /// The owner restores its initial scroll position before this document is exposed.
    var waitsForInitialPosition = false
    @Environment(\.conversationPresentations) private var presentations
    @State private var presentation = ConversationPresentationHandle()
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @ObservedObject var narrativeStore = ActivityNarrativeStore.shared
    @Environment(\.self) private var environment
    @State private var measured: (session: String, height: CGFloat)?
    @State private var documentLayout = ConversationDocumentLayout()
    var body: some View {
        let key = memoryKey ?? sessionId
        let snapshot = presentation.update(key: key, input: ConversationPresentationModel.Input(
            messages: messages, live: liveTools, running: running, isRunning: isRunning, online: online,
            epoch: historyEpoch, language: environment.locale.identifier + ":" + AppLanguage.current.localization,
            summariesEnabled: summarySettings.configuration.enabled && allowsActivitySummaries && online,
            includeToolOutput: summarySettings.configuration.includeToolOutput), cache: presentations)
        let observation = SummaryObservation(session: key, batch: snapshot.batch, narrativeKey: snapshot.narrativeKey,
            running: isRunning, online: online && allowsActivitySummaries, following: followsLatest,
            settingsRevision: summarySettings.revision)
        let narratives = narrativeStore.rows(session: key)
        let identity = ConversationContentIdentity(snapshot: snapshot, narratives: narratives,
            api: api, session: sessionId, memoryKey: key)
        let contents = snapshot.displayedRows { narratives[$0] }.map { row in
            ConversationEntryView(entry: row.entry, tools: row.tools, api: api, sessionId: sessionId,
                memoryKey: key + ":" + row.entry.id, activityNarrative: row.activity)
        }
        ConversationDocumentHost(contents: contents, contentIdentity: identity, navigation: snapshot.navigation, sessionId: key,
                                 appearance: ConversationEntryAppearance(environment),
                                 viewport: environment.conversationViewport,
                                 layout: documentLayout, measuredHeight: measured?.session == sessionId ? measured?.height : nil,
                                 suspended: isSuspended, waitsForInitialPosition: waitsForInitialPosition) { height in
            measured = (sessionId, height)
        }
        // The native measurement is the single source of document height.
        // An asynchronously updated outer fixed frame can keep the scroll view
        // taller than its already-shrunken transcript for one display pass.
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named("conversation-content")).minY
            } action: { documentLayout.updateOrigin($0) }
            .task(id: observation) {
                narrativeStore.observe(session: observation.session, snapshot: snapshot.narrative, batch: snapshot.batch,
                    running: isRunning, online: observation.online, following: followsLatest,
                    settings: summarySettings)
            }
    }
    private struct SummaryObservation: Hashable {
        let session: String
        let batch: ActivitySummaryBatch?
        let narrativeKey: String
        let running: Bool
        let online: Bool
        let following: Bool
        let settingsRevision: Int
    }
}

/// Geometry belongs to the mounted document, not observable transcript data.
/// An origin change must not rebuild the SwiftUI row values or presentation input.
@MainActor private final class ConversationDocumentLayout {
    private(set) var originY: CGFloat = 0
    weak var document: ConversationDocumentView?
    func updateOrigin(_ value: CGFloat) {
        guard originY != value else { return }
        originY = value
        document?.updateContentOrigin(value)
    }
}

private struct ConversationDocumentHost: NSViewRepresentable {
    let contents: [ConversationEntryView]
    let contentIdentity: ConversationContentIdentity
    let navigation: [ConversationTurnSummary]
    let sessionId: String
    let appearance: ConversationEntryAppearance
    let viewport: ConversationViewport?
    let layout: ConversationDocumentLayout
    // Changes invalidate SwiftUI's measurement without imposing a stale frame.
    let measuredHeight: CGFloat?
    var suspended = false
    var waitsForInitialPosition = false
    let heightChanged: (CGFloat) -> Void
    func makeCoordinator() -> ConversationDocumentLayout { layout }
    func makeNSView(context: Context) -> ConversationDocumentView {
        let document = ConversationDocumentView()
        context.coordinator.document = document
        return document
    }
    func updateNSView(_ view: ConversationDocumentView, context: Context) {
        guard !suspended else { view.suspend(); return }
        view.heightChanged = heightChanged
        view.configure(contents, contentIdentity: contentIdentity, navigation: navigation, sessionId: sessionId, appearance: appearance,
                       viewport: viewport, contentOriginY: layout.originY, waitsForInitialPosition: waitsForInitialPosition)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ConversationDocumentView, context: Context) -> CGSize? {
        if suspended { nsView.suspend() }
        return nsView.measure(width: proposal.width)
    }
    static func dismantleNSView(_ view: ConversationDocumentView, coordinator: ConversationDocumentLayout) {
        if coordinator.document === view { coordinator.document = nil }
        view.prepareForRemoval()
    }
}

private enum ConversationRefreshSource: String {
    case reveal
    case configure
    case contentOrigin = "content_origin"
    case measurement
    case rowHeight = "row_height"
    case willDraw = "will_draw"
    case restore
    case clipBounds = "clip_bounds"
    case viewport
}

/// Reserve history geometry, but only instantiate hosts intersecting the viewport.
/// Actual measurements replace estimates as rows are read. Only nearby controllers
/// survive detachment; disclosure state lives in ConversationReadingMemory.
private final class ConversationDocumentView: NSView {
    private var suspended = false
    private var preparingInitialViewport = false
    private var waitsForInitialPosition = false
    private var contents: [ConversationEntryView] = []
    private var contentIdentity: ConversationContentIdentity?
    private var indices: [String: Int] = [:]
    private var navigation: [ConversationTurnSummary] = []
    private var turnRows: [Int] = []
    private var heights: [CGFloat] = []
    // Keep measured sizes after their hosting graphs leave the retained window.
    // A row may reuse one only while its content, appearance and width match.
    private var measuredSizes: [String: (content: ConversationEntryView, width: CGFloat, height: CGFloat)] = [:]
    private var geometry = ConversationRowGeometry(heights: [])
    private var offsets: [CGFloat] { geometry.offsets }
    private var controllers: [String: ConversationEntryController] = [:]
    private var mounted: Set<String> = []
    private var laidOutRange: Range<Int>?
    private static let retiredControllers = NSMutableArray()
    private static var drainingRetiredControllers = false
    private var sessionId = ""
    private var readingIntent = 0
    private var restoreTarget: ConversationReadingMemory.Position?
    private var rowAppearance: ConversationEntryAppearance?
    private weak var viewport: ConversationViewport?
    private var columnWidth: CGFloat = ReplyStyle.readingWidth
    private var refreshing = false
    private var contentOriginY: CGFloat = 0
    private var publishedHeight: CGFloat?
    private var publicationScheduled = false
    private weak var observedClip: NSClipView?
    private var boundsObserver: NSObjectProtocol?
    var totalHeight: CGFloat { geometry.totalHeight }
    private var findObserver: NSObjectProtocol?
    private var highlightObserver: NSObjectProtocol?
    /// The find bar's current highlight-all request, if it targets this session.
    private var highlight: ConversationHighlightUpdate?
    #if TRANSCRIPT_CHECKS
    fileprivate var missingVisibleRows: [String] {
        let visible = viewportRect
        return contents.indices.compactMap { index in
            guard offsets[index] < visible.maxY, offsets[index] + heights[index] > visible.minY else { return nil }
            let id = contents[index].entry.id
            return controllers[id]?.view.superview === self ? nil : id
        }
    }
    fileprivate func checkReconciliation() throws -> [String: Any] {
        guard let appearance = rowAppearance, let identity = contentIdentity, !mounted.isEmpty,
              let offscreen = contents.indices.first(where: { !mounted.contains(contents[$0].entry.id) && contents[$0].entry.messages.first?.isUserPrompt == true }),
              let visible = contents.indices.first(where: { mounted.contains(contents[$0].entry.id) && contents[$0].entry.messages.first?.isUserPrompt == true }) else {
            throw WorkbenchError("Reconciliation fixture requires visible and offscreen user rows")
        }
        let original = contents, originalNavigation = navigation
        func count(_ key: String) -> Int { NavigationRenderMetrics.stages[key]?.count ?? 0 }
        func apply(_ rows: [ConversationEntryView], _ style: ConversationEntryAppearance, force: Bool = true) {
            if force { contentIdentity = nil }
            configure(rows, contentIdentity: identity, navigation: originalNavigation, sessionId: sessionId, appearance: style,
                      viewport: viewport, contentOriginY: contentOriginY)
        }
        let before = [count("document_reconcile"), count("row_geometry"), count("host_measure")]
        for _ in 0..<40 { apply(original, appearance, force: false); _ = measure(width: columnWidth) }
        guard before == [count("document_reconcile"), count("row_geometry"), count("host_measure")] else {
            throw WorkbenchError("Unchanged viewport replay rebuilt or remeasured rows")
        }
        func replacement(_ index: Int, id: String? = nil) throws -> ConversationEntryView {
            let row = original[index], message = row.entry.messages[0]
            let raw: [String: Any] = ["id": id ?? message.id, "role": message.role, "created_at": message.createdAt,
                "content": [["type": "text", "text": String(repeating: "same-ID changed content 中文 ", count: 30)]]]
            let changed = try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: raw))
            return ConversationEntryView(entry: ConversationTimelineEntry.make([changed])[0], tools: row.tools,
                api: row.api, sessionId: row.sessionId, memoryKey: row.memoryKey, activityNarrative: row.activityNarrative)
        }
        // Restore source rows even if an assertion throws; this is a mounted fixture.
        defer { apply(original, appearance) }
        var edited = original
        edited[offscreen] = try replacement(offscreen)
        let range = laidOutRange, geometryCount = count("row_geometry")
        reconcileRows(edited, sessionId: sessionId, appearance: appearance)
        guard contents[offscreen] == edited[offscreen], laidOutRange == range, count("row_geometry") == geometryCount else {
            throw WorkbenchError("Offscreen same-ID edit invalidated visible geometry or lost content")
        }
        reconcileRows(original, sessionId: sessionId, appearance: appearance)
        edited = original; edited[visible] = try replacement(visible)
        reconcileRows(edited, sessionId: sessionId, appearance: appearance)
        guard laidOutRange == nil, measuredSizes[edited[visible].entry.id] == nil else {
            throw WorkbenchError("Visible same-ID edit reused stale row measurement")
        }
        apply(original, appearance)
        // A summary can arrive without replacing the immutable source snapshot.
        let summary = ActivityNarrativeRow(narrative: .init(turnID: "fixture", stageID: "external", phase: .exploring,
            headline: "New external summary", source: .external, lifecycle: .final), isAnchor: true, stageClosed: true)
        var overlays = identity.narratives
        overlays[original[visible].entry.id] = summary
        var summarized = original; summarized[visible].activityNarrative = summary
        let summaryIdentity = ConversationContentIdentity(snapshot: identity.snapshot, narratives: overlays,
            api: identity.api, session: identity.session, memoryKey: identity.memoryKey)
        configure(summarized, contentIdentity: summaryIdentity, navigation: originalNavigation, sessionId: sessionId,
                  appearance: appearance, viewport: viewport, contentOriginY: contentOriginY)
        guard contents[visible].activityNarrative == summary else { throw WorkbenchError("Summary update was hidden by source identity") }
        apply(original, appearance)
        var environment = EnvironmentValues()
        environment.colorScheme = appearance.colorScheme == .light ? .dark : .light
        let changedAppearance = ConversationEntryAppearance(environment)
        reconcileRows(original, sessionId: sessionId, appearance: changedAppearance)
        guard laidOutRange == nil, measuredSizes.isEmpty else { throw WorkbenchError("Appearance kept stale measurements") }
        apply(original, appearance)
        let added = try replacement(offscreen, id: "layout-fixture-prepend")
        reconcileRows([added] + original, sessionId: sessionId, appearance: appearance)
        guard contents.count == original.count + 1, indices[original[visible].entry.id] == visible + 1 else {
            throw WorkbenchError("Prepend failed to rebuild row indices")
        }
        reconcileRows(Array(original.dropFirst()), sessionId: sessionId, appearance: appearance)
        guard indices[original[0].entry.id] == nil, heights.count == original.count - 1 else {
            throw WorkbenchError("Removal kept obsolete row geometry")
        }
        return ["unchanged_replays": 40, "unchanged_reconciliations": 0, "unchanged_geometry_rebuilds": 0,
                "unchanged_host_measurements": 0, "same_id_offscreen_and_visible_edits": true,
                "appearance_invalidation": true, "external_summary_same_snapshot": true, "prepend_and_removal": true]
    }
    fileprivate var navigator: ConversationTurnNavigation? { viewport?.navigator }
    fileprivate var retainedHostCount: Int { controllers.count }
    fileprivate var mountedHostCount: Int { mounted.count }
    fileprivate static var retiredHostCount: Int { retiredControllers.count }
    fileprivate var readingAnchor: (entry: String, offset: CGFloat)? {
        guard let row = geometry.readingRow(at: max(0, viewportRect.minY)), contents.indices.contains(row) else { return nil }
        return (contents[row].entry.id, viewportRect.minY - offsets[row])
    }
    #endif
    override init(frame: NSRect) {
        super.init(frame: frame)
        findObserver = NotificationCenter.default.addObserver(forName: .init("PerchRevealConversationHit"), object: nil, queue: .main) { [weak self] notice in
            guard let self, let target = notice.object as? ConversationFindTarget, target.session == self.sessionId else { return }
            self.reveal(target)
        }
        highlightObserver = NotificationCenter.default.addObserver(forName: .init("PerchConversationHighlight"), object: nil, queue: .main) { [weak self] notice in
            guard let self, let update = notice.object as? ConversationHighlightUpdate else { return }
            // Other sessions' searches clear nothing here.
            guard update.session == self.sessionId else { return }
            self.highlight = update.query.isEmpty ? nil : update
            self.applyFindHighlights()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func reveal(_ target: ConversationFindTarget) {
        guard !suspended else { return }
        revealEntry(target.hit.entryID)
        // Regular-expression hits reveal their row; only literal queries can
        // place the caret on the exact occurrence.
        guard target.options.canLocateOccurrence else { return }
        let intent = readingIntent
        DispatchQueue.main.async { [weak self] in
            guard let self, self.readingIntent == intent, self.sessionId == target.session,
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
                        let found = source.range(of: target.query, options: target.options.compareOptions(), range: search)
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
        guard !suspended, let index = indices[id], let clip = observedClip else { return }
        cancelPendingRestoration()
        ConversationReadingMemory.shared.following[sessionId] = false
        viewport?.pauseFollowing?()
        // A reveal is an explicit destination, not a request to preserve the
        // outgoing visible rows while cold rows above it are being measured.
        restoreTarget = .init(entry: id, index: index, offset: 0)
        clip.scroll(to: NSPoint(x: 0, y: max(0, offsets[index] + contentOriginY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
        refreshVisibleRows(source: .reveal)
        restoreReadingPosition()
        if highlight, let view = controllers[id]?.view {
            let marker = CALayer()
            marker.frame = view.bounds.insetBy(dx: 1, dy: 1)
            marker.cornerRadius = 12
            marker.borderWidth = 1
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                marker.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
            }
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

    /// Loading is a renderer lifecycle transition, not new empty content or a
    /// disabled appearance for every row. Preserve the outgoing reading anchor
    /// before hiding; delayed geometry callbacks cannot overwrite it meanwhile.
    func suspend() {
        guard !suspended else { return }
        saveReadingPosition()
        saveReadingHeights()
        readingIntent += 1 // Invalidate queued find/resize callbacks from the outgoing reader.
        if ConversationReadingMemory.shared.following[sessionId] == false {
            restoreTarget = ConversationReadingMemory.shared.positions[sessionId]
        }
        suspended = true
        isHidden = true
    }

    func configure(_ next: [ConversationEntryView], contentIdentity: ConversationContentIdentity, navigation: [ConversationTurnSummary], sessionId: String,
                   appearance: ConversationEntryAppearance, viewport: ConversationViewport?,
                   contentOriginY: CGFloat, waitsForInitialPosition: Bool = false) {
        self.waitsForInitialPosition = waitsForInitialPosition
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("document_configure", since: start) }
        #endif
        ConversationReadingMemory.shared.visit(sessionId)
        if self.viewport !== viewport {
            self.viewport?.remove(self)
            self.viewport = viewport
            viewport?.add(self)
        }
        let structureChanged: Bool
        if self.contentIdentity == contentIdentity, self.sessionId == sessionId, rowAppearance == appearance {
            structureChanged = false
        } else {
            structureChanged = reconcileRows(next, sessionId: sessionId, appearance: appearance)
            self.contentIdentity = contentIdentity
        }
        if structureChanged || self.navigation != navigation {
            self.navigation = navigation
            turnRows = navigation.compactMap { indices[$0.id] }
        }
        suspended = false
        isHidden = preparingInitialViewport
        self.contentOriginY = contentOriginY
        observeScroll()
        restoreReadingPosition()
        refreshVisibleRows(source: .configure)
        publishHeight()
        viewport?.refresh()
    }

    func updateContentOrigin(_ value: CGFloat) {
        guard contentOriginY != value else { return }
        // The loading row above the document changes height when history
        // arrives. Pin the anchor so the reader's rows do not drift.
        if restoreTarget == nil, ConversationReadingMemory.shared.following[sessionId] == false {
            saveReadingPosition()
            restoreTarget = ConversationReadingMemory.shared.positions[sessionId]
        }
        contentOriginY = value
        restoreReadingPosition()
        refreshVisibleRows(source: .contentOrigin)
        viewport?.refresh()
    }

    /// Content reconciliation and viewport layout have separate invalidation rules.
    /// Scrolling/origin updates preserve row geometry; same-ID edits update only
    /// their controllers, and offscreen edits do not remeasure the visible range.
    @discardableResult
    private func reconcileRows(_ next: [ConversationEntryView], sessionId: String,
                               appearance: ConversationEntryAppearance) -> Bool {
        let changedSession = self.sessionId != sessionId
        let changedAppearance = rowAppearance != appearance
        guard changedSession || changedAppearance || contents != next else { return false }
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("document_reconcile", since: start) }
        #endif
        if !changedSession, let first = contents.first?.entry.id,
           next.first?.entry.id != first, next.contains(where: { $0.entry.id == first }) {
            saveReadingPosition()
            restoreTarget = ConversationReadingMemory.shared.positions[sessionId]
        }
        if changedSession {
            readingIntent += 1
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
            preparingInitialViewport = waitsForInitialPosition
            isHidden = preparingInitialViewport
            self.sessionId = sessionId
        }
        let structureChanged = changedSession || contents.count != next.count || !zip(contents, next).allSatisfy {
            $0.entry.id == $1.entry.id && $0.entry.isProcess == $1.entry.isProcess
        }
        if changedSession || changedAppearance { measuredSizes.removeAll(keepingCapacity: true) }
        if structureChanged {
            let previous = Dictionary(uniqueKeysWithValues: zip(contents.map { $0.entry.id }, heights))
            indices = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.entry.id, $0.offset) })
            measuredSizes = measuredSizes.filter { indices[$0.key] != nil }
            heights = next.map { previous[$0.entry.id] ?? ConversationReadingMemory.shared.measuredHeights[sessionId]?[$0.entry.id] ?? 160 }
            for id in Array(controllers.keys) {
                guard let index = indices[id] else {
                    controllers.removeValue(forKey: id)?.view.removeFromSuperview()
                    mounted.remove(id)
                    continue
                }
                controllers[id]?.update(next[index], appearance: appearance)
            }
            contents = next
            rebuildOffsets()
        } else {
            for (old, new) in zip(contents, next) where changedAppearance || old != new {
                let id = new.entry.id
                measuredSizes.removeValue(forKey: id)
                controllers[id]?.update(new, appearance: appearance)
                if mounted.contains(id) { laidOutRange = nil }
            }
            contents = next
        }
        self.rowAppearance = appearance
        return structureChanged
    }
    /// Releasing hundreds of hosting graphs in the selection transaction stalls
    /// the main thread. Drain a small batch between frames, on AppKit's thread.
    func prepareForRemoval() {
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
        guard !suspended else { return CGSize(width: nextWidth, height: totalHeight) }
        if columnWidth != nextWidth {
            // AppKit can adjust the clip origin when wrapping changes, even if
            // no row above the reader changes height. Capture before measuring.
            if ConversationReadingMemory.shared.following[sessionId] == false, restoreTarget == nil {
                saveReadingPosition()
                let target = ConversationReadingMemory.shared.positions[sessionId]
                let session = sessionId
                let intent = readingIntent
                // Finish AppKit's resize transaction before restoring; restoring
                // during measurement is overwritten by the clip-view adjustment.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.readingIntent == intent, self.sessionId == session, self.columnWidth == nextWidth,
                          ConversationReadingMemory.shared.following[session] == false else { return }
                    self.restoreTarget = target
                    self.restoreReadingPosition()
                }
            }
            laidOutRange = nil
        }
        columnWidth = nextWidth
        refreshVisibleRows(source: .measurement)
        return CGSize(width: columnWidth, height: totalHeight)
    }
    /// Rows mounting above the reader resolve their estimates during a refresh.
    /// Defer the O(history) offsets rebuild to the end of the pass; the anchor
    /// must be pinned from pre-pass geometry, which matches the on-screen rows.
    private var deferringGeometry = false
    private var geometryDirty = false
    private func rebuildOffsets() {
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("row_geometry", since: start) }
        #endif
        laidOutRange = nil
        geometry = ConversationRowGeometry(heights: heights, spacingAfter: contents.indices.map(spacing(after:)))
    }
    private func spacing(after index: Int) -> CGFloat {
        index + 1 < contents.count && contents[index].entry.isProcess && contents[index + 1].entry.isProcess ? 6 : 18
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
    func refreshVisibleRows(source: ConversationRefreshSource) {
        #if TRANSCRIPT_CHECKS
        let refreshStart = CACurrentMediaTime()
        defer {
            NavigationRenderMetrics.record("refresh_total", since: refreshStart)
            NavigationRenderMetrics.record("refresh_source_\(source.rawValue)", since: refreshStart)
        }
        #endif
        guard !suspended, !refreshing, let appearance = rowAppearance, !contents.isEmpty else {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.record(refreshing ? "refresh_guard_reentrant" : "refresh_guard_unavailable", since: refreshStart)
            #endif
            return
        }
        refreshing = true
        defer { refreshing = false; revealInitialViewportIfReady() }
        var visible = viewportRect
        if preparingInitialViewport, ConversationReadingMemory.shared.following[sessionId] != false {
            // Lay out the incoming tail directly, not the outgoing clip position
            // or the top of a newly created scroll view. Keep estimates hidden.
            visible.origin.y = max(0, totalHeight - visible.height)
        }
        // Mount exactly the visible range; wider speculative ranges measured as
        // pure overhead on whole-viewport steps and did not pay for themselves.
        var index = min(geometry.firstIntersecting(max(0, visible.minY)), contents.count - 1)
        let first = index
        let end = max(first, geometry.end(before: visible.maxY))
        #if TRANSCRIPT_CHECKS
        let previousRange = laidOutRange
        #endif
        // Most wheel deltas stay within the same rows. The clip view moves their
        // pixels; no hosting measurement, frame writes or reattachment is needed.
        if laidOutRange == first..<end {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.record("refresh_same_range", since: refreshStart)
            #endif
            return
        }
        #if TRANSCRIPT_CHECKS
        let rangeWorkStart = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("refresh_range_work", since: rangeWorkStart) }
        #endif
        // Pin the reading position from pre-pass geometry (what is on screen now)
        // before rows above the reader resolve their estimates this pass. Edits
        // and disclosures evict their measuredSizes entry, so presence at the
        // committed width is enough to prove a row will not shift this pass.
        if restoreTarget == nil, ConversationReadingMemory.shared.following[sessionId] == false,
           let reading = readingRowForAnchor(), first < reading,
           (first..<reading).contains(where: { row in
               guard let measured = measuredSizes[contents[row].entry.id] else { return true }
               return measured.width != columnWidth
           }) {
            saveReadingPosition()
            restoreTarget = ConversationReadingMemory.shared.positions[sessionId]
        }
        deferringGeometry = true
        var nextMounted: Set<String> = []
        var rowY = offsets[first]
        while index < contents.count && rowY < visible.maxY {
            let content = contents[index]
            let id = content.entry.id
            let controller: ConversationEntryController
            if let existing = controllers[id] {
                controller = existing
            } else {
                let measuredSize: (width: CGFloat, height: CGFloat)? = measuredSizes[id].flatMap {
                    $0.width == columnWidth && $0.content == content ? ($0.width, $0.height) : nil
                }
                controller = ConversationEntryController(content: content, appearance: appearance, measuredSize: measuredSize, disclosureChanged: { [weak self] in self?.beginDisclosureChange(id) }) { [weak self] height in
                    self?.rowHeightChanged(id, height: height)
                }
                controllers[id] = controller
            }
            // Give a cold host its real window and width before asking SwiftUI
            // for its size. Measuring detached builds a graph that attachment
            // immediately invalidates and lays out again.
            if controller.view.superview !== self {
                controller.layout(frame: CGRect(x: 0, y: rowY, width: columnWidth, height: heights[index]), contentHeight: heights[index])
                #if TRANSCRIPT_CHECKS
                let attachStart = CACurrentMediaTime()
                #endif
                addSubview(controller.view)
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.record("host_attach", since: attachStart)
                NavigationRenderMetrics.record(controller.hasAttached ? "host_reattach" : "host_first_attach", since: attachStart)
                controller.hasAttached = true
                #endif
            }
            let height = controller.measure(width: columnWidth).height
            measuredSizes[id] = (content, columnWidth, height)
            updateHeight(id, height: height)
            controller.layout(frame: CGRect(x: 0, y: rowY, width: columnWidth, height: heights[index]), contentHeight: height)
            nextMounted.insert(id)
            rowY += heights[index] + spacing(after: index)
            index += 1
        }
        deferringGeometry = false
        let nextRange = first..<index
        // Resolve this pass's height updates in one rebuild, then correct row
        // positions against the final geometry (rows already in place skip).
        if geometryDirty {
            geometryDirty = false
            rebuildOffsets()
            for row in nextRange {
                let id = contents[row].entry.id
                let frame = CGRect(x: 0, y: offsets[row], width: columnWidth, height: heights[row])
                if let controller = controllers[id], controller.view.frame != frame {
                    controller.layout(frame: frame, contentHeight: heights[row])
                }
            }
        }
        #if TRANSCRIPT_CHECKS
        let overlap: Int
        if let previousRange {
            overlap = max(0, min(previousRange.upperBound, nextRange.upperBound) - max(previousRange.lowerBound, nextRange.lowerBound))
            NavigationRenderMetrics.count("refresh_exited_rows", by: previousRange.count - overlap)
        } else {
            overlap = 0
        }
        NavigationRenderMetrics.count("refresh_rows_visited", by: nextRange.count)
        NavigationRenderMetrics.count("refresh_overlap_rows", by: overlap)
        NavigationRenderMetrics.count("refresh_entered_rows", by: nextRange.count - overlap)
        #endif
        for id in mounted.subtracting(nextMounted) { controllers[id]?.view.removeFromSuperview() }
        mounted = nextMounted
        laidOutRange = nextRange
        if highlight != nil { applyFindHighlights() }
        let retained = geometry.retainedRows(around: nextRange)
        var retired: [ConversationEntryController] = []
        for id in Array(controllers.keys) where !mounted.contains(id) {
            if let row = indices[id], retained.contains(row) { continue }
            if let controller = controllers.removeValue(forKey: id) { retired.append(controller) }
        }
        Self.retire(retired)
        publishHeight()
    }
    private func revealInitialViewportIfReady() {
        guard preparingInitialViewport, !suspended, observedClip != nil,
              abs(bounds.height - totalHeight) < 1, restoreTarget == nil else { return }
        if !contents.isEmpty, ConversationReadingMemory.shared.following[sessionId] != false,
           viewportRect.maxY < totalHeight - 1 { return }
        preparingInitialViewport = false
        isHidden = false
    }

    private func beginDisclosureChange(_ id: String) {
        measuredSizes.removeValue(forKey: id)
        laidOutRange = nil
        viewport?.pauseFollowing?()
        // Pin the reader before SwiftUI removes/inserts disclosure content.
        // This also covers a change in the currently anchored row itself.
        if restoreTarget == nil {
            saveReadingPosition()
            restoreTarget = ConversationReadingMemory.shared.positions[sessionId]
        }
    }
    private func updateHeight(_ id: String, height: CGFloat) {
        guard let index = indices[id], heights[index] != height else { return }
        if deferringGeometry {
            // Anchors were pinned from pre-pass geometry; rebuild once at the
            // end of the pass instead of per resolved row.
            heights[index] = height
            geometryDirty = true
            return
        }
        if restoreTarget == nil, ConversationReadingMemory.shared.following[sessionId] == false,
           let reading = readingRowForAnchor(), index < reading {
            saveReadingPosition()
            restoreTarget = ConversationReadingMemory.shared.positions[sessionId]
        }
        heights[index] = height
        rebuildOffsets()
    }
    private func rowHeightChanged(_ id: String, height: CGFloat) {
        if let controller = controllers[id], let index = indices[id] {
            measuredSizes[id] = (contents[index], controller.view.bounds.width, height)
        }
        updateHeight(id, height: height)
        // Resize the host and reposition its neighbors together, before the
        // deferred SwiftUI document-height publication can display stale frames.
        refreshVisibleRows(source: .rowHeight)
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
            guard !self.suspended else { return }
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
    override func viewWillDraw() {
        // AppKit may clamp the clip origin after a height change, before the
        // coalesced viewport callback runs. Populate that visible range before
        // drawing, so a cached reply cannot disappear for one display pass.
        refreshVisibleRows(source: .willDraw)
        super.viewWillDraw()
    }
    override func layout() {
        super.layout()
        restoreReadingPosition()
        revealInitialViewportIfReady()
    }
    private func readingRowForAnchor() -> Int? {
        // During upward scrolling, a cold estimated row can enter above rows
        // already on screen. Anchor those displayed rows while its height is
        // resolved, rather than anchoring the unmeasured placeholder itself.
        let visible = viewportRect
        return mounted.compactMap { id -> Int? in
            guard let controller = controllers[id], controller.view.frame.intersects(visible) else { return nil }
            return indices[id]
        }.min() ?? geometry.readingRow(at: max(0, visible.minY))
    }
    private func saveReadingPosition() {
        guard !suspended, !preparingInitialViewport, restoreTarget == nil, !sessionId.isEmpty, let clip = observedClip,
              let index = readingRowForAnchor(),
              contents.indices.contains(index) else { return }
        ConversationReadingMemory.shared.savePosition(.init(entry: contents[index].entry.id,
            index: index, offset: clip.bounds.minY - contentOriginY - offsets[index]), for: sessionId)
    }
    private func saveReadingHeights() {
        guard !sessionId.isEmpty else { return }
        ConversationReadingMemory.shared.saveHeights(Dictionary(uniqueKeysWithValues: zip(contents.map { $0.entry.id }, heights)), for: sessionId)
    }
    fileprivate func cancelPendingRestoration() {
        guard !suspended else { return }
        preparingInitialViewport = false
        isHidden = false
        readingIntent += 1
        restoreTarget = nil
    }
    private func restoreReadingPosition() {
        guard !suspended else { return }
        // Return to latest can run before the queued height publication.
        if ConversationReadingMemory.shared.following[sessionId] == true {
            restoreTarget = nil
            return
        }
        guard let target = restoreTarget, let clip = observedClip, abs(bounds.height - totalHeight) < 1, !contents.isEmpty else { return }
        let index = indices[target.entry] ?? min(target.index, contents.count - 1)
        let y = max(0, offsets[index] + target.offset + contentOriginY)
        clip.scroll(to: NSPoint(x: 0, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
        restoreTarget = nil
        refreshVisibleRows(source: .restore)
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
        ) { [weak self] _ in
            // A content resize can move the clip after drawing has already been
            // scheduled. Mount the new range in this geometry transaction.
            self?.refreshVisibleRows(source: .clipBounds)
            self?.viewport?.refresh()
            self?.saveReadingPosition()
            self?.loadEarlierIfNearTop()
        }
    }
    /// Wheel, trackpad, keyboard and programmatic moves all flow through this
    /// bounds stream. Prefetch one viewport before the loaded top edge so the
    /// page arrives while the reader is still scrolling toward it.
    private func loadEarlierIfNearTop() {
        let visible = viewportRect
        guard observedClip != nil, !suspended, !preparingInitialViewport,
              visible.minY <= max(480, visible.height) else { return }
        viewport?.nearTop?()
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
    /// Highlight every find-bar match in the currently mounted text views.
    /// Rows mounted later pick it up in refreshVisibleRows; streaming rows
    /// re-apply from ReplyTextView.update.
    private func applyFindHighlights() {
        for id in mounted {
            guard let view = controllers[id]?.view else { continue }
            applyFindHighlights(in: view)
        }
    }
    private func applyFindHighlights(in view: NSView) {
        if let text = view as? ReplyTextView {
            text.findHighlight = highlight.map { (query: $0.query, caseSensitive: $0.options.caseSensitive, regex: $0.options.regex) }
            text.applyFindHighlight()
        }
        for subview in view.subviews { applyFindHighlights(in: subview) }
    }
    deinit {
        if let findObserver { NotificationCenter.default.removeObserver(findObserver) }
        if let highlightObserver { NotificationCenter.default.removeObserver(highlightObserver) }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
}

#if TRANSCRIPT_CHECKS
extension ConversationTranscript {
    static func document(in root: NSView) -> NSView? {
        if root is ConversationDocumentView { return root }
        return root.subviews.lazy.compactMap { document(in: $0) }.first
    }
    static func checkReconciliation(in root: NSView) throws -> [String: Any]? {
        if let document = root as? ConversationDocumentView { return try document.checkReconciliation() }
        for child in root.subviews {
            if let result = try checkReconciliation(in: child) { return result }
        }
        return nil
    }
    static func missingVisibleRows(in root: NSView) -> [String] {
        if let document = root as? ConversationDocumentView { return document.missingVisibleRows }
        return root.subviews.flatMap { missingVisibleRows(in: $0) }
    }
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
    let actionContext: ConversationActionContext?
    init(_ environment: EnvironmentValues) {
        colorScheme = environment.colorScheme
        layoutDirection = environment.layoutDirection
        displayScale = environment.displayScale
        dynamicTypeSize = environment.dynamicTypeSize
        reduceMotion = environment.accessibilityReduceMotion || environment.conversationReduceMotion
        isEnabled = environment.isEnabled
        actionContext = environment.conversationActionContext
    }
}

private struct HostedConversationEntry: View {
    let content: ConversationEntryView
    let appearance: ConversationEntryAppearance
    var disclosureChanged: () -> Void = {}
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
            .environment(\.conversationActionContext, appearance.actionContext)
            // Match Perch's ink and monochrome disclosure/control tint in both appearances.
            .foregroundStyle(WorkbenchTheme.ink)
            .tint(WorkbenchTheme.accent)
    }
}

/// Parse and attributed-string construction are pure functions of the source
/// text, and the built strings use dynamic colors. Recreated hosts reuse the
/// earlier preparation instead of parsing the same history on every revisit.
/// Bounded by entry count and retained source size.
private final class NativeRowPreparationCache {
    private enum Value {
        case user(source: String, preparation: NativeParagraphContent.Preparation)
        case assistant(source: String, allowsRichBlocks: Bool, preparation: NativeAssistantContent.Preparation)
        var source: String {
            switch self {
            case .user(let source, _): return source
            case .assistant(let source, _, _): return source
            }
        }
    }
    private struct Key: Hashable { let session: String; let messageID: String }
    private var entries: [Key: Value] = [:]
    private var order: [Key] = []
    private var sourceBytes = 0

    func user(session: String, messageID: String, source: String,
              prepare: () -> NativeParagraphContent.Preparation) -> NativeParagraphContent.Preparation {
        let key = Key(session: session, messageID: messageID)
        if case .user(let cached, let preparation) = entries[key], cached == source {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("row_prepare_cache_hit")
            #endif
            return preparation
        }
        let preparation = prepare()
        store(key, .user(source: source, preparation: preparation))
        return preparation
    }

    func assistant(session: String, messageID: String, source: String, allowsRichBlocks: Bool,
                   prepare: () -> NativeAssistantContent.Preparation) -> NativeAssistantContent.Preparation {
        let key = Key(session: session, messageID: messageID)
        if case .assistant(let cached, let cachedAllows, let preparation) = entries[key],
           cached == source, cachedAllows == allowsRichBlocks {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("row_prepare_cache_hit")
            #endif
            return preparation
        }
        let preparation = prepare()
        store(key, .assistant(source: source, allowsRichBlocks: allowsRichBlocks, preparation: preparation))
        return preparation
    }

    private func store(_ key: Key, _ value: Value) {
        if let old = entries[key] {
            sourceBytes -= old.source.utf8.count
        } else {
            order.append(key)
        }
        entries[key] = value
        sourceBytes += value.source.utf8.count
        while entries.count > 240 || sourceBytes > 12 * 1024 * 1024, !order.isEmpty {
            let oldest = order.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) { sourceBytes -= evicted.source.utf8.count }
        }
        #if TRANSCRIPT_CHECKS
        NavigationRenderMetrics.count("row_prepare_cache_store")
        #endif
    }
}

private let nativeRowPreparations = NativeRowPreparationCache()

private final class ConversationEntryController: NSViewController {
    private var host: NSHostingController<HostedConversationEntry>?
    private var nativeUser: NativeUserMessageView?
    private var nativeAssistant: NativeAssistantMessageView?
    private var content: ConversationEntryView
    private var appearance: ConversationEntryAppearance
    private var generation = 0
    private var sizes: [(width: CGFloat, height: CGFloat)] = []
    /// Width of the last committed native place; content changes re-place.
    private var placedWidth: CGFloat?
    private var pendingSize: (size: CGSize, generation: Int)?
    private var notificationScheduled = false
    private var publishedHeight: CGFloat?
    private var widthMeasurementScheduled = false
    #if TRANSCRIPT_CHECKS
    var hasAttached = false
    private var hasMeasured = false
    private var diagnosticKind: String {
        if nativeUser != nil { return "native_user" }
        if nativeAssistant != nil { return "native_assistant" }
        return "swiftui_" + String(describing: content.entry.presentation)
    }
    #endif
    var heightChanged: (CGFloat) -> Void
    private let disclosureChanged: () -> Void

    init(content: ConversationEntryView, appearance: ConversationEntryAppearance,
         measuredSize: (width: CGFloat, height: CGFloat)? = nil,
         disclosureChanged: @escaping () -> Void, heightChanged: @escaping (CGFloat) -> Void) {
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer {
            NavigationRenderMetrics.record("host_create", since: start)
            NavigationRenderMetrics.record("row_create_" + diagnosticKind, since: start)
        }
        #endif
        self.content = content
        self.appearance = appearance
        self.heightChanged = heightChanged
        self.disclosureChanged = disclosureChanged
        super.init(nibName: nil, bundle: nil)
        if let measuredSize { sizes.append(measuredSize) }
        setRoot()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer {
            NavigationRenderMetrics.record("host_view", since: start)
            NavigationRenderMetrics.record("row_view_" + diagnosticKind, since: start)
        }
        #endif
        let container = ConversationEntryContainer()
        container.identifier = NSUserInterfaceItemIdentifier(content.entry.id)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        if let nativeUser { container.addSubview(nativeUser) }
        if let nativeAssistant { container.addSubview(nativeAssistant) }
        if let host { addChild(host); container.addSubview(host.view) }
        container.widthChanged = { [weak self] in self?.committedWidthChanged() }
        // The row already owns its measured frame; its sole child fills it.
        // Avoid rebuilding an Auto Layout constraint graph on viewport changes.
        view = container
    }
    func layout(frame: CGRect, contentHeight: CGFloat) {
        #if TRANSCRIPT_CHECKS
        let layoutStart = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("row_layout", since: layoutStart) }
        #endif
        let rowFrameChanged = view.frame != frame
        #if TRANSCRIPT_CHECKS
        NavigationRenderMetrics.count(rowFrameChanged ? "row_frame_write" : "row_frame_unchanged")
        #endif
        if rowFrameChanged { view.frame = frame }
        let hostFrame = CGRect(x: 0, y: 0, width: frame.width, height: contentHeight)
        if let host {
            let frameChanged = host.view.frame != hostFrame
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count(frameChanged ? "child_frame_write" : "child_frame_unchanged")
            #endif
            if frameChanged { host.view.frame = hostFrame }
        }
        if let nativeUser {
            let frameChanged = nativeUser.frame != hostFrame
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count(frameChanged ? "child_frame_write" : "child_frame_unchanged")
            #endif
            if frameChanged { nativeUser.frame = hostFrame }
            // place is a pure function of width and committed content; a row whose
            // frame survived the pass needs neither it nor its measurement pass.
            if frameChanged || placedWidth != frame.width {
                #if TRANSCRIPT_CHECKS
                let placeStart = CACurrentMediaTime()
                #endif
                nativeUser.place(width: frame.width)
                placedWidth = frame.width
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.record("native_place", since: placeStart)
                NavigationRenderMetrics.record("native_user_place", since: placeStart)
                #endif
            }
        }
        if let nativeAssistant {
            let frameChanged = nativeAssistant.frame != hostFrame
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count(frameChanged ? "child_frame_write" : "child_frame_unchanged")
            #endif
            if frameChanged { nativeAssistant.frame = hostFrame }
            if frameChanged || placedWidth != frame.width {
                #if TRANSCRIPT_CHECKS
                let placeStart = CACurrentMediaTime()
                #endif
                nativeAssistant.place(width: frame.width)
                placedWidth = frame.width
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.record("native_place", since: placeStart)
                NavigationRenderMetrics.record("native_assistant_place", since: placeStart)
                #endif
            }
        }
    }
    deinit {
        if let nativeUser { NativeUserMessageView.recycle(nativeUser) }
        if let nativeAssistant { NativeAssistantMessageView.recycle(nativeAssistant) }
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
        let contentChanged = content != next
        let appearanceChanged = appearance != nextAppearance
        guard contentChanged || appearanceChanged else { return }
        #if TRANSCRIPT_CHECKS
        if contentChanged { NavigationRenderMetrics.count("host_content_update") }
        if appearanceChanged { NavigationRenderMetrics.count("host_appearance_update") }
        #endif
        content = next
        appearance = nextAppearance
        generation += 1
        publishedHeight = nil
        sizes.removeAll(keepingCapacity: true)
        setRoot()
    }
    private func nativeUserPreparation() -> (messageID: String, source: String, value: NativeParagraphContent.Preparation)? {
        #if TRANSCRIPT_CHECKS
        if ProcessInfo.processInfo.environment["NAVIGATION_NATIVE_USER_ROWS"] == "0" { return nil }
        #endif
        guard appearance.layoutDirection == .leftToRight, content.activityNarrative == nil,
              content.entry.presentation == .message, content.entry.messages.count == 1,
              let message = content.entry.messages.first, message.isUserPrompt,
              message.content.count == 1, let part = message.content.first,
              part.type == "text", !part.isRuntimeContext, part.skillContextSplit == nil else { return nil }
        let source = part.text ?? ""
        let preparation = nativeRowPreparations.user(session: content.sessionId, messageID: message.id, source: source) {
            NativeParagraphContent.prepare(source, lineHeight: UserMessageStyle.lineHeight)
        }
        return (message.id, source, preparation)
    }
    private func nativeAssistantPreparation() -> (messageID: String, source: String, value: NativeAssistantContent.Preparation)? {
        #if TRANSCRIPT_CHECKS
        if ProcessInfo.processInfo.environment["NAVIGATION_NATIVE_ASSISTANT_ROWS"] == "0" { return nil }
        let allowsRichBlocks = ProcessInfo.processInfo.environment["NAVIGATION_NATIVE_ASSISTANT_BLOCKS"] != "0"
        #else
        let allowsRichBlocks = true
        #endif
        guard appearance.layoutDirection == .leftToRight, content.activityNarrative == nil,
              content.entry.presentation == .message, content.entry.messages.count == 1,
              let message = content.entry.messages.first, message.role == "assistant", !message.isCompactionSummary,
              message.content.count == 1, let part = message.content.first,
              part.type == "text", !part.isRuntimeContext, part.skillContextSplit == nil,
              let source = part.text else { return nil }
        let preparation = nativeRowPreparations.assistant(session: content.sessionId, messageID: message.id,
                                                          source: source, allowsRichBlocks: allowsRichBlocks) {
            NativeAssistantContent.prepare(source, allowsRichBlocks: allowsRichBlocks)
        }
        return (message.id, source, preparation)
    }
    private func fallbackPreparation(messageID: String, source: String, blocks: [ReplyBlock]) -> ReplyMarkdownPreparation {
        #if TRANSCRIPT_CHECKS
        if ProcessInfo.processInfo.environment["NAVIGATION_REUSE_REJECTED_MARKDOWN"] == "0" {
            return .reparseRejected(sessionID: content.sessionId, messageID: messageID, source: source)
        }
        #endif
        return .reuse(sessionID: content.sessionId, messageID: messageID, source: source, blocks: blocks)
    }
    private func setRoot() {
        #if TRANSCRIPT_CHECKS
        // Covers native admission probing (parse + attributed construction), native
        // view acquisition and text-storage replacement, and NSHostingController
        // creation for fallback rows. Nested inside host_create/host_view callers.
        let rootStart = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("set_root", since: rootStart) }
        #endif
        placedWidth = nil
        var markdownPreparation: ReplyMarkdownPreparation?
        if let user = nativeUserPreparation() {
            if let paragraphs = user.value.content {
                if let nativeAssistant { NativeAssistantMessageView.recycle(nativeAssistant); self.nativeAssistant = nil }
                if let host { host.view.removeFromSuperview(); host.removeFromParent(); self.host = nil }
                if nativeUser == nil {
                    nativeUser = NativeUserMessageView.acquire()
                    if isViewLoaded { view.addSubview(nativeUser!) }
                }
                nativeUser!.actionContext = appearance.actionContext
                nativeUser!.sourceText = user.source
                nativeUser!.bookmarkTurn = self.content.entry.id
                nativeUser!.bookmarkSession = self.content.memoryKey
                nativeUser!.update(paragraphs, dark: appearance.colorScheme == .dark)
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.record("native_user_update", since: CACurrentMediaTime())
                #endif
                return
            }
            markdownPreparation = fallbackPreparation(messageID: user.messageID, source: user.source, blocks: user.value.blocks)
        }
        if let nativeUser { NativeUserMessageView.recycle(nativeUser); self.nativeUser = nil }
        if let assistant = nativeAssistantPreparation() {
            if let blocks = assistant.value.content {
                if let host { host.view.removeFromSuperview(); host.removeFromParent(); self.host = nil }
                if nativeAssistant == nil {
                    nativeAssistant = NativeAssistantMessageView.acquire()
                    if isViewLoaded { view.addSubview(nativeAssistant!) }
                }
                nativeAssistant!.update(blocks, source: assistant.source,
                                        dark: appearance.colorScheme == .dark, enabled: appearance.isEnabled,
                                        actionContext: appearance.actionContext, messageID: assistant.messageID)
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.record("native_assistant_update", since: CACurrentMediaTime())
                #endif
                return
            }
            markdownPreparation = fallbackPreparation(messageID: assistant.messageID, source: assistant.source,
                                                       blocks: assistant.value.blocks)
        }
        if let nativeAssistant { NativeAssistantMessageView.recycle(nativeAssistant); self.nativeAssistant = nil }
        var hostedContent = content
        hostedContent.markdownPreparation = markdownPreparation
        let version = generation
        let root = HostedConversationEntry(content: hostedContent, appearance: appearance, disclosureChanged: { [weak self] in
            self?.sizes.removeAll(keepingCapacity: true)
            self?.disclosureChanged()
        }) { [weak self] size in
            self?.contentSizeChanged(size, generation: version)
        }
        if let host { host.rootView = root }
        else {
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            host.safeAreaRegions = []
            self.host = host
            if isViewLoaded { addChild(host); view.addSubview(host.view) }
        }
    }
    func measure(width proposed: CGFloat?) -> CGSize {
        let width = max(1, proposed?.isFinite == true ? proposed! : ReplyStyle.readingWidth)
        let height: CGFloat
        if let cached = sizes.first(where: { $0.width == width }) {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("host_size_cache_hit")
            #endif
            height = cached.height
        } else {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("host_size_cache_miss")
            let start = CACurrentMediaTime()
            defer {
                NavigationRenderMetrics.record("host_measure", since: start)
                NavigationRenderMetrics.record("row_measure_" + diagnosticKind, since: start)
                NavigationRenderMetrics.record(hasMeasured ? "host_remeasure" : "host_first_measure", since: start)
                NavigationRenderMetrics.record(content.entry.messages.first?.isUserPrompt == true ? "host_measure_user" : "host_measure_assistant", since: start)
                hasMeasured = true
            }
            #endif
            height = ceil(nativeUser?.measure(width: width).height ?? nativeAssistant?.measure(width: width).height
                          ?? host!.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
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

/// Assistant rows offer copy, quote-into-composer and regenerate. Regenerate
/// re-sends the preceding user prompt; the connection reports when none exists.
private struct AssistantEntryActions: View {
    let text: String
    let messageID: String
    @Environment(\.conversationActionContext) private var context
    var body: some View {
        HStack(spacing: 2) {
            ReplyCopyButton(text: text)
            if let context {
                Button { context.post(.quote(text)) } label: {
                    Image(systemName: "quote.opening").font(.system(size: 11))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("引用到输入框")
                    .accessibilityLabel("引用到输入框")
                if !messageID.isEmpty {
                    Button { context.post(.regenerate(before: messageID)) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("重新生成（重发上一条提问）")
                        .accessibilityLabel("重新生成")
                }
            }
        }
    }
}

/// A concrete native viewport avoids relying on NSView.visibleRect: SwiftUI's
/// scroll clipping is not always represented by an enclosing NSClipView.
final class ConversationViewport {
    fileprivate weak var view: NSView?
    var pauseFollowing: (() -> Void)?
    /// Reaching the loaded history's top edge asks the owner for the next page.
    var nearTop: (() -> Void)?
    let navigator = ConversationTurnNavigation()
    private let rows = NSHashTable<NSView>.weakObjects()
    private var scheduled = false
    fileprivate func add(_ row: NSView) { rows.add(row); refresh() }
    fileprivate func remove(_ row: NSView) { rows.remove(row); refresh() }
    func userScrolled() {
        for row in rows.allObjects {
            (row as? ConversationDocumentView)?.cancelPendingRestoration()
        }
    }
    func refresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            // Coalesce scroll and layout updates into one document pass.
            for row in self.rows.allObjects {
                if let document = row as? ConversationDocumentView {
                    document.refreshVisibleRows(source: .viewport)
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
    var onNearTop: () -> Void = {}
    func makeNSView(context: Context) -> MarkerView { viewport.pauseFollowing = onPauseFollowing; viewport.nearTop = onNearTop; return MarkerView(viewport: viewport) }
    func updateNSView(_ view: MarkerView, context: Context) { viewport.pauseFollowing = onPauseFollowing; viewport.nearTop = onNearTop; viewport.refresh() }
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
    var activityNarrative: ActivityNarrativeRow? = nil
    var markdownPreparation: ReplyMarkdownPreparation? = nil
    @RememberedExpansion("commentary") private var commentaryExpanded
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.tools == rhs.tools && lhs.api === rhs.api
            && lhs.sessionId == rhs.sessionId && lhs.memoryKey == rhs.memoryKey
            && lhs.activityNarrative == rhs.activityNarrative
            && lhs.markdownPreparation == rhs.markdownPreparation
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let activityNarrative, activityNarrative.isAnchor, activityNarrative.stageClosed,
               entry.isNarrativeSource(for: activityNarrative.narrative) {
                ActivityNarrativeHistoryView(narrative: activityNarrative.narrative)
            } else {
                switch entry.presentation {
                case .activity:
                    KimiActivityView(entry: entry, tools: tools, api: api, sessionId: sessionId,
                                     narrative: activityNarrative.flatMap {
                                         $0.isAnchor && $0.stageClosed ? $0.narrative : nil
                                     })
                case .commentary:
                    DisclosureGroup("此前的进度说明 · \(entry.messages.count) 条", isExpanded: $commentaryExpanded) {
                        if commentaryExpanded { VStack(alignment: .leading, spacing: 12) {
                            ForEach(entry.messages) { message in
                                KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId,
                                                markdownPreparation: markdownPreparation)
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
                        KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId,
                                        markdownPreparation: markdownPreparation, entryID: entry.id)
                    }
                    if entry.messages.first?.role == "assistant" && entry.presentation != .progress {
                        let text = entry.messages.flatMap(\.content).compactMap(\.text).joined(separator: "\n\n")
                        if !text.isEmpty {
                            AssistantEntryActions(text: text, messageID: entry.messages.first?.id ?? "")
                        }
                    }
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
        DisclosureReplyText(text: text, attributes: ThoughtTextStyle.attributes)
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

struct ThoughtDisclosure: View {
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
            ScrollView {
                SelectableReplyText(attributed: NSAttributedString(string: fullText, attributes: ThoughtTextStyle.attributes))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
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
