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

private let kimiPaper = Color(nsColor: WorkbenchTheme.userBubbleNS)

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
                        Text("上下文已压缩").font(.system(size: ReplyStyle.captionSize))
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                    }.foregroundStyle(.secondary).fixedSize()
                    divider
                }.contentShape(Rectangle())
            }.buttonStyle(WorkbenchDisclosureButtonStyle())
                .accessibilityValue(Text(expanded ? "已展开" : "已收起"))
            if expanded {
                KimiMarkdown(text: CompactionSummaryDisplay.humanText(text))
                    .environment(\.replyTone, .quiet)
                    .padding(.horizontal, ReplyStyle.Process.nestedIndent)
            }
        }
    }
    private var divider: some View {
        Color.primary.opacity(0.12).frame(height: 1)
    }
}

/// A scheduled wake-up is harness machinery that still anchors its turn: one
/// quiet marker line carrying the task summary, with the raw envelope folded
/// behind it. Full-width like the compaction divider, never a prompt bubble.
private struct CronFireRow: View {
    let envelope: CronFireEnvelope
    let raw: String
    @RememberedExpansion("cron-fire") private var expanded
    private var summary: String {
        envelope.prompt.split(separator: "\n").first.map(String.init) ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    divider
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .medium))
                        Text("定时任务触发").font(.system(size: ReplyStyle.captionSize)).fixedSize()
                        if !summary.isEmpty {
                            Text("· \(summary)").font(.system(size: ReplyStyle.captionSize))
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                    }.foregroundStyle(.secondary)
                    divider
                }.contentShape(Rectangle())
            }.buttonStyle(WorkbenchDisclosureButtonStyle())
                .accessibilityLabel("定时任务触发")
                .accessibilityValue(Text(expanded ? "已展开" : "已收起"))
            if expanded {
                Text(raw).font(.system(size: ReplyStyle.captionSize, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.horizontal, ReplyStyle.Process.nestedIndent)
            }
        }
    }
    private var divider: some View {
        Color.primary.opacity(0.12).frame(height: 1)
    }
}

struct LongUserPrompt<Content: View>: View {
    @ViewBuilder let content: Content
    @RememberedExpansion("user-prompt") private var expanded
    @State private var naturalHeight: CGFloat = 0
    private var folds: Bool { naturalHeight > UserMessageStyle.foldThreshold }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content.fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
                .frame(maxHeight: folds && !expanded ? UserMessageStyle.collapsedHeight : nil, alignment: .top)
                .clipped()
            if folds {
                Button(expanded ? "收起问题" : "展开完整问题") { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: ReplyStyle.labelSize)).foregroundStyle(.secondary)
                    .frame(height: 24, alignment: .leading)
                    .accessibilityIdentifier("user-prompt-toggle")
            }
        }
    }
}

struct KimiMessageView: View {
    let message: KimiMessage
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    var markdownPreparation: ReplyMarkdownPreparation? = nil
    var streaming = false
    /// A native row's release survives a temporary hosted Markdown fallback.
    var displayTextOverride: String? = nil
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
        DisclosureGroup {
            KimiMarkdown(text: text).environment(\.replyTone, .quiet)
                .padding(.leading, ReplyStyle.Process.nestedIndent)
        } label: {
            Text("运行上下文").font(.system(size: ReplyStyle.Process.labelSize)).foregroundStyle(.secondary)
        }.disclosureGroupStyle(ProcessDisclosureStyle())
    }
    private func compactionSummary(_ text: String) -> some View {
        CompactionSummaryRow(text: text)
    }
    var body: some View {
        if let envelope = message.cronFire {
            CronFireRow(envelope: envelope, raw: message.content.first?.text ?? "")
        } else if isUserMessage {
            UserMessageLayout {
                LongUserPrompt {
                    content.environment(\.replyLineHeight, UserMessageStyle.lineHeight)
                }
                    .padding(.horizontal, UserMessageStyle.horizontalPadding)
                    .padding(.top, UserMessageStyle.topPadding)
                    .padding(.bottom, UserMessageStyle.bottomPadding)
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
        VStack(alignment: .leading, spacing: ReplyStyle.entryPartSpacing) {
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
                    } else if isUserMessage, let raw = part.text, raw.contains("@\"") {
                        let refs = ProjectFileReference.references(in: raw)
                        if !refs.isEmpty {
                            UserPromptFileMentionRow(references: refs)
                            let compactText = Self.compactUserMentionText(raw, references: refs)
                            if !compactText.isEmpty {
                                KimiMarkdown(text: compactText, sessionID: sessionId, messageID: message.id)
                                    .environment(\.isConversationBodyText, true)
                            }
                        } else {
                            KimiMarkdown(text: raw, sessionID: sessionId, messageID: message.id,
                                         preparation: markdownPreparation)
                                .environment(\.isConversationBodyText, true)
                        }
                    } else {
                        let source = displayTextOverride ?? part.text ?? ""
                        SmoothReplyText(source: source, streaming: streaming && !isUserMessage && displayTextOverride == nil) { visible in
                            KimiMarkdown(text: visible, sessionID: sessionId, messageID: message.id,
                                         preparation: visible == source ? markdownPreparation : nil)
                        }.environment(\.isConversationBodyText, true)
                    }
                case "thinking": ThoughtDisclosure(text: part.thinking ?? "", publicSummary: ConversationThinkingSummary.publicSummary(of: part))
                case "tool_use":
                    if let tool = tools[part.toolCallId ?? ""] { KimiToolCard(tool: tool) }
                case "image", "file", "video":
                    KimiAttachmentView(part: part, api: api, sessionId: sessionId)
                default: EmptyView()
                }
            }
        }
    }
    private static func compactUserMentionText(_ raw: String, references: [ProjectFileReference]) -> String {
        let mutable = NSMutableString(string: raw)
        for ref in references.reversed() {
            mutable.replaceCharacters(in: ref.range, with: "")
        }
        return (mutable as String)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct UserPromptFileMentionRow: View {
    let references: [ProjectFileReference]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(references.enumerated()), id: \.offset) { _, ref in
                    let name = (ref.path as NSString).lastPathComponent
                    Button {
                        var url = URLComponents(); url.scheme = "perch-file"
                        url.queryItems = [URLQueryItem(name: "path", value: ref.path)]
                        if let target = url.url {
                            NotificationCenter.default.post(name: .init("PerchOpenConversationFile"), object: target)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: ReplyStyle.captionSize - 1, weight: .medium))
                                .foregroundStyle(WorkbenchTheme.quiet)
                            Text(verbatim: name)
                                .font(.system(size: ReplyStyle.captionSize, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.84))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.055),
                                    in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: ref.path))
                }
            }
        }
        .scrollIndicators(.never, axes: .horizontal)
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
    var foldsProcess = false
    var retainedProcessEntries: Set<String> = []
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot === rhs.snapshot && lhs.narratives == rhs.narratives
            && lhs.api === rhs.api && lhs.session == rhs.session && lhs.memoryKey == rhs.memoryKey
            && lhs.foldsProcess == rhs.foldsProcess && lhs.retainedProcessEntries == rhs.retainedProcessEntries
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
    /// A cached reader can stay online while its authoritative snapshot loads.
    /// Pause remote summary requests without changing the displayed projection.
    var allowsActivitySummaryRequests = true
    var followsLatest = true
    var historyEpoch: String?
    var isSuspended = false
    /// Completed turns collapse their process rows behind one disclosure.
    var foldsProcess = true
    /// The owner restores its initial scroll position before this document is exposed.
    var waitsForInitialPosition = false
    /// The connection's clock for the latest turn; its duration labels that turn's
    /// process fold once this view has watched the turn end.
    var timing: ConversationTiming? = nil
    /// Active Todo plan progress for the live stage header in a running turn.
    var planProgress: TurnStatus.Progress? = nil
    @Environment(\.conversationPresentations) private var presentations
    @State private var presentation = ConversationPresentationHandle()
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @ObservedObject var narrativeStore = ActivityNarrativeStore.shared
    @Environment(\.self) private var environment
    @State private var documentLayout = ConversationDocumentLayout()
    var body: some View {
        // Connection snapshots land here; their state types stay probe-free.
        let projectionProbe = PerfDiagnostics.begin()
        let key = memoryKey ?? sessionId
        let snapshot = presentation.update(key: key, input: ConversationPresentationModel.Input(
            messages: messages, live: liveTools, running: running, isRunning: isRunning, online: online,
            epoch: historyEpoch, language: environment.locale.identifier + ":" + AppLanguage.current.localization,
            summariesEnabled: summarySettings.configuration.enabled && allowsActivitySummaries && online,
            includeToolOutput: summarySettings.configuration.includeToolOutput), cache: presentations)
        let observation = SummaryObservation(session: key, batch: snapshot.batch, narrativeKey: snapshot.narrativeKey,
            running: isRunning, online: online && allowsActivitySummaries && allowsActivitySummaryRequests, following: followsLatest,
            settingsRevision: summarySettings.revision)
        let narratives = narrativeStore.rows(session: key, snapshot: snapshot.narrative, following: followsLatest)
        let retained = ConversationReadingMemory.shared.retainedEntries(session: key)
        let identity = ConversationContentIdentity(snapshot: snapshot, narratives: narratives,
            api: api, session: sessionId, memoryKey: key, foldsProcess: foldsProcess, retainedProcessEntries: retained)
        // Earlier turns are presented once per summary overlay; a streamed token
        // only presents the latest turn.
        let presented = snapshot.presented(activity: narratives, foldsProcess: foldsProcess, isRunning: isRunning, preservingEntries: retained)
            .retainingProcessEntries(retained)
        let foldParents = presented.foldParents
        let liveActivityID = isRunning ? ConversationProcessClock.lastActivityOfLatestTurn(presented.rows) : nil
        let latestFoldID = !isRunning ? ConversationProcessClock.lastFoldOfLatestTurn(presented.rows) : nil
        let settledDuration: TimeInterval? = {
            guard !isRunning, let timing, let ended = timing.endedAt else { return nil }
            let seconds = timing.elapsed(at: ended).rounded()
            return seconds >= 5 ? seconds : nil
        }()
        let streamingMessageID = isRunning && online && messages.last?.role == "assistant" ? messages.last?.id : nil
        let contents = presented.rows.map { row in
            let isLiveActivity = row.entry.id == liveActivityID
            let foldDuration = row.entry.id == latestFoldID ? settledDuration : nil
            return ConversationEntryView(entry: row.entry, tools: row.tools, api: api, sessionId: sessionId,
                memoryKey: key + ":" + row.entry.id, activityNarrative: row.activity, foldedRows: row.foldedRows,
                isLive: isLiveActivity, preservesExpandedProcess: row.entry.presentation != .processFold,
                liveThinkingSummary: (isLiveActivity || row.live) ? ConversationThinkingSummary.current(snapshot.narrative.current) : nil,
                planProgress: isLiveActivity ? planProgress : nil,
                completedDuration: foldDuration, liveProcessFold: row.live,
                liveStartedAt: row.live ? timing?.startedAt : nil,
                streamingMessageID: streamingMessageID.flatMap { id in
                    row.entry.messages.contains { $0.id == id } || row.foldedRows?.contains { $0.entry.messages.contains { $0.id == id } } == true ? id : nil
                })
        }
        let _ = PerfDiagnostics.end("snapshot_projection", projectionProbe,
                                    detail: "messages=\(messages.count) rows=\(contents.count)")
        ConversationDocumentSizingHost(contents: contents, contentIdentity: identity, navigation: snapshot.navigation,
                                       sessionId: sessionId, key: key, appearance: ConversationEntryAppearance(environment),
                                       foldParents: foldParents, viewport: environment.conversationViewport,
                                       layout: documentLayout, suspended: isSuspended,
                                       waitsForInitialPosition: waitsForInitialPosition)
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

/// Isolates measured-height state from `ConversationTranscript.body` so height
/// publications during streaming never re-project the transcript rows.
private struct ConversationDocumentSizingHost: View {
    let contents: [ConversationEntryView]
    let contentIdentity: ConversationContentIdentity
    let navigation: [ConversationTurnSummary]
    let sessionId: String
    let key: String
    let appearance: ConversationEntryAppearance
    let foldParents: [String: String]
    let viewport: ConversationViewport?
    let layout: ConversationDocumentLayout
    let suspended: Bool
    let waitsForInitialPosition: Bool
    @State private var measured: (session: String, height: CGFloat)?
    var body: some View {
        ConversationDocumentHost(contents: contents, contentIdentity: contentIdentity, navigation: navigation, sessionId: key,
                                 appearance: appearance, foldParents: foldParents,
                                 viewport: viewport,
                                 layout: layout, measuredHeight: measured?.session == sessionId ? measured?.height : nil,
                                 suspended: suspended, waitsForInitialPosition: waitsForInitialPosition) { height in
            measured = (sessionId, height)
        }
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
    /// Folded entry id -> its fold row id, so find results open the fold.
    let foldParents: [String: String]
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
                       viewport: viewport, foldParents: foldParents, contentOriginY: layout.originY, waitsForInitialPosition: waitsForInitialPosition)
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
    private var foldParents: [String: String] = [:]
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
    fileprivate var disconnectedTools: [String] {
        Array(Set(contentIdentity?.snapshot.rows.flatMap { row in
            row.tools.values.filter { $0.status == .disconnected }.map(\.id)
        } ?? [])).sorted()
    }
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
                "content": [["type": "text", "text": String(repeating: "same-ID changed content 中文 ", count: 30)]]] // l10n-ignore
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
        // A refresh that shrinks the body below the clip (a settled fold) must
        // pin the clip back into the body synchronously, not a display pass later.
        apply(original, appearance)
        _ = measure(width: columnWidth)
        guard let clip = observedClip else { throw WorkbenchError("Shrink fixture lost the clip view") }
        clip.scroll(to: NSPoint(x: 0, y: max(0, totalHeight - clip.bounds.height) + contentOriginY))
        enclosingScrollView?.reflectScrolledClipView(clip)
        refreshVisibleRows(source: .configure)
        apply(Array(original.suffix(2)), appearance)
        do {
            let visibleNow = viewportRect
            let covered = contents.indices.contains { index in
                offsets[index] < visibleNow.maxY && offsets[index] + heights[index] > visibleNow.minY
                    && mounted.contains(contents[index].entry.id)
            }
            guard visibleNow.minY <= max(0, totalHeight - visibleNow.height) + 1, covered else {
                throw WorkbenchError("Shrink left the clip outside the body for a display pass")
            }
        }
        // With a pending restore target the pin lands on the target row itself.
        apply(original, appearance)
        _ = measure(width: columnWidth)
        clip.scroll(to: NSPoint(x: 0, y: max(0, totalHeight - clip.bounds.height) + contentOriginY))
        enclosingScrollView?.reflectScrolledClipView(clip)
        refreshVisibleRows(source: .configure)
        let mid = original.count / 2
        restoreTarget = .init(entry: original[mid].entry.id, index: mid, offset: 0)
        defer { restoreTarget = nil }
        apply(Array(original[(mid - 15)...(mid + 15)]), appearance)
        guard let targetRow = indices[original[mid].entry.id], abs(viewportRect.minY - offsets[targetRow]) <= 1 else {
            throw WorkbenchError("Shrink restore did not land on the reading anchor")
        }
        // Reproduce the launch crash: separate folds from one persisted message
        // must survive the native unique-key indices and saved-height maps.
        // Fixture prose sits outside the JSON literal, which cannot hold a marker.
        let prompt = "分析并回答", firstThought = "第一段思考", firstAnswer = "第一段回答" // l10n-ignore
        let secondThought = "第二段思考", secondAnswer = "第二段回答" // l10n-ignore
        let multipart = try KimiWire.decoder().decode([KimiMessage].self, from: Data("""
        [{"id":"fold-user","role":"user","created_at":"1","content":[{"type":"text","text":"\(prompt)"}]},
         {"id":"fold-answer","role":"assistant","created_at":"2","content":[
           {"type":"thinking","thinking":"\(firstThought)"},{"type":"text","text":"\(firstAnswer)"},
           {"type":"thinking","thinking":"\(secondThought)"},{"type":"text","text":"\(secondAnswer)"}]}]
        """.utf8))
        let projection = ConversationPresentationModel(key: "fold-regression")
        let snapshot = projection.update(.init(messages: multipart, language: "en"))
        let folded = ConversationProcessFold.fold(rows: snapshot.displayedRows { _ in nil }, isRunning: false)
        let foldedContents = folded.map { row in
            ConversationEntryView(entry: row.entry, tools: row.tools, api: nil, sessionId: sessionId,
                memoryKey: sessionId + ":" + row.entry.id, activityNarrative: row.activity, foldedRows: row.foldedRows)
        }
        for _ in 0..<2 {
            apply(foldedContents, appearance)
            _ = measure(width: columnWidth)
            guard contents.count == 5, indices.count == 5, heights.count == 5,
                  foldedContents.enumerated().allSatisfy({ indices[$0.element.entry.id] == $0.offset }) else {
                throw WorkbenchError("Multipart fold reconciliation lost a row or reused another fold's index")
            }
            saveReadingHeights()
            apply(original, appearance)
        }
        return ["unchanged_replays": 40, "unchanged_reconciliations": 0, "unchanged_geometry_rebuilds": 0,
                "unchanged_host_measurements": 0, "same_id_offscreen_and_visible_edits": true,
                "appearance_invalidation": true, "external_summary_same_snapshot": true, "prepend_and_removal": true,
                "shrink_clip_pin": true, "shrink_restore_pin": true,
                "multipart_fold_reconciliation_and_heights": true]
    }
    fileprivate var navigator: ConversationTurnNavigation? { viewport?.navigator }
    /// Top-level document rows as (id, presentation), in reading order.
    fileprivate var rowIdentifiers: [(id: String, presentation: String)] {
        contents.map { ($0.entry.id, "\($0.entry.presentation)") }
    }
    fileprivate var retainedHostCount: Int { controllers.count }
    fileprivate var mountedHostCount: Int { mounted.count }
    fileprivate static var retiredHostCount: Int { retiredControllers.count }
    fileprivate var readingAnchor: (entry: String, offset: CGFloat)? {
        guard let row = geometry.readingRow(at: max(0, viewportRect.minY)), contents.indices.contains(row) else { return nil }
        return (contents[row].entry.id, viewportRect.minY - offsets[row])
    }
    /// The gesture mark a wheel tick sets, for fixtures that scroll the clip
    /// programmatically before approaching the top edge.
    fileprivate func markUserScroll() { viewport?.userScrolled() }
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
        if let toolID = target.hit.toolID {
            let id = target.hit.entryID, scope = sessionId + ":" + id
            for name in ["expanded", "thought"] {
                ConversationReadingMemory.shared.expansions[scope + ":" + name] = true
            }
            for name in ["expanded", "full-output"] {
                ConversationReadingMemory.shared.expansions[scope + ":tool:" + toolID + ":" + name] = true
            }
            invalidateRevealedRow(indices[id] == nil ? foldParents[id] ?? id : id)
        }
        revealEntry(target.hit.entryID)
        // Regular-expression hits reveal their row; only literal queries can
        // place the caret on the exact occurrence.
        guard target.options.canLocateOccurrence else { return }
        let intent = readingIntent
        DispatchQueue.main.async { [weak self] in
            guard let self, self.readingIntent == intent, self.sessionId == target.session,
                  let view = self.controllers[target.hit.entryID]?.view ?? self.foldParents[target.hit.entryID].flatMap({ self.controllers[$0]?.view }) else { return }
            // A newly mounted host may not have created its native text views yet.
            // Complete that host's layout before looking for the selected range.
            view.layoutSubtreeIfNeeded()
            var remaining = target.hit.toolOccurrence ?? target.hit.occurrence
            let anchorID = target.hit.toolID.map { "tool:" + $0 } ?? target.hit.entryID
            func anchor(in node: NSView) -> NSView? {
                if node.identifier?.rawValue == "process-entry:" + anchorID { return node }
                return node.subviews.lazy.compactMap { anchor(in: $0) }.first
            }
            let targetBounds = anchor(in: view).map { $0.convert($0.bounds, to: view) }
            let toolRecord = target.hit.toolID != nil && targetBounds != nil
            let root = view
            func select(in view: NSView) -> Bool {
                if let text = view as? NSTextView, (text as? ReplyTextView)?.isConversationBodyText == true
                    || (toolRecord && text is ReplyTextView)
                    || text.enclosingScrollView?.identifier?.rawValue == "perch-long-output" {
                    // A long reader's text document extends beyond its viewport;
                    // use the viewport to avoid selecting another row's hidden text.
                    let region: NSView = text.enclosingScrollView?.identifier?.rawValue == "perch-long-output" ? text.enclosingScrollView! : text
                    if let targetBounds, !targetBounds.intersects(region.convert(region.bounds, to: root)) { return false }
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
    private func invalidateRevealedRow(_ id: String) {
        measuredSizes.removeValue(forKey: id)
        if let controller = controllers.removeValue(forKey: id) {
            controller.view.removeFromSuperview()
            mounted.remove(id)
            Self.retire([controller])
        }
        laidOutRange = nil
    }
    private func revealEntry(_ id: String, highlight: Bool = false) {
        guard !suspended, let clip = observedClip else { return }
        var target = id
        if let index = indices[id], contents[index].entry.messages.first?.isUserPrompt == true {
            ConversationReadingMemory.shared.expansions[sessionId + ":" + id + ":user-prompt"] = true
            invalidateRevealedRow(id)
        }
        if indices[id] == nil, let fold = foldParents[id], indices[fold] != nil {
            // The hit sits inside a folded process group: expand it in place and
            // land on the fold row. The expanded content re-measures on mount.
            let scope = sessionId + ":" + fold
            ConversationReadingMemory.shared.expansions[scope + ":process-fold"] = true
            for name in ["thought", "live-thought", "full-thought", "commentary", "expanded", "full-output"] {
                ConversationReadingMemory.shared.expansions[sessionId + ":" + id + ":" + name] = true
            }
            if let index = indices[fold], let row = contents[index].foldedRows?.first(where: { $0.entry.id == id }) {
                for tool in row.tools.keys {
                    ConversationReadingMemory.shared.expansions[sessionId + ":" + id + ":tool:" + tool + ":expanded"] = true
                    ConversationReadingMemory.shared.expansions[sessionId + ":" + id + ":tool:" + tool + ":full-output"] = true
                }
            }
            invalidateRevealedRow(fold)
            target = fold
        }
        guard let index = indices[target] else { return }
        cancelPendingRestoration()
        ConversationReadingMemory.shared.following[sessionId] = false
        viewport?.pauseFollowing?()
        // A reveal is an explicit destination, not a request to preserve the
        // outgoing visible rows while cold rows above it are being measured.
        restoreTarget = .init(entry: target, index: index, offset: 0)
        clip.scroll(to: NSPoint(x: 0, y: max(0, offsets[index] + contentOriginY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
        refreshVisibleRows(source: .reveal)
        restoreReadingPosition()
        if highlight, let view = controllers[target]?.view {
            let marker = CALayer()
            marker.frame = view.bounds.insetBy(dx: 1, dy: 1)
            marker.cornerRadius = WorkbenchTheme.Radius.card
            marker.cornerCurve = .continuous
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
        for controller in controllers.values { controller.suspendTextReveal() }
    }

    func configure(_ next: [ConversationEntryView], contentIdentity: ConversationContentIdentity, navigation: [ConversationTurnSummary], sessionId: String,
                   appearance: ConversationEntryAppearance, viewport: ConversationViewport?, foldParents: [String: String]? = nil,
                   contentOriginY: CGFloat, waitsForInitialPosition: Bool = false) {
        self.waitsForInitialPosition = waitsForInitialPosition
        if let foldParents { self.foldParents = foldParents }
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("document_configure", since: start) }
        #endif
        let applyProbe = PerfDiagnostics.begin()
        var reconciled = false, restructured = false
        defer {
            PerfDiagnostics.end("snapshot_apply", applyProbe,
                                detail: "rows=\(next.count) reconciled=\(reconciled) restructured=\(restructured)")
        }
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
            reconciled = true
            restructured = structureChanged
        }
        if structureChanged || self.navigation != navigation {
            self.navigation = navigation
            turnRows = navigation.compactMap { indices[$0.id] }
        }
        let wasSuspended = suspended
        suspended = false
        isHidden = preparingInitialViewport
        if wasSuspended { for controller in controllers.values { controller.resumeTextReveal() } }
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
                && $0.isStageNote == $1.isStageNote
        }
        if changedSession || changedAppearance { measuredSizes.removeAll(keepingCapacity: true) }
        if structureChanged {
            // Completing a turn folds several rows at once. Preserve the reading
            // anchor before replacing their geometry, just as for disclosure and
            // width changes. A folded-away row maps to its visible process entry.
            if !changedSession, restoreTarget == nil,
               ConversationReadingMemory.shared.following[sessionId] == false {
                saveReadingPosition()
                restoreTarget = ConversationReadingMemory.shared.positions[sessionId]
                if let target = restoreTarget, !next.contains(where: { $0.entry.id == target.entry }),
                   let parent = foldParents[target.entry],
                   let index = next.firstIndex(where: { $0.entry.id == parent }) {
                    restoreTarget = .init(entry: parent, index: index, offset: 0)
                }
            }
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
        guard index + 1 < contents.count else { return ReplyStyle.entrySpacing }
        let current = contents[index], next = contents[index + 1]
        if next.isStageNote && current.entry.isProcess { return ReplyStyle.progressStageSpacing }
        if current.isStageNote && next.entry.isProcess { return ReplyStyle.progressToolSpacing }
        return current.entry.isProcess && next.entry.isProcess ? ReplyStyle.processEntrySpacing : ReplyStyle.entrySpacing
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
        // A refresh can shrink the body below the clip (a settled turn folds its
        // process rows). AppKit clamps the origin only after a blank display
        // pass; pin the clip into the body now, at the pending restore target
        // when one exists. The frame still lags the content in this window, so
        // elastic overscroll (frame already matches) is left alone.
        let bottom = max(0, totalHeight - visible.height)
        if visible.minY > bottom, abs(bounds.height - totalHeight) >= 1, let clip = observedClip {
            let pinned: CGFloat
            if let target = restoreTarget {
                let row = indices[target.entry] ?? min(target.index, contents.count - 1)
                pinned = max(0, min(offsets[row] + target.offset, bottom))
            } else { pinned = bottom }
            clip.scroll(to: NSPoint(x: 0, y: pinned + contentOriginY))
            enclosingScrollView?.reflectScrolledClipView(clip)
            visible = viewportRect
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
        // Only passes that change the mounted range; same-range scroll steps return above.
        let refreshProbe = PerfDiagnostics.begin()
        var entered = 0, exited = 0, created = 0
        defer {
            PerfDiagnostics.end("transcript_refresh", refreshProbe, detail: "source=\(source.rawValue) "
                + "rows=\(laidOutRange?.count ?? 0) entered=\(entered) exited=\(exited) created=\(created)")
        }
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
                created += 1
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
                entered += 1
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
        let leaving = mounted.subtracting(nextMounted)
        exited = leaving.count
        for id in leaving { controllers[id]?.view.removeFromSuperview() }
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
            let publishProbe = PerfDiagnostics.begin()
            let previous = self.publishedHeight
            defer {
                PerfDiagnostics.end("height_publish", publishProbe,
                                    detail: "rows=\(self.contents.count) delta=\((self.totalHeight - (previous ?? 0)).rounded())")
            }
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
        let restoreProbe = PerfDiagnostics.begin()
        defer { PerfDiagnostics.end("anchor_restore", restoreProbe, detail: "rows=\(contents.count)") }
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
    /// Wheel, trackpad and scrollbar moves flow through this bounds stream, but
    /// so do content growth, restore pins and reveal jumps. Only a recent reader
    /// gesture pages: a clip parked at the top while pages prepend would
    /// otherwise keep loading until the whole history is read. Keyboard and
    /// VoiceOver reach the same page through the top "load earlier" button.
    private func loadEarlierIfNearTop() {
        let visible = viewportRect
        guard observedClip != nil, !suspended, !preparingInitialViewport,
              visible.minY <= max(480, visible.height), let viewport,
              Date().timeIntervalSince(viewport.lastUserScroll) < 1 else { return }
        viewport.nearTop?()
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
    static func disconnectedTools(in root: NSView) -> [String] {
        if let document = root as? ConversationDocumentView { return document.disconnectedTools }
        return root.subviews.flatMap { disconnectedTools(in: $0) }
    }
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
    /// Mark the reader gesture that precedes an approach to the top edge, so a
    /// fixture's programmatic scroll pages the same way a wheel tick does.
    static func markUserScroll(in root: NSView) {
        if let document = root as? ConversationDocumentView { document.markUserScroll(); return }
        for view in root.subviews { markUserScroll(in: view) }
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
    /// Top-level document rows as (id, presentation), in reading order.
    static func rowIdentifiers(in root: NSView) -> [(id: String, presentation: String)] {
        if let document = root as? ConversationDocumentView { return document.rowIdentifiers }
        return root.subviews.flatMap { rowIdentifiers(in: $0) }
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
    /// Hosted rows are separate SwiftUI roots; the app language reaches them only here.
    let locale: Locale
    /// The reader's body size. Reading it here also makes the transcript's body
    /// observe it, so a size change re-renders and re-measures every row.
    let bodySize: CGFloat
    init(_ environment: EnvironmentValues) {
        bodySize = ReplyStyle.bodySize
        colorScheme = environment.colorScheme
        layoutDirection = environment.layoutDirection
        displayScale = environment.displayScale
        dynamicTypeSize = environment.dynamicTypeSize
        reduceMotion = environment.streamingReduceMotionOverride ?? (environment.accessibilityReduceMotion || environment.conversationReduceMotion)
        isEnabled = environment.isEnabled
        actionContext = environment.conversationActionContext
        locale = environment.locale
    }
}

private struct HostedConversationEntry: View {
    let content: ConversationEntryView
    let appearance: ConversationEntryAppearance
    var disclosureChanged: () -> Void = {}
    var sizeChanged: (CGSize) -> Void = { _ in }
    var body: some View {
        content.equatable()
            .environment(\.conversationMemoryKey, content.memoryKey)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
            .environment(\.conversationDisclosureWillChange, disclosureChanged)
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.layoutDirection, appearance.layoutDirection)
            .environment(\.displayScale, appearance.displayScale)
            .environment(\.dynamicTypeSize, appearance.dynamicTypeSize)
            .environment(\.conversationReduceMotion, appearance.reduceMotion)
            .environment(\.streamingReduceMotionOverride, appearance.reduceMotion)
            .environment(\.isEnabled, appearance.isEnabled)
            .environment(\.conversationActionContext, appearance.actionContext)
            .environment(\.locale, appearance.locale)
            // Match Perch's ink and monochrome disclosure/control tint in both appearances.
            .foregroundStyle(WorkbenchTheme.ink)
            .tint(WorkbenchTheme.accent)
    }
}

/// Parse and attributed-string construction are pure functions of the source
/// text and the reading body size, and the built strings use dynamic colors.
/// Recreated hosts reuse the earlier preparation instead of parsing the same
/// history on every revisit. Bounded by entry count and retained source size.
private final class NativeRowPreparationCache {
    private enum Value {
        case user(source: String, size: CGFloat, preparation: NativeParagraphContent.Preparation)
        case assistant(source: String, size: CGFloat, allowsRichBlocks: Bool, preparation: NativeAssistantContent.Preparation)
        var source: String {
            switch self {
            case .user(let source, _, _): return source
            case .assistant(let source, _, _, _): return source
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
        let size = ReplyStyle.bodySize
        if case .user(let cached, let cachedSize, let preparation) = entries[key], cached == source, cachedSize == size {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("row_prepare_cache_hit")
            #endif
            return preparation
        }
        let preparation = prepare()
        store(key, .user(source: source, size: size, preparation: preparation))
        return preparation
    }

    func assistant(session: String, messageID: String, source: String, allowsRichBlocks: Bool,
                   prepare: () -> NativeAssistantContent.Preparation) -> NativeAssistantContent.Preparation {
        let key = Key(session: session, messageID: messageID)
        let size = ReplyStyle.bodySize
        if case .assistant(let cached, let cachedSize, let cachedAllows, let preparation) = entries[key],
           cached == source, cachedSize == size, cachedAllows == allowsRichBlocks {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("row_prepare_cache_hit")
            #endif
            return preparation
        }
        let preparation = prepare()
        store(key, .assistant(source: source, size: size, allowsRichBlocks: allowsRichBlocks, preparation: preparation))
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
    /// The assistant reply's Markdown for "copy as plain text"; nil for other rows.
    private var replySource: String?
    private var content: ConversationEntryView
    private var appearance: ConversationEntryAppearance
    private var generation = 0
    private var textReveal: StreamingReplyState?
    private var revealIdentity: String?
    private var revealTask: Task<Void, Never>?
    private var revealFlushPending = false
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
        updateTextReveal()
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
        #if TRANSCRIPT_CHECKS
        let directUserRoot = ProcessInfo.processInfo.environment["NAVIGATION_DIRECT_USER_ROOT"] != "0"
        #else
        let directUserRoot = true
        #endif
        // Attaching an already populated text subtree to another container makes
        // AppKit invalidate its layout again. Native user rows can own the frame.
        if directUserRoot, let nativeUser {
            nativeUser.identifier = NSUserInterfaceItemIdentifier(content.entry.id)
            nativeUser.wantsLayer = true
            nativeUser.layer?.masksToBounds = true
            nativeUser.widthChanged = { [weak self] in self?.committedWidthChanged() }
            view = nativeUser
            return
        }
        let container = ConversationEntryContainer()
        container.identifier = NSUserInterfaceItemIdentifier(content.entry.id)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.replySourceProvider = { [weak self] in self?.replySource }
        if let nativeUser { container.addSubview(nativeUser) }
        if let nativeAssistant { container.addSubview(nativeAssistant) }
        if let host {
            // The hosting view and its SwiftUI graph are created on first access.
            let createProbe = PerfDiagnostics.begin()
            addChild(host); container.addSubview(host.view)
            PerfDiagnostics.end("hosted_row_create", createProbe, detail: "step=view presentation=\(content.entry.presentation)")
        }
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
            let frameChanged = nativeUser !== view && nativeUser.frame != hostFrame
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
        revealTask?.cancel()
        if let settleFlipObserver { NotificationCenter.default.removeObserver(settleFlipObserver) }
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
        // A settled reply skips equal blocks, so its looked-up labels would keep
        // the previous language. Rebuild it from the pool; user rows re-place.
        if appearance.locale != nextAppearance.locale || appearance.bodySize != nextAppearance.bodySize,
           let nativeAssistant {
            NativeAssistantMessageView.recycle(nativeAssistant)
            self.nativeAssistant = nil
        }
        content = next
        appearance = nextAppearance
        updateTextReveal()
        generation += 1
        publishedHeight = nil
        sizes.removeAll(keepingCapacity: true)
        // The settle edge: a reply that just finished pre-renders its diagrams
        // offscreen so scrolling to them does not wait on the renderer.
        if contentChanged, content.entry.presentation == .progress, next.entry.presentation == .message,
           let source = next.entry.messages.first?.content.first?.text {
            MermaidRenderer.shared.prewarmSources(in: source, dark: nextAppearance.colorScheme == .dark)
        }
        setRoot()
    }

    /// Only one cumulative assistant text is timed here. Native and hosted
    /// shapes share its prefix, so incomplete Markdown can change renderer
    /// without replaying text or adding a second release loop.
    private func updateTextReveal() {
        guard !content.isProgressNote,
              content.entry.presentation == .message || content.entry.presentation == .progress,
              content.entry.messages.count == 1, let message = content.entry.messages.first,
              message.role == "assistant", !message.isCompactionSummary,
              message.content.count == 1, let part = message.content.first,
              part.type == "text", !part.isRuntimeContext, part.skillContextSplit == nil,
              let source = part.text else {
            revealTask?.cancel(); revealTask = nil; textReveal = nil; revealIdentity = nil
            return
        }
        let identity = content.memoryKey + ":" + message.id
        if revealIdentity != identity {
            revealTask?.cancel(); revealTask = nil
            textReveal = StreamingReplyState(source); revealIdentity = identity
        }
        let visible = !isViewLoaded || (view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty)
        textReveal!.update(source, smoothing: content.streamingMessageID == message.id && !appearance.reduceMotion && visible)
        guard textReveal!.hasBacklog else { revealTask?.cancel(); revealTask = nil; return }
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(StreamingTextReveal.frameInterval)) }
                catch { return }
                guard !Task.isCancelled, self?.advanceTextReveal() == true else { return }
            }
        }
    }
    private func advanceTextReveal() -> Bool {
        guard let textReveal else { revealTask = nil; return false }
        guard isViewLoaded, view.window?.isVisible == true, view.window?.isMiniaturized == false,
              !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else {
            textReveal.flush(); revealTask = nil
            // One final flush, with no measurement or ongoing hidden-window
            // clock. Returning to the same mounted row must not leave a prefix.
            setRoot(); sizes.removeAll(keepingCapacity: true)
            return false
        }
        if textReveal.advance() {
            let revealProbe = PerfDiagnostics.begin()
            defer { PerfDiagnostics.end("streaming_text_frame", revealProbe) }
            // Publish this row's real measured height through the existing
            // anchor/follow path, without re-projecting the conversation.
            generation += 1; publishedHeight = nil
            sizes.removeAll(keepingCapacity: true)
            setRoot()
            report(measure(width: view.bounds.width), generation: generation)
        }
        if !textReveal.hasBacklog { revealTask = nil }
        return textReveal.hasBacklog
    }
    func suspendTextReveal() {
        revealTask?.cancel(); revealTask = nil
        if textReveal?.hasBacklog == true {
            // State can settle while the outgoing document is hidden, but its
            // native subtree and saved geometry must remain untouched.
            textReveal?.flush(); revealFlushPending = true
        }
    }
    func resumeTextReveal() {
        guard revealFlushPending else { return }
        revealFlushPending = false
        generation += 1; publishedHeight = nil
        sizes.removeAll(keepingCapacity: true)
        setRoot()
    }
    private func nativeUserPreparation() -> (messageID: String, source: String, value: NativeParagraphContent.Preparation)? {
        #if TRANSCRIPT_CHECKS
        if ProcessInfo.processInfo.environment["NAVIGATION_NATIVE_USER_ROWS"] == "0" { return nil }
        #endif
        guard appearance.layoutDirection == .leftToRight, content.activityNarrative == nil,
              content.entry.presentation == .message, content.entry.messages.count == 1,
              let message = content.entry.messages.first, message.isUserPrompt, message.cronFire == nil,
              message.content.count == 1, let part = message.content.first,
              part.type == "text", !part.isRuntimeContext, part.skillContextSplit == nil else { return nil }
        let source = part.text ?? ""
        if source.contains("@\""), !ProjectFileReference.references(in: source).isEmpty { return nil }
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
        guard appearance.layoutDirection == .leftToRight, !content.isProgressNote,
              content.entry.presentation == .message || content.entry.presentation == .progress,
              content.entry.messages.count == 1,
              let message = content.entry.messages.first, message.role == "assistant", !message.isCompactionSummary,
              message.content.count == 1, let part = message.content.first,
              part.type == "text", !part.isRuntimeContext, part.skillContextSplit == nil,
              let rawSource = part.text else { return nil }
        let source = textReveal?.text ?? rawSource
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

    /// Any descendant text view holding a non-empty selection blocks the
    /// settle flip; the flip retries when that selection clears.
    private static func hasLiveTextSelection(in view: NSView) -> Bool {
        if let text = view as? NSTextView, text.selectedRange().length > 0 { return true }
        return view.subviews.contains(where: { hasLiveTextSelection(in: $0) })
    }

    private var settleFlipObserver: NSObjectProtocol?
    private func deferSettleFlip() {
        guard settleFlipObserver == nil else { return }
        settleFlipObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, let host = self.host,
                      !Self.hasLiveTextSelection(in: host.view) else { return }
                NotificationCenter.default.removeObserver(self.settleFlipObserver as Any)
                self.settleFlipObserver = nil
                self.setRoot()
            }
    }
    private func setRoot() {
        #if TRANSCRIPT_CHECKS
        // Covers native admission probing (parse + attributed construction), native
        // view acquisition and text-storage replacement, and NSHostingController
        // creation for fallback rows. Nested inside host_create/host_view callers.
        let rootStart = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("set_root", since: rootStart) }
        #endif
        let setupProbe = PerfDiagnostics.begin()
        defer { PerfDiagnostics.end("row_setup", setupProbe, detail: rowSetupDetail) }
        placedWidth = nil
        replySource = nil
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
                nativeUser!.expansionKey = content.memoryKey
                nativeUser!.expansionWillChange = { [weak self] in self?.disclosureChanged() }
                nativeUser!.expansionDidChange = { [weak self] in
                    guard let self else { return }
                    self.sizes.removeAll(keepingCapacity: true)
                    self.placedWidth = nil
                    let width = self.view.bounds.width
                    self.nativeUser?.place(width: width)
                    self.report(self.measure(width: width), generation: self.generation)
                }
                nativeUser!.update(paragraphs, dark: appearance.colorScheme == .dark)
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.record("native_user_update", since: CACurrentMediaTime())
                #endif
                return
            }
            markdownPreparation = fallbackPreparation(messageID: user.messageID, source: user.source, blocks: user.value.blocks)
        }
        if let nativeUser {
            if isViewLoaded, view === nativeUser {
                // A same-ID edit may need SwiftUI or the assistant renderer.
                // Replace the row in place before recycling its former root.
                let container = ConversationEntryContainer()
                container.identifier = nativeUser.identifier
                container.frame = nativeUser.frame
                container.wantsLayer = true
                container.layer?.masksToBounds = true
                container.replySourceProvider = { [weak self] in self?.replySource }
                nativeUser.widthChanged = nil
                nativeUser.superview?.replaceSubview(nativeUser, with: container)
                container.widthChanged = { [weak self] in self?.committedWidthChanged() }
                view = container
            }
            NativeUserMessageView.recycle(nativeUser)
            self.nativeUser = nil
        }
        if let assistant = nativeAssistantPreparation() {
            replySource = content.entry.messages.first?.content.first?.text
            if let blocks = assistant.value.content {
                // A hosted fallback may become native after its incomplete Markdown
                // changes shape. Keep an active selection until the user clears it.
                if let host, Self.hasLiveTextSelection(in: host.view) {
                    deferSettleFlip()
                    markdownPreparation = fallbackPreparation(messageID: assistant.messageID, source: assistant.source,
                                                              blocks: assistant.value.blocks)
                } else {
                    if let host { host.view.removeFromSuperview(); host.removeFromParent(); self.host = nil }
                    if nativeAssistant == nil {
                        if NativeAssistantMessageView.makeRecapButton == nil {
                            NativeAssistantMessageView.makeRecapButton = { AnyView(RecapActionButton(key: $0)) }
                        }
                        nativeAssistant = NativeAssistantMessageView.acquire()
                        if isViewLoaded { view.addSubview(nativeAssistant!) }
                    }
                    nativeAssistant!.update(blocks, source: assistant.source,
                                            dark: appearance.colorScheme == .dark, enabled: appearance.isEnabled,
                                            actionContext: appearance.actionContext, messageID: assistant.messageID,
                                            showsActions: content.entry.presentation == .message)
                    #if TRANSCRIPT_CHECKS
                    NavigationRenderMetrics.record("native_assistant_update", since: CACurrentMediaTime())
                    #endif
                    return
                }
            }
            markdownPreparation = fallbackPreparation(messageID: assistant.messageID, source: assistant.source,
                                                       blocks: assistant.value.blocks)
        }
        if let nativeAssistant {
            NativeAssistantMessageView.recycle(nativeAssistant)
            self.nativeAssistant = nil
        }
        var hostedContent = content
        hostedContent.markdownPreparation = markdownPreparation
        hostedContent.displayTextOverride = textReveal?.text
        let version = generation
        let root = HostedConversationEntry(content: hostedContent, appearance: appearance, disclosureChanged: { [weak self] in
            self?.sizes.removeAll(keepingCapacity: true)
            self?.disclosureChanged()
        }) { [weak self] size in
            self?.contentSizeChanged(size, generation: version)
        }
        if let host { host.rootView = root }
        else {
            let createProbe = PerfDiagnostics.begin()
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            host.safeAreaRegions = []
            self.host = host
            if isViewLoaded { addChild(host); view.addSubview(host.view) }
            PerfDiagnostics.end("hosted_row_create", createProbe,
                                detail: "step=controller presentation=\(content.entry.presentation)")
        }
    }
    /// Diagnostics details: renderer and block kinds and counts, never message text.
    private var perfRenderer: String {
        if nativeUser != nil { return "renderer=native_user" }
        if nativeAssistant != nil { return "renderer=native_assistant" }
        return "renderer=hosted presentation=\(content.entry.presentation)"
    }
    /// A hosted row adds why: a held text selection, or the top-level block
    /// kinds of a reply the native renderers declined.
    private var rowSetupDetail: String {
        guard nativeUser == nil, nativeAssistant == nil else { return perfRenderer }
        var detail = perfRenderer
        if settleFlipObserver != nil { detail += " reason=selection" }
        if case .reuse(_, _, _, let blocks)? = host?.rootView.content.markdownPreparation {
            detail += " blocks=" + Self.blockKinds(blocks)
        }
        return detail
    }
    private static func blockKinds(_ blocks: [ReplyBlock]) -> String {
        Set(blocks.map { block -> String in
            switch block {
            case .paragraph: return "paragraph"
            case .heading: return "heading"
            case .code(let language, _): return MermaidSupport.isMermaid(language) ? "mermaid" : "code"
            case .math: return "math"
            case .list: return "list"
            case .quote: return "quote"
            case .table: return "table"
            case .alert: return "alert"
            case .rule: return "rule"
            }
        }).sorted().joined(separator: ",")
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
            let measureProbe = PerfDiagnostics.begin()
            defer { PerfDiagnostics.end("row_measure", measureProbe, detail: perfRenderer) }
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
                    Image(systemName: "quote.opening").font(.system(size: ReplyStyle.captionSize))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("引用到输入框")
                    .accessibilityLabel("引用到输入框")
                if !messageID.isEmpty {
                    Button { context.post(.regenerate(before: messageID)) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: ReplyStyle.captionSize))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("重新生成（重发上一条提问）")
                        .accessibilityLabel("重新生成")
                    if let recapKey = context.recapKey, context.recapMessageID == messageID {
                        RecapActionButton(key: recapKey)
                    }
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
    /// Last reader-driven scroll; separates approach-to-top paging from clip
    /// moves caused by content growth or position restoration.
    private(set) var lastUserScroll = Date.distantPast
    let navigator = ConversationTurnNavigation()
    private let rows = NSHashTable<NSView>.weakObjects()
    private var scheduled = false
    fileprivate func add(_ row: NSView) { rows.add(row); refresh() }
    fileprivate func remove(_ row: NSView) { rows.remove(row); refresh() }
    func userScrolled() {
        lastUserScroll = Date()
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
private final class ConversationEntryContainer: NSView, ReplySelectionScope {
    override var isFlipped: Bool { true }
    var widthChanged: (() -> Void)?
    /// The row's assistant Markdown, read when its context menu opens.
    var replySourceProvider: (() -> String?)?
    var replySource: String? { replySourceProvider?() }
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
    /// Rows collapsed behind this fold; non-nil only for process-fold entries.
    var foldedRows: [ConversationPresentationModel.Row]? = nil
    var isLive = false
    var preservesExpandedProcess = false
    var liveThinkingSummary: String? = nil
    /// Active plan progress for the live stage header in a running turn.
    var planProgress: TurnStatus.Progress? = nil
    /// Static duration of a settled turn for its process fold header (>= 5s).
    var completedDuration: TimeInterval? = nil
    /// The running turn's process fold: auto-opens and settles in place (PI).
    var liveProcessFold = false
    /// Live turn start for the fold header's ticking duration (PI).
    var liveStartedAt: Date? = nil
    var streamingMessageID: String? = nil
    var displayTextOverride: String? = nil
    @RememberedExpansion("commentary", initial: true) private var commentaryExpanded
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.tools == rhs.tools && lhs.api === rhs.api
            && lhs.sessionId == rhs.sessionId && lhs.memoryKey == rhs.memoryKey
            && lhs.activityNarrative == rhs.activityNarrative
            && lhs.markdownPreparation == rhs.markdownPreparation
            && lhs.foldedRows == rhs.foldedRows
            && lhs.isLive == rhs.isLive
            && lhs.preservesExpandedProcess == rhs.preservesExpandedProcess
            && lhs.liveThinkingSummary == rhs.liveThinkingSummary
            && lhs.planProgress == rhs.planProgress
            && lhs.completedDuration == rhs.completedDuration
            && lhs.liveProcessFold == rhs.liveProcessFold
            && lhs.liveStartedAt == rhs.liveStartedAt
            && lhs.streamingMessageID == rhs.streamingMessageID
            && lhs.displayTextOverride == rhs.displayTextOverride
    }
    /// Ordinary provider progress prose needs the same rhythm as narrative anchors.
    var isStageNote: Bool { isProgressNote || entry.presentation == .progress }
    var isProgressNote: Bool {
        guard let activityNarrative else { return false }
        return activityNarrative.isAnchor && activityNarrative.stageClosed
            && entry.isNarrativeSource(for: activityNarrative.narrative)
    }
    var body: some View {
        // The native assistant row places its actions with the same gap.
        VStack(alignment: .leading, spacing: ReplyStyle.entryPartSpacing) {
            if isProgressNote, let activityNarrative {
                ActivityNarrativeHistoryView(narrative: activityNarrative.narrative,
                                             sourceText: entry.narrativeSourceText(for: activityNarrative.narrative))
            } else {
                switch entry.presentation {
                case .activity:
                    KimiActivityView(entry: entry, tools: tools, api: api, sessionId: sessionId,
                                     narrative: activityNarrative.flatMap {
                                         $0.isAnchor ? $0.narrative : nil
                                     }, isLive: isLive, liveThinkingSummary: liveThinkingSummary, planProgress: planProgress)
                case .commentary:
                    DisclosureGroup("此前的进度说明 · \(entry.messages.count) 条", isExpanded: $commentaryExpanded) {
                        if commentaryExpanded { VStack(alignment: .leading, spacing: ReplyStyle.entryPartSpacing) {
                            ForEach(entry.messages) { message in
                                KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId,
                                                markdownPreparation: markdownPreparation)
                            }
                        }.padding(.top, 10).padding(.leading, ReplyStyle.Process.nestedIndent) }
                    }.disclosureGroupStyle(ProcessDisclosureStyle())
                        .font(.system(size: ReplyStyle.Process.labelSize)).foregroundStyle(.secondary)
                case .thinkingDetails, .thinkingPreview, .thinkingRecord:
                    ThoughtOutput(messages: entry.messages, finished: entry.presentation != .thinkingPreview)
                case .emptyOutput:
                    Text("本轮未返回文字回复，可展开工具记录查看结果。")
                        .font(.system(size: ReplyStyle.labelSize)).foregroundStyle(.secondary)
                case .processFold:
                    if let foldedRows {
                        ProcessFoldRow(rows: foldedRows, api: api, sessionId: sessionId,
                                       completedDuration: completedDuration,
                                       sourceMemoryPrefix: String(memoryKey.dropLast(entry.id.count + 1)),
                                       live: liveProcessFold, liveStartedAt: liveStartedAt,
                                       streamingMessageID: streamingMessageID)
                    }
                default:
                    if entry.presentation == .record {
                        Text("过程记录 · 未返回最终回复").font(.system(size: ReplyStyle.captionSize)).foregroundStyle(.secondary)
                    }
                    ForEach(entry.messages) { message in
                        KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId,
                                        markdownPreparation: markdownPreparation,
                                        streaming: streamingMessageID == message.id,
                                        displayTextOverride: displayTextOverride, entryID: entry.id)
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
        .environment(\.conversationProcessEntry, memoryKey)
        .environment(\.conversationPreservesProcess, preservesExpandedProcess && entry.presentation != .processFold)
    }
}

/// Bounds the native text search to one mounted stage or tool record.
struct ProcessFindAnchor: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("process-entry:" + id)
    }
}

struct ProcessFoldRow: View {
    let rows: [ConversationPresentationModel.Row]
    let api: KimiAPI?
    let sessionId: String
    var completedDuration: TimeInterval? = nil
    var sourceMemoryPrefix: String? = nil
    /// Untouched processes open while running and close on completion.
    /// An explicit user choice remains authoritative for this turn.
    var live = false
    /// Live turn start, so the header's duration ticks while it runs (PI).
    var liveStartedAt: Date? = nil
    var streamingMessageID: String? = nil
    @UILocalization private var L
    @Environment(\.locale) private var locale
    @Environment(\.conversationMemoryKey) private var memoryKey
    @Environment(\.conversationActionContext) private var actionContext

    init(rows: [ConversationPresentationModel.Row], api: KimiAPI?, sessionId: String,
         completedDuration: TimeInterval? = nil, sourceMemoryPrefix: String? = nil,
         live: Bool = false, liveStartedAt: Date? = nil, streamingMessageID: String? = nil) {
        self.rows = rows; self.api = api; self.sessionId = sessionId
        self.completedDuration = completedDuration; self.sourceMemoryPrefix = sourceMemoryPrefix
        self.live = live; self.liveStartedAt = liveStartedAt
        self.streamingMessageID = streamingMessageID
        _expanded = RememberedExpansion("process-fold", initial: live)
    }
    @RememberedExpansion("process-fold") private var expanded
    @Environment(\.conversationDisclosureWillChange) private var disclosureWillChange
    private var toolCalls: Int {
        rows.reduce(0) { $0 + $1.entry.messages.flatMap(\.content).filter { $0.type == "tool_use" }.count }
    }
    /// First line of the folded thinking, DSH's completed-reasoning summary.
    /// A provider-declared public summary wins; raw reasoning is only the
    /// fallback, matching the collapsed thought header.
    private var thinkingSummary: String? {
        let parts = rows.flatMap { $0.entry.messages }.flatMap(\.content).filter { $0.thinking != nil }
        for part in parts {
            if let summary = ConversationThinkingSummary.publicSummary(of: part) { return summary }
        }
        for part in parts {
            if let thinking = part.thinking, let line = ThoughtTextStyle.firstSummaryLine(thinking) { return line }
        }
        return nil
    }
    /// Line churn from the folded rows' own edit-class tool calls (session-sourced,
    /// not git): nil when nothing resolved a file, so the header stays quiet.
    private var editStat: (files: Int, additions: Int, deletions: Int)? {
        SessionEditStats.derive(from: rows.flatMap(\.entry.messages)).map {
            (files: $0.perFile.count, additions: $0.total.additions, deletions: $0.total.deletions)
        }
    }
    private var externalHeadline: String? {
        rows.lazy.compactMap { $0.activity?.narrative }.last { $0.source == .external && !$0.headline.isEmpty }?.headline
    }
    /// Live wording follows PI: a streaming thought at the tail reads as
    /// "thinking", anything else as the plain running status.
    private var liveLabel: String {
        if rows.last?.entry.presentation == .thinkingPreview { return L("思考中") }
        return L("Process running")
    }
    var body: some View {
        let countLabel = toolCalls > 0 ? L("\(toolCalls) 个工具") : L("\(rows.count) 条记录")
        let headline = expanded ? nil : externalHeadline
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    HStack(spacing: 6) {
                        // PI's process disclosure: one sparkles glyph for every
                        // state, then status, a live pulse dot, duration and the
                        // tool count; the thinking summary rides last (DSH's
                        // completed reasoning row).
                        Image(systemName: "sparkles").font(.system(size: ReplyStyle.captionSize))
                            .foregroundStyle(WorkbenchTheme.quiet).fixedSize()
                        Text(verbatim: live ? liveLabel : L("运行完成")).fixedSize()
                        ProcessStatusDot(status: live ? .running : .succeeded)
                        if live, let liveStartedAt {
                            let isZh = locale.language.languageCode?.identifier.hasPrefix("zh") ?? true
                            TimelineView(.periodic(from: liveStartedAt, by: 1)) { context in
                                Text(verbatim: "· " + ConversationTiming.duration(
                                    max(0, context.date.timeIntervalSince(liveStartedAt)).rounded(), chinese: isZh))
                                    .monospacedDigit()
                            }.fixedSize()
                        } else if !live, let completedDuration, completedDuration >= 5 {
                            let isZh = locale.language.languageCode?.identifier.hasPrefix("zh") ?? true
                            Text(verbatim: "· " + ConversationTiming.duration(completedDuration, chinese: isZh))
                                .monospacedDigit().fixedSize()
                        }
                        Text(verbatim: "· " + countLabel).fixedSize()
                        if let editStat, actionContext == nil {
                            Text(L("· \(editStat.files) 个文件 +\(editStat.additions) −\(editStat.deletions)"))
                                .monospacedDigit().fixedSize()
                        }
                        if !expanded, headline == nil, let summary = thinkingSummary {
                            Text(verbatim: "· " + summary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                        }
                    }
                    .font(.system(size: headline != nil ? ReplyStyle.captionSize : ReplyStyle.Process.labelSize))
                    .foregroundStyle(headline != nil ? WorkbenchTheme.quiet : Color.secondary)
                }
                .disclosureGroupStyle(ProcessDisclosureStyle(caretFollowsContent: true))
                .accessibilityValue(Text(expanded ? "已展开" : "已收起"))
                .accessibilityIdentifier("completed-process:" + rows[0].entry.id)
                if let editStat, let actionContext {
                    Button { actionContext.post(.showChanges) } label: {
                        editStatBadge(editStat)
                    }.buttonStyle(WorkbenchDisclosureButtonStyle())
                        .fixedSize()
                        .help(Text("查看改动：本轮改了 \(editStat.files) 个文件"))
                        .accessibilityLabel(Text("查看改动"))
                        .accessibilityValue(Text(verbatim: L("本轮改了 \(editStat.files) 个文件") + " +\(editStat.additions) −\(editStat.deletions)"))
                }
            }
            if let externalHeadline = headline {
                Button { expanded.toggle() } label: {
                    Text(verbatim: externalHeadline)
                        .font(.system(size: ReplyStyle.Process.labelSize))
                        .foregroundStyle(Color.primary.opacity(0.76))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: externalHeadline))
                .padding(.leading, ReplyStyle.Process.nestedIndent)
                .padding(.bottom, 2)
            }
            WorkbenchDisclosureContent(expanded: expanded) {
                VStack(alignment: .leading, spacing: ReplyStyle.Process.rowSpacing) {
                    ForEach(rows, id: \.entry.id) { row in
                        foldedRowView(row)
                    }
                }.padding(.top, ReplyStyle.Process.rowSpacing).padding(.leading, ReplyStyle.Process.nestedIndent)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.primary.opacity(0.12)).frame(width: 1).padding(.top, ReplyStyle.Process.rowSpacing)
                    }
            }
        }
    }
    /// Only the tail child is live; earlier stages in the same turn have settled.
    private func foldedRowView(_ row: ConversationPresentationModel.Row) -> some View {
        return ConversationEntryView(entry: row.entry, tools: row.tools, api: api, sessionId: sessionId,
                                     memoryKey: (sourceMemoryPrefix ?? sessionId) + ":" + row.entry.id, activityNarrative: row.activity,
                                     isLive: live && row.entry.id == rows.last?.entry.id,
                                     preservesExpandedProcess: true, streamingMessageID: streamingMessageID)
            .environment(\.conversationMemoryKey, (sourceMemoryPrefix ?? sessionId) + ":" + row.entry.id)
            .environment(\.isConversationBodyText, true)
            .background(ProcessFindAnchor(id: row.entry.id))
    }
    private func editStatBadge(_ editStat: (files: Int, additions: Int, deletions: Int)) -> some View {
        HStack(spacing: 5) {
            Text(L("\(editStat.files) 个文件")).foregroundStyle(WorkbenchTheme.quiet)
            EditStatText(stat: SessionEditStat(additions: editStat.additions, deletions: editStat.deletions))
        }
        .font(.system(size: ReplyStyle.captionSize))
        .padding(.horizontal, 4)
        .frame(height: 22)
        .contentShape(Rectangle())
    }
}

@MainActor enum ConversationProcessClock {
    static func lastActivityOfLatestTurn(_ rows: [ConversationPresentationModel.Row]) -> String? {
        let prompt = rows.lastIndex { $0.entry.presentation == .message && $0.entry.messages.first?.isUserPrompt == true }
        let start = prompt.map { $0 + 1 } ?? 0
        guard start < rows.count else { return nil }
        guard let last = rows.last else { return nil }
        // The live disclosure wraps the turn's process: the live activity is its
        // last activity child.
        if last.entry.presentation == .processFold, let children = last.foldedRows {
            return children.last { $0.entry.presentation == .activity }?.entry.id
        }
        guard last.entry.presentation == .activity else { return nil }
        return last.entry.id
    }
    static func lastFoldOfLatestTurn(_ rows: [ConversationPresentationModel.Row]) -> String? {
        let prompt = rows.lastIndex { $0.entry.presentation == .message && $0.entry.messages.first?.isUserPrompt == true }
        let start = prompt.map { $0 + 1 } ?? 0
        guard start < rows.count else { return nil }
        return rows[start...].last { $0.entry.presentation == .processFold }?.entry.id
    }
}

/// Live and historical thoughts share one TextKit style, with inline code,
/// emphasis, compact paragraph spacing and a leading reasoning rail.
private enum ThoughtTextStyle {
    /// Built at the current reading size; cheap enough to rebuild per view update.
    static var attributes: [NSAttributedString.Key: Any] {
        make(size: ReplyStyle.Process.thoughtSize, lineHeight: ReplyStyle.Process.thoughtLineHeight, ink: WorkbenchTheme.quietNS)
    }
    private static let codeTint = NSColor(name: nil) { appearance in
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.withAlphaComponent(0.055) }
        return color
    }
    private static let emphasisInk = NSColor(name: nil) { appearance in
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.withAlphaComponent(0.78) }
        return color
    }
    private static func paragraphStyle(lineHeight: CGFloat, spacing: CGFloat = ReplyStyle.compactParagraphSpacing) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.paragraphSpacing = spacing
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }
    private static func make(size: CGFloat, lineHeight: CGFloat, ink: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .regular), .foregroundColor: ink,
         .paragraphStyle: paragraphStyle(lineHeight: lineHeight)]
    }
    private static func isCommentSentinel(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") { // l10n-ignore
            let body = trimmed.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
            return body.isEmpty
        }
        return trimmed == "<!--" // l10n-ignore
    }
    /// One cleaned prose line from thinking text: skips blanks, code fences and
    /// comment sentinels, strips heading/list markers and emphasis/backticks.
    private static func cleanedLine(_ rawLine: String, inCodeBlock: inout Bool) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { // l10n-ignore
            inCodeBlock.toggle()
            return nil
        }
        if inCodeBlock || trimmed.isEmpty || isCommentSentinel(trimmed) { return nil }
        var clean = trimmed
        for prefix in ["#### ", "### ", "## ", "# ", "- ", "* "] where clean.hasPrefix(prefix) { // l10n-ignore
            clean = String(clean.dropFirst(prefix.count))
            break
        }
        clean = clean.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "..." || clean == "…" ? nil : clean
    }
    /// Latest meaningful prose line for collapsed thought headers (ZCode / Oh My Pi style).
    static func latestSummaryLine(_ source: String) -> String? {
        guard !source.isEmpty else { return nil }
        var inCodeBlock = false
        var latest: String?
        for rawLine in source.components(separatedBy: "\n") {
            if let clean = cleanedLine(rawLine, inCodeBlock: &inCodeBlock) { latest = clean }
        }
        return latest
    }
    /// First meaningful prose line — the completed fold header's summary, DSH-style.
    static func firstSummaryLine(_ source: String) -> String? {
        guard !source.isEmpty else { return nil }
        var inCodeBlock = false
        for rawLine in source.components(separatedBy: "\n") {
            if let clean = cleanedLine(rawLine, inCodeBlock: &inCodeBlock) { return clean }
        }
        return nil
    }
    static func attributed(_ source: String) -> NSAttributedString {
        guard !source.isEmpty else { return NSAttributedString(string: "", attributes: attributes) }
        if !source.contains("`") && !source.contains("*") && !source.contains("#")
            && !source.contains("<!--") && !source.contains("\n\n")
            && !source.hasPrefix("- ") && !source.contains("\n- ") && !source.contains("\n* ") {
            return NSAttributedString(string: source, attributes: attributes)
        }
        let size = ReplyStyle.Process.thoughtSize
        let lineHeight = ReplyStyle.Process.thoughtLineHeight
        let ink = WorkbenchTheme.quietNS
        let regularFont = NSFont.systemFont(ofSize: size, weight: .regular)
        let boldFont = NSFont.systemFont(ofSize: size, weight: .medium)
        let codeFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let tightParagraph = paragraphStyle(lineHeight: lineHeight, spacing: 2)
        let separatedParagraph = paragraphStyle(lineHeight: lineHeight, spacing: ReplyStyle.compactParagraphSpacing)
        let result = NSMutableAttributedString()
        var lastLineRange: NSRange?
        var inCodeBlock = false
        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { // l10n-ignore
                inCodeBlock.toggle()
                continue
            }
            if !inCodeBlock && isCommentSentinel(trimmed) { continue }
            if trimmed.isEmpty {
                if !inCodeBlock, let range = lastLineRange {
                    result.addAttribute(.paragraphStyle, value: separatedParagraph, range: range)
                }
                continue
            }
            if result.length > 0 {
                var newlineAttributes = result.attributes(at: result.length - 1, effectiveRange: nil)
                newlineAttributes.removeValue(forKey: .backgroundColor)
                newlineAttributes.removeValue(forKey: .replyChip)
                result.append(NSAttributedString(string: "\n", attributes: newlineAttributes))
            }
            let start = result.length
            if inCodeBlock {
                result.append(NSAttributedString(string: rawLine, attributes: [
                    .font: codeFont, .foregroundColor: emphasisInk, .paragraphStyle: tightParagraph
                ]))
            } else {
                var line = rawLine
                var isHeading = false
                for prefix in ["#### ", "### ", "## ", "# "] where trimmed.hasPrefix(prefix) { // l10n-ignore
                    line = String(trimmed.dropFirst(prefix.count))
                    isHeading = true
                    break
                }
                if !isHeading {
                    if let marker = line.range(of: #"^(\s*)[-*]\s+"#, options: .regularExpression) {
                        let indent = String(line[..<marker.upperBound].prefix { $0 == " " || $0 == "\t" })
                        line.replaceSubrange(marker, with: indent + "• ")
                    }
                }
                appendInline(line, into: result, regularFont: isHeading ? boldFont : regularFont,
                             boldFont: boldFont, codeFont: codeFont,
                             baseInk: isHeading ? emphasisInk : ink, paragraph: tightParagraph)
            }
            lastLineRange = NSRange(location: start, length: result.length - start)
        }
        return result.length > 0 ? result : NSAttributedString(string: source, attributes: attributes)
    }
    private static func appendInline(_ line: String, into result: NSMutableAttributedString,
                                     regularFont: NSFont, boldFont: NSFont, codeFont: NSFont,
                                     baseInk: NSColor, paragraph: NSParagraphStyle) {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: regularFont, .foregroundColor: baseInk, .paragraphStyle: paragraph
        ]
        var index = line.startIndex
        var plainStart = index
        func flushPlain(upTo end: String.Index) {
            guard plainStart < end else { return }
            result.append(NSAttributedString(string: String(line[plainStart..<end]), attributes: baseAttributes))
        }
        while index < line.endIndex {
            if line[index] == "`" {
                let contentStart = line.index(after: index)
                if contentStart < line.endIndex, let close = line[contentStart...].firstIndex(of: "`"), close > contentStart {
                    flushPlain(upTo: index)
                    let codeText = String(line[contentStart..<close])
                    result.append(NSAttributedString(string: codeText, attributes: [
                        .font: codeFont, .foregroundColor: emphasisInk,
                        .replyChip: codeTint, .paragraphStyle: paragraph
                    ]))
                    index = line.index(after: close)
                    plainStart = index
                    continue
                }
            } else if line[index...].hasPrefix("**") {
                let contentStart = line.index(index, offsetBy: 2)
                if contentStart < line.endIndex, let close = line.range(of: "**", range: contentStart..<line.endIndex),
                   close.lowerBound > contentStart {
                    flushPlain(upTo: index)
                    let boldText = String(line[contentStart..<close.lowerBound])
                    result.append(NSAttributedString(string: boldText, attributes: [
                        .font: boldFont, .foregroundColor: emphasisInk, .paragraphStyle: paragraph
                    ]))
                    index = close.upperBound
                    plainStart = index
                    continue
                }
            }
            index = line.index(after: index)
        }
        flushPlain(upTo: line.endIndex)
    }
}

private struct ThoughtRail<Content: View>: View {
    var fadesTail = false
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, ReplyStyle.Process.nestedIndent)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(
                        fadesTail
                            ? AnyShapeStyle(LinearGradient(
                                stops: [
                                    .init(color: Color.primary.opacity(0.14), location: 0),
                                    .init(color: Color.primary.opacity(0.14), location: 0.78),
                                    .init(color: Color.primary.opacity(0.02), location: 1)
                                ],
                                startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color.primary.opacity(0.12))
                    )
                    .frame(width: ReplyStyle.Process.thoughtRailWidth)
                    .padding(.leading, ReplyStyle.Process.thoughtRailLeading)
                    .padding(.vertical, 2)
            }
    }
}

/// Expanded thoughts sit under their toggle's label, like every nested process row.
private struct ThoughtText: View {
    let text: String
    var streaming = false
    var body: some View {
        // Prepare styles only for incoming content. Reveal frames slice this
        // attributed value instead of reparsing the entire thought every tick.
        let attributed = ThoughtTextStyle.attributed(text)
        ThoughtRail {
            SmoothReplyText(source: attributed.string, streaming: streaming) { visible in
                SelectableReplyText(attributed: attributed.attributedSubstring(
                    from: NSRange(location: 0, length: (visible as NSString).length)))
            }
        }
    }
}

private struct ThoughtToggle: View {
    /// A looked-up `Text`, so callers pass `Text("…")` rather than a raw string.
    let title: Text
    var summary: String? = nil
    var status: VisibleTool.Status? = nil
    @Binding var expanded: Bool
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(WorkbenchTheme.quiet).fixedSize()
                title.font(.system(size: ReplyStyle.Process.labelSize)).foregroundStyle(.secondary).fixedSize()
                if let status { ProcessStatusDot(status: status) }
                if !expanded, let summary, !summary.isEmpty {
                    Text(verbatim: "·")
                        .font(.system(size: ReplyStyle.Process.labelSize))
                        .foregroundStyle(WorkbenchTheme.quiet)
                        .fixedSize()
                    Text(verbatim: summary)
                        .font(.system(size: ReplyStyle.secondarySize))
                        .foregroundStyle(WorkbenchTheme.quiet)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }.disclosureGroupStyle(ProcessDisclosureStyle())
    }
}

struct ThoughtDisclosure: View {
    let text: String
    /// A provider-declared public summary wins over the raw rolling line (the
    /// collapsed header never surfaces redacted reasoning).
    var publicSummary: String? = nil
    @UILocalization private var L
    @RememberedExpansion("thought", initial: true) private var expanded
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ThoughtToggle(title: Text(verbatim: L("Thoughts")),
                          summary: expanded ? nil : (publicSummary ?? ThoughtTextStyle.latestSummaryLine(text)),
                          status: .succeeded,
                          expanded: $expanded)
            WorkbenchDisclosureContent(expanded: expanded) { ThoughtText(text: text) }
        }
    }
}

/// One stable disclosure through live and settled thought phases.
struct ThoughtOutput: View {
    @Environment(\.conversationMemoryKey) private var memoryKey
    @UILocalization private var L
    let messages: [KimiMessage]
    let finished: Bool
    var embedded = false
    private var fullText: String { messages.flatMap(\.content).compactMap(\.thinking).joined(separator: "\n\n") }
    @RememberedExpansion("thought", initial: true) private var expanded
    var body: some View {
        VStack(alignment: .leading, spacing: embedded ? 4 : 9) {
                // A collapsed running thought shows the provider's public summary
                // first, else its latest meaningful line beside the title (DSH's
                // streaming summary), so the preview reads without pushing the
                // reply down.
                let publicSummary = messages.flatMap(\.content).compactMap { ConversationThinkingSummary.publicSummary(of: $0) }.first
                if ProcessInfo.processInfo.environment["THOUGHT_DEBUG"] != nil {
                    let _ = print("THOUGHT \(memoryKey) expanded=\(expanded) finished=\(finished) public=\(String(describing: publicSummary)) latest=\(String(describing: ThoughtTextStyle.latestSummaryLine(fullText)))")
                }
                ThoughtToggle(title: Text(verbatim: finished ? L("Thoughts") : L("Thinking")),
                              summary: expanded ? nil : (publicSummary ?? ThoughtTextStyle.latestSummaryLine(fullText)),
                              status: finished ? .succeeded : .running,
                              expanded: $expanded)
                    .accessibilityIdentifier("thought-disclosure:" + memoryKey)
                WorkbenchDisclosureContent(expanded: expanded) {
                    ThoughtText(text: fullText, streaming: !finished)
                }
                if !expanded, !finished, let summary = ConversationThinkingSummary.latest(in: messages) {
                    LiveThinkingSummary(text: summary).padding(.leading, ReplyStyle.Process.nestedIndent)
                }
        }
    }
}

/// The live thought preview retired with the phase-aware transcript (ce591b2):
/// running thoughts surface through the disclosure header's rolling summary and
/// provider-declared summaries, not a second scrolling text surface.

