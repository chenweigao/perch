import AppKit
import SwiftUI
import Observation
import QuartzCore
import UniformTypeIdentifiers
import WorkbenchCore

/// The reading scale. Kimi, OMP, Qoder and the other native agents share it with
/// their composers, and both renderers read every size, line height and gap from
/// here. Admitted Markdown stays in one native row while it streams and settles;
/// unsupported shapes keep the SwiftUI renderer with the same geometry.
///
/// Type sizes and vertical rhythm follow the reader's body size through
/// `ReadingScale`'s DSH-aligned ladder (14 pt on a 24 pt line by default; H1–H3
/// step up through a real ramp, H4+ separate by weight). Horizontal geometry —
/// the 748 pt column, insets — stays fixed at every size.
enum ReplyStyle {
    /// Qoder's measure: about 57 em of 14 pt body in the centered column.
    static let readingWidth: CGFloat = 800
    static let horizontalPadding = WorkbenchTheme.Reading.inset
    static let composerInset: CGFloat = 12
    /// The editor text and transcript share the same centered reading column.
    static let composerWidth: CGFloat = readingWidth + 2 * composerInset
    static let composerPadding = horizontalPadding - composerInset
    static var scale: ReadingScale { WorkbenchTheme.Reading.scale }
    static var bodySize: CGFloat { scale.body }
    static var lineHeight: CGFloat { scale.bodyLine }
    static var lineHeightRatio: CGFloat { lineHeight / bodySize }
    static var paragraphSpacing: CGFloat { scale.spacing(16) }
    /// Between paragraphs inside list items, quotes and alerts.
    static var compactParagraphSpacing: CGFloat { scale.spacing(8) }
    /// Secondary prose one tier below the body: thoughts, quiet notes and tables.
    static var secondarySize: CGFloat { scale.secondary }
    /// Process and tool rows, fold headers, the activity bar and notices.
    static var labelSize: CGFloat { scale.label }
    /// Counts, chips, code labels, row actions and small hints.
    static var captionSize: CGFloat { scale.caption }
    static var codeSize: CGFloat { scale.code }
    /// Code line pitch: the scale's code line height minus the font's natural
    /// height at the default size (6 ≈ 19 − 13).
    static let codeLineSpacing: CGFloat = 6
    /// Between the parts of one transcript entry, and above a reply's actions.
    static let entryPartSpacing: CGFloat = 10
    /// Between transcript entries; consecutive process rows sit closer.
    /// Qoder spaces a fold row and the prose after it a full step apart.
    static let entrySpacing: CGFloat = 16
    /// Below a user prompt, before the reply's first row.
    static let promptSpacing: CGFloat = 20
    static let processEntrySpacing: CGFloat = 4
    static let progressToolSpacing: CGFloat = 4
    static let progressStageSpacing: CGFloat = 28
    static let ink = Color.primary.opacity(0.9)
    /// DSH ladder: H1–H3 step up through a real ramp, H4 and below keep the body
    /// size; weight and spacing separate the levels.
    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return scale.heading1
        case 2: return scale.heading2
        case 3: return scale.heading3
        default: return bodySize
        }
    }
    /// Constant leading per level (H1 30/21, H2 28/19, H3 26/18, H4+ body line).
    static func headingLineHeight(_ level: Int) -> CGFloat {
        switch level {
        case 1: return scale.heading1Line
        case 2: return scale.heading2Line
        case 3: return scale.heading3Line
        default: return lineHeight
        }
    }
    /// H1–H3 bold, H4–H6 semibold (DSH's 700/600 split).
    static func headingWeight(_ level: Int) -> NSFont.Weight {
        level <= 3 ? .bold : .semibold
    }
    /// Space above a heading: 32 pt for H1–H3, 16 pt for H4–H6 (DSH margins).
    static func headingTopSpacing(_ level: Int, compact: Bool) -> CGFloat {
        scale.spacing(compact ? (level <= 3 ? 16 : 8) : (level <= 3 ? 32 : 16))
    }
    /// Reply surface for code/mermaid/tool cards: DSH neutral-bluish-50/900,
    /// a touch lighter and cooler than a flat black wash.
    static let paper = Color(nsColor: WorkbenchTheme.replySurfaceNS)
    // Preserve a dynamic color in cached attributed text. Applying alpha to
    // labelColor once can freeze the system appearance before the light window exists.
    static let nativeInk = NSColor(name: nil) { appearance in
        var ink = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { ink = NSColor.labelColor.withAlphaComponent(0.9) }
        return ink
    }
    /// `ReplyTone.quiet`: compaction notes and runtime context share the reading size,
    /// in secondary ink. Weight still marks headings and strong text.
    static var quietSize: CGFloat { scale.secondary }
    static var quietLineHeight: CGFloat { scale.secondaryLine }
    static let quietInk = WorkbenchTheme.quietNS
    /// Code and tables wider than the column fade out over this trailing width.
    /// No wider than their 12 pt trailing inset (`Code.inset`, table cell padding),
    /// so scrolled to the end no glyph fades.
    static let overflowFadeWidth: CGFloat = 12
    static var tableCellSize: CGFloat { scale.secondary }
    /// Column totals are arithmetic over estimated content widths, so a table
    /// never probes TextKit for widths and cannot feed the transcript layout.
    static var tableGeometry: ReplyTableGeometry { ReplyTableGeometry(fontSize: tableCellSize) }

    /// Block categories that set vertical rhythm. Display math spaces like code.
    enum BlockKind { case paragraph, heading, code, rule, other }
    /// Space above a block, shared by both renderers (DSH margins: 16 pt block
    /// gap, 32 pt around rules, 16 pt under headings). Heading top spacing is
    /// level-aware and applied by the callers, which know the level. Compact
    /// applies inside list items, quotes and alerts.
    static func blockSpacing(before block: BlockKind, after previous: BlockKind?, compact: Bool) -> CGFloat {
        guard let previous else { return 0 }
        if previous == .rule { return scale.spacing(32) }
        if previous == .heading { return scale.spacing(compact ? 8 : 16) }
        if previous == .paragraph && block == .paragraph { return compact ? compactParagraphSpacing : paragraphSpacing }
        switch block {
        case .heading: return scale.spacing(compact ? 16 : 32)
        case .rule: return scale.spacing(32)
        case .code: return scale.spacing(compact ? 8 : 16)
        case .paragraph, .other: return compact ? scale.spacing(4) : paragraphSpacing
        }
    }

    /// Code card chrome; the native card and the SwiftUI card place text identically.
    /// Banner follows DSH: a fixed 11 pt label (not content-scaled), 14 pt side
    /// padding, 6 pt vertical padding (36 pt header), 16 pt text inset.
    enum Code {
        static let cornerRadius: CGFloat = 16
        static let labelSize: CGFloat = 11
        static let copyButtonSize: CGFloat = 24
        static let headerHorizontalPadding: CGFloat = 14
        static let headerVerticalPadding: CGFloat = 6
        static var headerHeight: CGFloat { headerVerticalPadding * 2 + copyButtonSize }
        /// Around the code text, and on its leading side when there is no gutter.
        static let inset: CGFloat = 16
        static let gutterLeading: CGFloat = 10
        static let gutterTrailing: CGFloat = 8
    }
    enum ListLayout {
        static let markerGap: CGFloat = 8
        /// With the 8 pt gap this gives the DSH 18 px indent per list level.
        static let minimumMarkerWidth: CGFloat = 10
        /// DSH lists sit items 6 pt apart, uniformly.
        static let itemSpacing: CGFloat = 6
    }
    /// Quotes and alerts: a 2 pt rule with the text inset after it (text starts
    /// 16 pt from the bar, matching DSH's 2 px bar + 14 px padding).
    enum Quote {
        static let leadingInset: CGFloat = 16
        static let verticalInset: CGFloat = 4
        static let barWidth: CGFloat = 2
        static let barOpacity: Double = 0.28
    }
    /// Section rules: a hairline with 32 pt margins (block spacing), DSH-style.
    enum Rule {
        static let height: CGFloat = 0.5
        static let opacity: Double = 0.12
    }
    /// Table cells and rules; horizontal cell padding lives in `tableGeometry`.
    enum Table {
        static let cellVerticalPadding: CGFloat = 10
        /// Cell text on the table line (22 pt at the default secondary size).
        static var cellLineHeight: CGFloat { ReplyStyle.scale.secondary + 9 }
        /// The rule under the header reads stronger than the rules between rows.
        static let headerRuleOpacity: Double = 0.12
        static let rowRuleOpacity: Double = 0.10
    }
}

/// How prose in a reply reads: the body, or quiet secondary notes (compaction notes, runtime context).
enum ReplyTone: Equatable { case body, quiet }

/// Document metrics are normalized to the shared renderer's `ReplyStyle.bodySize`.
/// The reader's font scale preserves document proportions independently of
/// conversation zoom. The 16 pt reference yields 26/18 pt headings and 28 pt lines.
enum DocumentTypography {
    static var unit: CGFloat { ReplyStyle.bodySize / 16 }
    static func headingSize(_ level: Int) -> CGFloat { (level == 1 ? 26 : level == 2 ? 18 : 16) * unit }
    static func headingLineHeight(_ level: Int) -> CGFloat { headingSize(level) * (level == 1 ? 1.35 : 1.5) }
    static func blockSpacing(before block: ReplyStyle.BlockKind, after previous: ReplyStyle.BlockKind?, compact: Bool) -> CGFloat {
        guard let previous else { return 0 }
        if block == .heading { return compact ? 16 : 28 }
        if previous == .heading { return 10 }
        if block == .rule || previous == .rule { return 24 }
        return compact ? 8 : 16
    }
}
private struct ReplyToneKey: EnvironmentKey { static let defaultValue = ReplyTone.body }
private struct StreamingReduceMotionKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    /// Stream fixtures can pin motion without changing the reader's system
    /// accessibility preference. Ordinary views leave this unset.
    var streamingReduceMotionOverride: Bool? {
        get { self[StreamingReduceMotionKey.self] }
        set { self[StreamingReduceMotionKey.self] = newValue }
    }
    /// `.quiet` sets `ReplyText` (and list markers) at `ReplyStyle.quietSize` on
    /// `quietLineHeight` in `quietInk`. SwiftUI rows only: native rows never admit
    /// quiet content. Set with `.environment(\.replyTone, .quiet)`.
    var replyTone: ReplyTone {
        get { self[ReplyToneKey.self] }
        set { self[ReplyToneKey.self] = newValue }
    }
}

extension ReplyStyle.BlockKind {
    init(_ block: ReplyBlock) {
        switch block {
        case .paragraph: self = .paragraph
        case .heading: self = .heading
        case .code, .math: self = .code
        case .rule: self = .rule
        default: self = .other
        }
    }
}

enum UserMessageStyle {
    /// Nine lines of a folded long prompt; prompts past eleven lines fold.
    /// Bubble text runs one step tighter than the reply body (DSH: 14/22).
    static var lineHeight: CGFloat { ReplyStyle.scale.body + 8 }
    static var collapsedHeight: CGFloat { lineHeight * 9 }
    static var foldThreshold: CGFloat { lineHeight * 11 }
    static let horizontalPadding: CGFloat = 16
    /// A one-line prompt is a 46 pt neutral pill: 22 pt of text plus 12 pt above and below.
    static let verticalPadding: CGFloat = 12
    /// TextKit puts a line's extra leading above its glyphs, so text at the
    /// reading line height sits low in its line box. A bubble raises its text
    /// until capitals and ideographs sit midway between its edges, in whole
    /// points; the bubble's height stays two `verticalPadding`s plus the text.
    static var textLift: CGFloat {
        let font = NSFont.systemFont(ofSize: ReplyStyle.bodySize)
        let natural = ceil(font.ascender - font.descender + font.leading)
        let baseline = ceil(font.ascender) + max(0, lineHeight - natural)
        return min(verticalPadding, max(0, baseline - font.capHeight / 2 - lineHeight / 2).rounded())
    }
    static var topPadding: CGFloat { verticalPadding - textLift }
    static var bottomPadding: CGFloat { verticalPadding + textLift }
    /// Qoder's prompt bubble: a card-radius neutral surface, not a pill.
    static let cornerRadius = WorkbenchTheme.Radius.card
    /// DSH caps the bubble at 0.702 of the column (525/748).
    static let maxWidthRatio: CGFloat = 0.72
    /// A new turn opens with air above its prompt, apart from the previous reply.
    static let topSpacing: CGFloat = 24
    static var paragraphSpacing: CGFloat { ReplyStyle.paragraphSpacing }
    /// The fold toggle under a long prompt, as `LongUserPrompt` sets it: label-size
    /// secondary text on a 24 pt row, 6 pt below the prompt.
    static var toggleFontSize: CGFloat { ReplyStyle.labelSize }
    static let toggleSpacing: CGFloat = 6
    static let toggleHeight: CGFloat = 24
}

enum ReplyParagraphLayout {
    static let enabled: Bool = {
        #if TRANSCRIPT_CHECKS
        return ProcessInfo.processInfo.environment["NAVIGATION_GROUP_PARAGRAPHS"] != "0"
        #else
        return true
        #endif
    }()
}

enum ReplyMarkdownPreparation: Equatable {
    case reuse(sessionID: String, messageID: String, source: String, blocks: [ReplyBlock])
    case reparseRejected(sessionID: String, messageID: String, source: String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.reuse(lhsSession, lhsMessage, lhsSource, _), .reuse(rhsSession, rhsMessage, rhsSource, _)):
            return lhsSession == rhsSession && lhsMessage == rhsMessage && lhsSource == rhsSource
        case let (.reparseRejected(lhsSession, lhsMessage, lhsSource),
                  .reparseRejected(rhsSession, rhsMessage, rhsSource)):
            return lhsSession == rhsSession && lhsMessage == rhsMessage && lhsSource == rhsSource
        default:
            return false
        }
    }
}

/// Each live text surface owns its display prefix. Timed writes are observed by
/// that surface alone; the authoritative transcript and drafts stay unchanged.
@MainActor @Observable final class StreamingReplyState {
    private(set) var text: String
    @ObservationIgnored private var reveal: StreamingTextReveal
    @ObservationIgnored private var lastFrame: TimeInterval = 0
    @ObservationIgnored private weak var frameOwner: NSView?
    @ObservationIgnored private var requestFrame: (() -> Void)?
    var hasBacklog: Bool { reveal.hasBacklog }

    init(_ source: String) { text = source; reveal = StreamingTextReveal(source) }

    func update(_ source: String, smoothing: Bool, receivedAt: TimeInterval? = nil) {
        let wasPending = reveal.hasBacklog
        if reveal.update(source, smoothing: smoothing) { text = reveal.text }
        if !wasPending && reveal.hasBacklog { lastFrame = receivedAt ?? CACurrentMediaTime() }
        requestFrame?()
    }
    @discardableResult func advance() -> Bool {
        let now = CACurrentMediaTime()
        let changed = reveal.advance(elapsed: now - lastFrame)
        lastFrame = now
        if changed { text = reveal.text }
        return changed
    }
    func flush() { if reveal.flush() { text = reveal.text }; requestFrame?() }
    func bindFrames(to owner: NSView, request: @escaping () -> Void) {
        frameOwner = owner; requestFrame = request
    }
    func unbindFrames(from owner: NSView) {
        guard frameOwner === owner else { return }
        frameOwner = nil; requestFrame = nil
    }
}

/// The native equivalent of PI's requestAnimationFrame: one persistent display
/// clock, capped at 60 Hz, which new source snapshots cannot postpone.
@MainActor final class ReplyFrameClock {
    @MainActor private final class Target: NSObject {
        weak var clock: ReplyFrameClock?
        @objc func tick(_ link: CADisplayLink) { clock?.tick(link) }
    }
    private let target = Target()
    private var link: CADisplayLink?
    private weak var screen: NSScreen?
    private var lastTick: CFTimeInterval = 0
    private let frame: () -> Bool

    init(frame: @escaping () -> Bool) { self.frame = frame; target.clock = self }
    func start(screen requested: NSScreen?) {
        guard let screen = requested ?? NSScreen.main ?? NSScreen.screens.first else { return }
        guard link == nil || self.screen !== screen else { return }
        stop()
        let link = screen.displayLink(target: target, selector: #selector(Target.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        self.screen = screen; self.link = link
        lastTick = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
    }
    private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // A little timestamp jitter must not halve a nominal 60 Hz display.
        guard now - lastTick >= StreamingTextReveal.frameInterval - 0.0005 else { return }
        lastTick = now
        if !frame() { stop() }
    }
    func stop() { link?.invalidate(); link = nil; screen = nil; lastTick = 0 }
    deinit { link?.invalidate() }
}

private final class SmoothReplyFrameView: NSView {
    weak var state: StreamingReplyState?
    private lazy var clock = ReplyFrameClock { [weak self] in self?.step() ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    func bind(_ state: StreamingReplyState) {
        if self.state !== state { self.state?.unbindFrames(from: self) }
        self.state = state
        state.bindFrames(to: self) { [weak self] in self?.refresh() }
        refresh()
    }
    private var visible: Bool {
        window?.isVisible == true && window?.isMiniaturized == false
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }
    func refresh() {
        guard state?.hasBacklog == true else { clock.stop(); return }
        clock.start(screen: window?.screen)
    }
    private func step() -> Bool {
        guard let state else { return false }
        guard visible else { state.flush(); return false }
        state.advance()
        return state.hasBacklog
    }
    func stop() { clock.stop(); state?.unbindFrames(from: self) }
}
private struct SmoothReplyFrameAnchor: NSViewRepresentable {
    let state: StreamingReplyState
    func makeNSView(context: Context) -> SmoothReplyFrameView { SmoothReplyFrameView() }
    func updateNSView(_ view: SmoothReplyFrameView, context: Context) { view.bind(state) }
    static func dismantleNSView(_ view: SmoothReplyFrameView, coordinator: ()) { view.stop() }
}

/// Hosted Markdown and expanded thoughts use the same release as native prose.
/// The native anchor owns its display clock; input changes only replace the
/// target, and dismantling the surface stops the clock.
struct SmoothReplyText<Content: View>: View {
    let source: String
    let streaming: Bool
    let content: (String) -> Content
    @State private var state: StreamingReplyState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.conversationReduceMotion) private var conversationReduceMotion
    @Environment(\.streamingReduceMotionOverride) private var motionOverride
    private struct Input: Equatable { let source: String; let smoothing: Bool }

    init(source: String, streaming: Bool, @ViewBuilder content: @escaping (String) -> Content) {
        self.source = source; self.streaming = streaming; self.content = content
        _state = State(initialValue: StreamingReplyState(source))
    }
    var body: some View {
        let reduced = motionOverride ?? (systemReduceMotion || conversationReduceMotion)
        let input = Input(source: source, smoothing: streaming && !reduced)
        content(input.smoothing && source.utf16.starts(with: state.text.utf16) ? state.text : source)
            .background(SmoothReplyFrameAnchor(state: state).allowsHitTesting(false))
            .onChange(of: input, initial: true) { _, next in state.update(next.source, smoothing: next.smoothing) }
            .onDisappear { state.flush() }
    }
}

struct KimiMarkdown: View {
    let text: String
    var sessionID: String? = nil
    var messageID: String? = nil
    var preparation: ReplyMarkdownPreparation? = nil
    var coalescesParagraphs = ReplyParagraphLayout.enabled
    var body: some View {
        ReplyContent(text: text, sessionID: sessionID, messageID: messageID, preparation: preparation,
                     coalescesParagraphs: coalescesParagraphs).equatable()
    }
}

/// Mixed-content hosted replies use the same parsed-block release as native
/// rows. Keep the raw source for copying while only the visible blocks change.
struct SmoothReplyMarkdown: View {
    let source: String
    let streaming: Bool
    let sessionID: String?
    let messageID: String?
    let preparation: ReplyMarkdownPreparation?
    // A reference box so the incremental parser survives body evaluations;
    // updating it is an idempotent cache write, not observable state.
    @State private var parser = ParserBox()

    private final class ParserBox {
        private var value = ReplyStreamParser()
        private var snapshotSource: String?
        private var cachedSnapshot: ReplyStreamSnapshot?
        func blocks(_ source: String) -> [ReplyBlock] { value.update(source) }
        /// Reveal frames re-evaluate the body without a new source; joining the
        /// snapshot text is O(document), so build it only when source changes.
        func snapshot(for source: String, blocks: [ReplyBlock]) -> ReplyStreamSnapshot {
            if let cachedSnapshot, snapshotSource == source {
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.count("stream_snapshot_reused")
                #endif
                return cachedSnapshot
            }
            let built = ReplyStreamSnapshot(blocks: blocks)
            snapshotSource = source
            cachedSnapshot = built
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("stream_snapshot_built")
            #endif
            return built
        }
    }

    private var blocks: [ReplyBlock] {
        if case .reuse(let session, let message, let expected, let blocks)? = preparation,
           session == sessionID, message == messageID, expected == source { return blocks }
        return parser.blocks(source)
    }
    var body: some View {
        if streaming && source.utf16.count <= StreamingTextReveal.maximumLength {
            let snapshot = parser.snapshot(for: source, blocks: blocks)
            SmoothReplyText(source: snapshot.text, streaming: true) { visible in
                ReplyBlocks(blocks: snapshot.prefix(utf16Length: visible.utf16.count))
                    .foregroundStyle(ReplyStyle.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            KimiMarkdown(text: source, sessionID: sessionID, messageID: messageID, preparation: preparation)
        }
    }
}

/// Static history is not reparsed when the surrounding conversation streams updates.
private struct ReplyContent: View, Equatable {
    let text: String
    let sessionID: String?
    let messageID: String?
    let preparation: ReplyMarkdownPreparation?
    let coalescesParagraphs: Bool
    private var blocks: [ReplyBlock] {
        if case .reuse(let expectedSession, let expectedID, let expectedSource, let blocks)? = preparation,
           expectedSession == sessionID, expectedID == messageID, expectedSource == text {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("markdown_parse_reused")
            #endif
            return blocks
        }
        #if TRANSCRIPT_CHECKS
        if case .reparseRejected(let expectedSession, let expectedID, let expectedSource)? = preparation,
           expectedSession == sessionID, expectedID == messageID, expectedSource == text {
            NavigationRenderMetrics.count("markdown_parse_rejected_fallback")
        } else {
            NavigationRenderMetrics.count("markdown_parse_direct")
            if preparation != nil { NavigationRenderMetrics.count("markdown_parse_preparation_mismatch") }
        }
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("markdown_parse", since: start) }
        #endif
        return ReplyDocument.parse(text)
    }
    var body: some View {
        ReplyBlocks(blocks: blocks, coalescesParagraphs: coalescesParagraphs)
            .foregroundStyle(ReplyStyle.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReplyBlocks: View {
    let blocks: [ReplyBlock]
    var compact = false
    var coalescesParagraphs = ReplyParagraphLayout.enabled
    @Environment(\.documentReadingStyle) private var documentReadingStyle
    @Environment(\.documentFontScale) private var documentFontScale
    private struct Group: Identifiable, Equatable {
        let id: Int
        let block: ReplyBlock
        var following: [[ReplyInline]] = []
    }
    // Bound streaming invalidation: only the final group of at most eight
    // paragraphs changes when the tail grows; completed groups remain equal.
    private var groups: [Group] {
        var result: [Group] = []
        for (index, block) in blocks.enumerated() {
            if coalescesParagraphs, case .paragraph(let runs) = block, runs.contains(where: { !$0.text.isEmpty }),
               let last = result.last, last.following.count < 7,
               case .paragraph(let first) = last.block, first.contains(where: { !$0.text.isEmpty }) {
                result[result.count - 1].following.append(runs)
            } else {
                result.append(Group(id: index, block: block))
            }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                GroupContent(group: group, compact: compact, coalescesParagraphs: coalescesParagraphs).equatable()
                    .padding(.top, group.id == 0 ? 0 : spacing(before: group.block, after: blocks[group.id - 1]))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private struct GroupContent: View, Equatable {
        @Environment(\.documentReadingStyle) private var documentReadingStyle
        let group: Group
        let compact: Bool
        let coalescesParagraphs: Bool
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.group == rhs.group && lhs.compact == rhs.compact && lhs.coalescesParagraphs == rhs.coalescesParagraphs
        }
        @ViewBuilder var body: some View {
            if case .paragraph(let runs) = group.block {
                ReplyText(runs: runs, followingParagraphs: group.following,
                          paragraphSpacing: documentReadingStyle ? (compact ? 8 : 16) * DocumentTypography.unit :
                            (compact ? ReplyStyle.compactParagraphSpacing : ReplyStyle.paragraphSpacing),
                          preservesSelectionOnAppend: coalescesParagraphs)
            } else {
                ReplyBlockContent(block: group.block, coalescesParagraphs: coalescesParagraphs).equatable()
            }
        }
    }

    private func spacing(before block: ReplyBlock, after previous: ReplyBlock?) -> CGFloat {
        if documentReadingStyle {
            return DocumentTypography.blockSpacing(before: ReplyStyle.BlockKind(block),
                after: previous.map { ReplyStyle.BlockKind($0) }, compact: compact) * DocumentTypography.unit * documentFontScale
        }
        // A heading's top spacing is level-aware (32 pt H1–H3, 16 pt H4–H6).
        if case .heading(let level, _) = block, previous != nil {
            return ReplyStyle.headingTopSpacing(level, compact: compact)
        }
        return ReplyStyle.blockSpacing(before: ReplyStyle.BlockKind(block),
                                       after: previous.map { ReplyStyle.BlockKind($0) }, compact: compact)
    }

}

private struct ReplyBlockContent: View, Equatable {
    @Environment(\.documentReadingStyle) private var documentReadingStyle
    @Environment(\.documentFontScale) private var documentFontScale
    let block: ReplyBlock
    var coalescesParagraphs = ReplyParagraphLayout.enabled
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block && lhs.coalescesParagraphs == rhs.coalescesParagraphs
    }
    @ViewBuilder var body: some View {
        switch block {
        case .paragraph(let runs): ReplyText(runs: runs)
        case .heading(let level, let runs):
            ReplyText(runs: runs, size: documentReadingStyle ? DocumentTypography.headingSize(level) : ReplyStyle.headingSize(level),
                      weight: documentReadingStyle ? .medium : ReplyStyle.headingWeight(level),
                      lineHeight: documentReadingStyle ? DocumentTypography.headingLineHeight(level) : ReplyStyle.headingLineHeight(level))
        case .code(let language, let source):
            if MermaidSupport.isMermaid(language) {
                ReplyMermaid(source: source)
            } else {
                ReplyCode(language: language, source: source)
            }
        case .math(let latex): ReplyMathBlock(latex: latex)
        case .list(let items):
            let markerWidth = ReplyListMetrics.columnWidth(items.map(\.marker)) * documentFontScale
            ReplyListLayout {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: ReplyStyle.ListLayout.markerGap) {
                        ReplyListMarker(marker: item.marker)
                            .frame(width: markerWidth, alignment: .trailing)
                        // Type erasure breaks the recursive SwiftUI view type, not the document hierarchy.
                        AnyView(ReplyBlocks(blocks: item.blocks, compact: true, coalescesParagraphs: coalescesParagraphs))
                    }
                }
            }
        case .quote(let blocks):
            AnyView(ReplyBlocks(blocks: blocks, compact: true, coalescesParagraphs: coalescesParagraphs))
                .environment(\.documentMutedText, documentReadingStyle)
                .padding(.leading, ReplyStyle.Quote.leadingInset).padding(.vertical, ReplyStyle.Quote.verticalInset)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(ReplyStyle.Quote.barOpacity)).frame(width: ReplyStyle.Quote.barWidth)
                }
        case .alert(let kind, let blocks):
            ReplyAlertBlock(kind: kind, blocks: blocks, coalescesParagraphs: coalescesParagraphs)
        case .table(let headers, let rows, let alignments):
            ReplyTable(headers: headers, rows: rows, alignments: alignments)
        case .rule: Rectangle().fill(.primary.opacity(ReplyStyle.Rule.opacity)).frame(height: ReplyStyle.Rule.height)
        }
    }
}

/// GitHub-style alert (> [!NOTE] …): tinted bar, kind title, compact content.
/// Layout mirrors the quote block so both sit identically in the reading column.
private struct ReplyAlertBlock: View {
    let kind: ReplyAlertKind
    let blocks: [ReplyBlock]
    var coalescesParagraphs = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The bar and icon carry the kind's tint; the title has its own ink.
            Label {
                Text(kind.title).foregroundStyle(kind.titleInk)
            } icon: {
                Image(systemName: kind.symbol).foregroundStyle(kind.tint)
            }.font(.system(size: ReplyStyle.labelSize, weight: .semibold))
            AnyView(ReplyBlocks(blocks: blocks, compact: true, coalescesParagraphs: coalescesParagraphs))
        }
        .padding(.leading, ReplyStyle.Quote.leadingInset).padding(.vertical, ReplyStyle.Quote.verticalInset)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(kind.tint.opacity(0.7)).frame(width: ReplyStyle.Quote.barWidth)
        }
    }
}

/// One right-aligned marker column per list, at least 10 pt wide, shared by the
/// SwiftUI and native renderers. Item text starts at the same x for "9." and
/// "10.", and switching between native admission and SwiftUI fallback keeps the
/// same geometry. Widths are measured with the marker's own label metrics.
@MainActor enum ReplyListMetrics {
    static let minimumMarkerWidth: CGFloat = ReplyStyle.ListLayout.minimumMarkerWidth
    private static let measuringField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: ReplyStyle.bodySize)
        field.alignment = .right
        field.lineBreakMode = .byClipping
        return field
    }()
    /// Markers repeat ("•", "1." …); bounded independently of history length.
    /// Measured at `measuredSize`; a new body size starts over.
    private static var widths: [String: CGFloat] = [:]
    private static var measuredSize: CGFloat = 0
    static func markerWidth(_ marker: String) -> CGFloat {
        let size = ReplyStyle.bodySize
        if size != measuredSize {
            measuredSize = size
            measuringField.font = .systemFont(ofSize: size)
            widths.removeAll(keepingCapacity: true)
        }
        if let width = widths[marker] { return width }
        measuringField.stringValue = marker
        let width = measuringField.fittingSize.width
        if widths.count >= 256 { widths.removeAll(keepingCapacity: true) }
        widths[marker] = width
        return width
    }
    static func columnWidth(_ markers: [String]) -> CGFloat {
        max(minimumMarkerWidth, ceil(markers.map(markerWidth).max() ?? 0))
    }
}

/// Use the same marker metrics as native transcript rows. SwiftUI Text's rounded
/// baseline can otherwise add a pixel to every list item at some font sizes.
/// Quiet prose sets its markers like its text: quiet size, secondary ink.
/// Body markers take the body ink, so each item opens on a solid mark (Qoder).
private struct ReplyListMarker: View {
    let marker: String
    @Environment(\.replyTone) private var tone
    @Environment(\.documentFontScale) private var documentFontScale
    @Environment(\.documentReadingStyle) private var documentReadingStyle
    var body: some View {
        let quiet = tone == .quiet
        let size = (quiet ? ReplyStyle.quietSize : ReplyStyle.bodySize) * documentFontScale
        ReplyListMarkerLabel(marker: marker, size: size, ink: quiet ? ReplyStyle.quietInk : ReplyStyle.nativeInk)
            .fixedSize()
            .alignmentGuide(.firstTextBaseline) { _ in
                let font = NSFont.systemFont(ofSize: size)
                let leading = documentReadingStyle ? max(0, size * 1.75 - ceil(font.ascender - font.descender + font.leading)) : 0
                return ceil(font.ascender) + leading
            }
    }
}

private struct ReplyListMarkerLabel: NSViewRepresentable {
    let marker: String
    let size: CGFloat
    let ink: NSColor
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: marker)
        field.font = .systemFont(ofSize: size)
        field.textColor = ink
        field.alignment = .right
        field.lineBreakMode = .byClipping
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = marker
        if field.font?.pointSize != size { field.font = .systemFont(ofSize: size) }
        if field.textColor !== ink { field.textColor = ink }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize {
        nsView.fittingSize
    }
}

/// Measure wrapped rows at the actual column width without a geometry/state loop.
private struct ReplyListLayout: Layout {
    struct Measurement {
        let width: CGFloat?
        let size: CGSize
        let rows: [CGSize]
        let offsets: [CGFloat]
    }
    func makeCache(subviews: Subviews) -> [Measurement] { [] }
    func updateCache(_ cache: inout [Measurement], subviews: Subviews) { cache.removeAll(keepingCapacity: true) }
    private func measure(width: CGFloat?, subviews: Subviews, cache: inout [Measurement]) -> Measurement {
        // SwiftUI also probes the maximum size with an infinite proposal.
        let columnWidth = width.flatMap { $0.isFinite ? $0 : nil }
        if let measured = cache.first(where: { $0.width == columnWidth }) { return measured }
        let rows = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)) }
        var offsets: [CGFloat] = []
        var height: CGFloat = 0
        for index in rows.indices {
            if index > 0 {
                height += ReplyStyle.ListLayout.itemSpacing
            }
            offsets.append(height)
            height += rows[index].height
        }
        let measured = Measurement(width: columnWidth,
            size: CGSize(width: columnWidth ?? rows.map(\.width).max() ?? 0, height: height), rows: rows, offsets: offsets)
        if cache.count == 4 { cache.removeFirst() }
        cache.append(measured)
        return measured
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [Measurement]) -> CGSize {
        measure(width: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [Measurement]) {
        let measured = measure(width: bounds.width, subviews: subviews, cache: &cache)
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY + measured.offsets[index]),
                                  anchor: .topLeading, proposal: ProposedViewSize(measured.rows[index]))
        }
    }
}

private struct ReplyLineHeightKey: EnvironmentKey {
    static var defaultValue: CGFloat { ReplyStyle.lineHeight }
}
extension EnvironmentValues {
    var replyLineHeight: CGFloat {
        get { self[ReplyLineHeightKey.self] }
        set { self[ReplyLineHeightKey.self] = newValue }
    }
}

extension NSAttributedString.Key {
    /// Glyph-hugging chip fill (inline code, mentions), painted by ReplyTextView
    /// around the run's glyph bounds. Value: the fill NSColor.
    static let replyChip = NSAttributedString.Key("PerchReplyChip")
}

/// Both native user rows and SwiftUI Markdown share exact text attributes.
enum ReplyTextAttributes {
    /// Attributed paragraph text is a pure function of runs and style.
    /// Render-thread only.
    private struct ParagraphsKey: Hashable {
        let paragraphs: [[ReplyInline]]
        let size: CGFloat
        let weight: CGFloat
        let alignment: TextAlignment
        let lineHeight: CGFloat
        let paragraphSpacing: CGFloat
        let ink: ObjectIdentifier
    }
    private static var paragraphsCache: [ParagraphsKey: NSAttributedString] = [:]
    private static var paragraphsCacheOrder: [ParagraphsKey] = []
    private static var paragraphsCacheCharacters = 0

    static func paragraphs(_ paragraphs: [[ReplyInline]], size: CGFloat = ReplyStyle.bodySize,
                           weight: NSFont.Weight = .regular, alignment: TextAlignment = .leading,
                           lineHeight: CGFloat? = nil, paragraphSpacing: CGFloat = ReplyStyle.paragraphSpacing,
                           ink: NSColor = ReplyStyle.nativeInk) -> NSAttributedString {
        // Body text uses the exact scale line height; other sizes keep its ratio.
        let resolvedLineHeight = lineHeight
            ?? (size == ReplyStyle.bodySize ? ReplyStyle.lineHeight : size * ReplyStyle.lineHeightRatio)
        let key = ParagraphsKey(paragraphs: paragraphs, size: size, weight: weight.rawValue,
                                alignment: alignment, lineHeight: resolvedLineHeight,
                                paragraphSpacing: paragraphSpacing, ink: ObjectIdentifier(ink))
        if let cached = paragraphsCache[key] {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("paragraphs_cache_hit")
            #endif
            if let index = paragraphsCacheOrder.firstIndex(of: key) {
                paragraphsCacheOrder.append(paragraphsCacheOrder.remove(at: index))
            }
            return cached
        }
        #if TRANSCRIPT_CHECKS
        NavigationRenderMetrics.count("paragraphs_cache_miss")
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("attributed_text", since: start) }
        #endif
        let perfProbe = PerfDiagnostics.begin()
        defer { PerfDiagnostics.end("attributed_text", perfProbe, detail: "paragraphs=\(paragraphs.count)") }
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = resolvedLineHeight
        // Wrap oversized paths/URLs in TextKit without altering selectable text.
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment == .trailing ? .right : alignment == .center ? .center : .left
        for (index, paragraphRuns) in paragraphs.enumerated() {
            if index > 0 {
                // Space only the paragraph boundary, preserving Markdown hard breaks.
                let previous = (result.string as NSString).paragraphRange(for: NSRange(location: result.length - 1, length: 1))
                let separated = paragraph.mutableCopy() as! NSMutableParagraphStyle
                separated.paragraphSpacing = paragraphSpacing
                result.addAttribute(.paragraphStyle, value: separated, range: previous)
                var separator = result.attributes(at: result.length - 1, effectiveRange: nil)
                separator.removeValue(forKey: .link)
                separator.removeValue(forKey: .replyChip)
                result.append(NSAttributedString(string: "\n", attributes: separator))
            }
            for run in paragraphRuns {
                if let math = run.math {
                    // Inline formula: one attachment char carrying the paragraph style.
                    let attachment = NSMutableAttributedString(attributedString: ReplyMathAttachment.string(latex: math, size: size))
                    attachment.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attachment.length))
                    result.append(attachment)
                    continue
                }
                // Strong text is semibold (DSH base-strong 600); it never lightens a heading.
                let strongWeight: NSFont.Weight = run.strong && weight.rawValue < NSFont.Weight.semibold.rawValue ? .semibold : weight
                // Links read at least medium (DSH anchors are 500).
                let runWeight: NSFont.Weight = run.link != nil && strongWeight.rawValue < NSFont.Weight.medium.rawValue ? .medium : strongWeight
                // Inline code at 0.875 em with a chip fill (DSH inline code);
                // heading code keeps the heading's ramp share via the same ratio.
                // The chip is not a TextKit background: that fills the whole line
                // fragment, leading included. ReplyTextView paints `.replyChip`
                // around the glyph bounds instead.
                var font = run.code ? NSFont.monospacedSystemFont(ofSize: (size * 0.875).rounded(), weight: runWeight)
                                    : NSFont.systemFont(ofSize: size, weight: runWeight)
                if run.emphasis { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: ink, .paragraphStyle: paragraph
                ]
                if run.code { attributes[.replyChip] = WorkbenchTheme.inlineCodeTintNS }
                if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link {
                    // Render layer: only allowlisted schemes become clickable;
                    // everything else stays plain text (SafeLink).
                    if link.scheme == "perch-document" {
                        attributes[.link] = link
                    } else if let reference = ConversationFileReference(text: link.relativeString.removingPercentEncoding ?? link.relativeString)?.url {
                        attributes[.link] = reference
                    } else if SafeLink.allowed(link) {
                        attributes[.link] = link
                    }
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        #if TRANSCRIPT_CHECKS
        // Nested inside attributed_text; reported separately because this scan is
        // the part whose cost grows with paragraph length rather than run count.
        let scanStart = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("file_reference_scan", since: scanStart) }
        #endif
        for (range, reference) in ConversationFileReference.matches(in: result.string) {
            // Inline code is never a file link: the chip owns those glyphs.
            guard result.attribute(.replyChip, at: range.location, effectiveRange: nil) == nil else { continue }
            if result.attribute(.link, at: range.location, effectiveRange: nil) == nil {
                result.addAttribute(.link, value: reference.url, range: range)
            }
        }
        if result.string.contains("@\"") {
            // Opaque like the inline-code chip: an alpha tint over the glass
            // backdrop reads as a border-only bubble.
            let mentionTint = WorkbenchTheme.nsColor(light: (242/255, 242/255, 243/255), dark: (54/255, 54/255, 56/255))
            for ref in ProjectFileReference.references(in: result.string) {
                var comps = URLComponents(); comps.scheme = "perch-file"
                comps.queryItems = [URLQueryItem(name: "path", value: ref.path)]
                if let url = comps.url {
                    result.addAttribute(.link, value: url, range: ref.range)
                }
                result.addAttribute(.replyChip, value: mentionTint, range: ref.range)
                result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: max(11, size - 1), weight: .medium), range: ref.range)
            }
        }
        let characters = result.length
        if characters <= 512_000 {
            while !paragraphsCacheOrder.isEmpty,
                  paragraphsCacheOrder.count >= 96 || paragraphsCacheCharacters + characters > 512_000 {
                let oldest = paragraphsCacheOrder.removeFirst()
                if let evicted = paragraphsCache.removeValue(forKey: oldest) {
                    paragraphsCacheCharacters -= evicted.length
                }
            }
            paragraphsCache[key] = result
            paragraphsCacheOrder.append(key)
            paragraphsCacheCharacters += characters
        }
        return result
    }

    /// Matches `SelectableReplyText(_:font:lineSpacing:)` so native and SwiftUI code
    /// cards measure identical text.
    static func code(_ source: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = ReplyStyle.codeLineSpacing
        return NSAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: ReplyStyle.codeSize, weight: .regular),
            .foregroundColor: ReplyStyle.nativeInk, .paragraphStyle: paragraph
        ])
    }
    /// Gutter numbers share the code font and line spacing so rows align
    /// exactly; only color and alignment differ.
    static func codeGutter(_ lines: Int) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = ReplyStyle.codeLineSpacing; paragraph.alignment = .right
        let numbers = (1...max(1, lines)).map(String.init).joined(separator: "\n")
        return NSAttributedString(string: numbers, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: ReplyStyle.codeSize, weight: .regular),
            .foregroundColor: ReplyStyle.nativeInk.withAlphaComponent(0.32), .paragraphStyle: paragraph
        ])
    }
}

/// A trailing newline ends the last line rather than starting another.
enum CodeLineNumbers {
    static func count(in source: String) -> Int {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).count
        if source.hasSuffix("\n") { lines -= 1 }
        return max(1, lines)
    }
}

private struct ReplyText: View {
    @Environment(\.replyTone) private var tone
    @Environment(\.replyLineHeight) private var defaultLineHeight
    @Environment(\.documentReadingStyle) private var documentReadingStyle
    @Environment(\.documentMutedText) private var documentMutedText
    @Environment(\.documentFontScale) private var documentFontScale
    let runs: [ReplyInline]
    var size: CGFloat = ReplyStyle.bodySize
    var weight: NSFont.Weight = .regular
    var alignment: TextAlignment = .leading
    var lineHeight: CGFloat? = nil
    var followingParagraphs: [[ReplyInline]] = []
    var paragraphSpacing: CGFloat = ReplyStyle.paragraphSpacing
    var preservesSelectionOnAppend = false
    /// Quiet prose sets every run, headings and table cells included, at the quiet
    /// size and line height in secondary ink; weight still marks the hierarchy.
    private var resolvedSize: CGFloat { tone == .quiet ? ReplyStyle.quietSize : size }
    private var resolvedLineHeight: CGFloat {
        tone == .quiet ? ReplyStyle.quietLineHeight : (lineHeight ?? (documentReadingStyle ? size * 1.75 : defaultLineHeight))
    }
    private var ink: NSColor { tone == .quiet || documentMutedText ? ReplyStyle.quietInk : ReplyStyle.nativeInk }
    private var attributed: NSAttributedString {
        ReplyTextAttributes.paragraphs([runs] + followingParagraphs, size: resolvedSize, weight: weight,
                                       alignment: alignment, lineHeight: resolvedLineHeight,
                                       paragraphSpacing: paragraphSpacing, ink: ink)
    }
    var body: some View {
        SelectableReplyText(attributed: attributed, preservesSelectionOnAppend: preservesSelectionOnAppend)
            .alignmentGuide(.firstTextBaseline) { _ in
                let font = NSFont.systemFont(ofSize: resolvedSize * documentFontScale)
                let naturalHeight = ceil(font.ascender - font.descender + font.leading)
                // TextKit adds minimum-line-height leading above the glyph baseline.
                return ceil(font.ascender) + max(0, resolvedLineHeight * documentFontScale - naturalHeight)
            }
            .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }
}

/// TextKit owns selection and line measurement. SwiftUI receives only the measured
/// size, with no SelectionOverlay/font-baseline feedback through its layout graph.
private struct ConversationBodyTextKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isConversationBodyText: Bool {
        get { self[ConversationBodyTextKey.self] }
        set { self[ConversationBodyTextKey.self] = newValue }
    }
}

struct SelectableReplyText: NSViewRepresentable {
    @Environment(\.isConversationBodyText) private var isConversationBodyText
    @Environment(\.documentFontScale) private var documentFontScale
    @Environment(\.documentQuery) private var documentQuery
    @Environment(\.documentOpenLink) private var documentOpenLink
    @Environment(\.documentSelection) private var documentSelection
    let attributed: NSAttributedString
    var preservesSelectionOnAppend = false
    /// Gutter-style rows opt out of selection.
    var selectable = true
    var codeLanguage: String?
    var usesViewportLayout = false
    init(attributed: NSAttributedString, preservesSelectionOnAppend: Bool = false, selectable: Bool = true,
         codeLanguage: String? = nil, usesViewportLayout: Bool = false) {
        self.codeLanguage = codeLanguage
        self.usesViewportLayout = usesViewportLayout
        self.attributed = attributed
        self.preservesSelectionOnAppend = preservesSelectionOnAppend
        self.selectable = selectable
    }
    init(_ text: String, font: NSFont = .monospacedSystemFont(ofSize: ReplyStyle.captionSize, weight: .regular), lineSpacing: CGFloat = 4, selectable: Bool = true) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing
        attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: ReplyStyle.nativeInk, .paragraphStyle: paragraph
        ])
        self.selectable = selectable
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var documentOpenLink: ((URL) -> Bool)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            if documentOpenLink?(url) == true { return true }
            if url.scheme == "perch-file" {
                NotificationCenter.default.post(name: .init("PerchOpenConversationFile"), object: url)
                return true
            }
            // Click layer defense in depth: non-allowlisted schemes are
            // swallowed here even if some path missed the render allowlist.
            return !SafeLink.allowed(url)
        }
    }
    // Dismantled paragraphs hold no message content or delegate. Reuse only after
    // SwiftUI has detached them; cap the pool independently of history length.
    private static var recycled: [ReplyTextView] = []
    #if TRANSCRIPT_CHECKS
    static var recycledCount: Int { recycled.count }
    #endif
    static func dismantleNSView(_ view: ReplyTextView, coordinator: Coordinator) { recycle(view) }
    static func recycle(_ view: ReplyTextView) {
        ReplySelection.shared.forget(view)
        view.delegate = nil
        view.codeHighlighting?.reset()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.update(NSAttributedString(string: ""))
        view.isConversationBodyText = false
        view.extraMenuItems = nil
        view.findHighlight = nil
        if recycled.count < 64 { recycled.append(view) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ReplyTextView { Self.acquire(delegate: context.coordinator, usesViewportLayout: usesViewportLayout) }
    static func acquire(delegate: NSTextViewDelegate, usesViewportLayout: Bool = false) -> ReplyTextView {
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("text_create", since: start) }
        #endif
        // The enclosing conversation owns viewport layout; each short paragraph
        // needs selection and drawing, not another TextKit 2 viewport controller.
        let view: ReplyTextView
        if let index = Self.recycled.firstIndex(where: {
            $0.superview == nil && $0.window == nil && ($0.textLayoutManager != nil) == usesViewportLayout
        }) {
            view = Self.recycled.remove(at: index)
            #if TRANSCRIPT_CHECKS
            precondition(view.string.isEmpty && view.delegate == nil && view.selectedRange().length == 0,
                         "Recycled text view retained outgoing row state")
            NavigationRenderMetrics.record("text_reuse", since: CACurrentMediaTime())
            #endif
        } else {
            view = ReplyTextView(usingTextLayoutManager: usesViewportLayout)
        }
        view.isEditable = false
        view.delegate = delegate
        view.enabledTextCheckingTypes = 0
        // Read-only prose: the spell/grammar checker's dotted underlines read as
        // rendering noise on mixed CJK/Latin agent output.
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.linkTextAttributes = [.foregroundColor: WorkbenchTheme.link]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: ReplyTextView, context: Context) {
        view.isConversationBodyText = isConversationBodyText; view.isSelectable = selectable
        context.coordinator.documentOpenLink = documentOpenLink
        let styled: NSAttributedString
        if documentFontScale != 1 {
            let copy = NSMutableAttributedString(attributedString: attributed)
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
                if let font = attrs[.font] as? NSFont {
                    copy.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * documentFontScale), range: range)
                }
                if let paragraph = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                    paragraph.minimumLineHeight *= documentFontScale; paragraph.maximumLineHeight *= documentFontScale
                    paragraph.lineSpacing *= documentFontScale
                    paragraph.paragraphSpacing *= documentFontScale
                    copy.addAttribute(.paragraphStyle, value: paragraph, range: range)
                }
            }
            styled = copy
        } else { styled = attributed }
        view.update(styled, preservingSelectionOnAppend: preservesSelectionOnAppend, replacingAttributes: documentOpenLink != nil)
        view.extraMenuItems = documentSelection.map { action in { [weak view] in
            guard let view else { return [] }
            let range = view.selectedRange()
            let selected = ReplySelection.shared.text(from: view) ?? ((range.length > 0 && NSMaxRange(range) <= view.string.utf16.count) ? (view.string as NSString).substring(with: range) : "")
            let target = DocumentSelectionAction { action(selected) }
            let item = NSMenuItem(title: L("反馈选中文本…"), action: #selector(DocumentSelectionAction.performSelection(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = target; item.isEnabled = !selected.isEmpty
            return [item]
        } }
        if documentOpenLink != nil {
            view.findHighlight = documentQuery.isEmpty ? nil : (documentQuery, false, false)
            view.applyFindHighlight()
        }
        if let codeLanguage { view.highlightCode(language: codeLanguage, debounce: true) }
        else { view.codeHighlighting?.reset() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReplyTextView, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}

enum NativeParagraphContent {
    struct Preparation {
        let blocks: [ReplyBlock]
        let content: [NSAttributedString]?
    }

    static func make(_ source: String, lineHeight: CGFloat? = nil) -> [NSAttributedString]? {
        prepare(source, lineHeight: lineHeight).content
    }

    static func prepare(_ source: String, lineHeight: CGFloat? = nil) -> Preparation {
        #if TRANSCRIPT_CHECKS
        let parseStart = CACurrentMediaTime()
        let blocks = ReplyDocument.parse(source)
        NavigationRenderMetrics.record("row_parse", since: parseStart)
        NavigationRenderMetrics.count("row_parse_native_user")
        #else
        let blocks = ReplyDocument.parse(source)
        #endif
        let content = build(blocks, lineHeight: lineHeight)
        #if TRANSCRIPT_CHECKS
        if content == nil { NavigationRenderMetrics.count("row_parse_rejected") }
        #endif
        return Preparation(blocks: blocks, content: content)
    }

    private static func build(_ blocks: [ReplyBlock], lineHeight: CGFloat?) -> [NSAttributedString]? {
        var paragraphs: [[ReplyInline]] = []
        for block in blocks {
            guard case .paragraph(let runs) = block, runs.contains(where: { !$0.text.isEmpty }) else { return nil }
            paragraphs.append(runs)
        }
        guard !paragraphs.isEmpty else { return nil }
        return stride(from: 0, to: paragraphs.count, by: 8).map {
            ReplyTextAttributes.paragraphs(Array(paragraphs[$0..<min($0 + 8, paragraphs.count)]), lineHeight: lineHeight)
        }
    }
}

/// Plain-paragraph user messages need text selection and a right-aligned bubble,
/// but no SwiftUI state graph. Complex Markdown/attachments keep their existing row.
private final class UserPromptClipView: NSView { override var isFlipped: Bool { true } }

final class NativeUserMessageView: NSView {
    private static var recycled: [NativeUserMessageView] = []
    private var texts: [ReplyTextView] = []
    private let links = SelectableReplyText.Coordinator()
    private let bubbleBackground = NSView()
    private let promptClip = UserPromptClipView()
    private let expandButton = NSButton()
    /// The toggle title's size when it was last set; the reading size can change.
    private var toggleTitleSize: CGFloat = 0
    var expansionKey: String?
    var expansionWillChange: (() -> Void)?
    var expansionDidChange: (() -> Void)?
    private var expanded: Bool {
        expansionKey.flatMap { ConversationReadingMemory.shared.expansions[$0 + ":user-prompt"] } ?? false
    }
    @objc private func togglePrompt() {
        guard let expansionKey else { return }
        expansionWillChange?()
        ConversationReadingMemory.shared.expansions[expansionKey + ":user-prompt"] = !expanded
        expansionDidChange?()
    }
    /// Row identity for message-level menu actions; set by the hosting controller.
    var actionContext: ConversationActionContext?
    var sourceText = ""
    /// Turn id + reading key for the bookmark menu item.
    var bookmarkTurn: String?
    var bookmarkSession: String?
    override var isFlipped: Bool { true }
    var widthChanged: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = bounds.width
        super.setFrameSize(newSize)
        if bounds.width != previousWidth { widthChanged?() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if TRANSCRIPT_CHECKS
        bubbleBackground.identifier = NSUserInterfaceItemIdentifier("native-user-bubble-background")
        #endif
        bubbleBackground.wantsLayer = true
        bubbleBackground.layer?.cornerRadius = UserMessageStyle.cornerRadius
        bubbleBackground.layer?.cornerCurve = .continuous
        addSubview(bubbleBackground)
        promptClip.wantsLayer = true
        promptClip.layer?.masksToBounds = true
        addSubview(promptClip)
        // LongUserPrompt's plain button: secondary text at the prompt's text inset,
        // no bezel. `place` sets the title in secondary ink.
        expandButton.isBordered = false
        expandButton.alignment = .left
        expandButton.font = .systemFont(ofSize: UserMessageStyle.toggleFontSize)
        expandButton.target = self
        expandButton.action = #selector(togglePrompt)
        expandButton.identifier = NSUserInterfaceItemIdentifier("user-prompt-toggle")
        addSubview(expandButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func content(_ source: String) -> [NSAttributedString]? {
        NativeParagraphContent.make(source, lineHeight: UserMessageStyle.lineHeight)
    }
    static func acquire() -> NativeUserMessageView { recycled.popLast() ?? NativeUserMessageView() }
    static func recycle(_ view: NativeUserMessageView) {
        view.widthChanged = nil
        view.identifier = nil
        view.removeFromSuperview()
        view.actionContext = nil
        view.sourceText = ""
        view.expansionKey = nil
        view.expansionWillChange = nil
        view.expansionDidChange = nil
        view.expandButton.isHidden = true
        view.bookmarkTurn = nil
        view.bookmarkSession = nil
        for text in view.texts { text.setSelectedRange(NSRange(location: 0, length: 0)); text.update(NSAttributedString(string: "")) }
        // A giant prompt must not leave an unbounded number of text containers
        // in the row pool after it is no longer visible.
        while view.texts.count > 8 {
            let text = view.texts.removeLast(); text.removeFromSuperview(); SelectableReplyText.recycle(text)
        }
        if recycled.count < 16 { recycled.append(view) }
    }
    func update(_ content: [NSAttributedString], dark: Bool) {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bubbleBackground.layer?.backgroundColor = WorkbenchTheme.userBubbleNS.cgColor
        }
        while texts.count > content.count {
            let text = texts.removeLast(); text.removeFromSuperview(); SelectableReplyText.recycle(text)
        }
        while texts.count < content.count {
            let text = SelectableReplyText.acquire(delegate: links)
            text.isConversationBodyText = true
            text.extraMenuItems = { [weak self] in
                guard let self, let context = self.actionContext, !self.sourceText.isEmpty else { return [] }
                var items = context.userMenuItems(copyText: self.sourceText, sourceText: self.sourceText)
                if let turn = self.bookmarkTurn, let session = self.bookmarkSession {
                    items += [.separator(), ConversationActionContext.bookmarkMenuItem(turn: turn, session: session)]
                }
                return items
            }
            texts.append(text); promptClip.addSubview(text)
        }
        for (text, value) in zip(texts, content) { text.update(value, preservingSelectionOnAppend: true) }
        needsDisplay = true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let actionContext, !sourceText.isEmpty else { return nil }
        let menu = actionContext.userMenu(copyText: sourceText, sourceText: sourceText)
        if let turn = bookmarkTurn, let session = bookmarkSession {
            menu.addItem(.separator())
            menu.addItem(ConversationActionContext.bookmarkMenuItem(turn: turn, session: session))
        }
        return menu
    }
    private func measurements(width: CGFloat) -> (bubbleWidth: CGFloat, sizes: [CGSize]) {
        let contentPadding = UserMessageStyle.horizontalPadding * 2
        let maxBubble = width * UserMessageStyle.maxWidthRatio
        let ideal = (texts.map { $0.measure(width: nil).width }.max() ?? 0) + contentPadding
        let bubbleWidth = min(ideal, maxBubble)
        return (bubbleWidth, texts.map { $0.measure(width: max(1, bubbleWidth - contentPadding)) })
    }
    func measure(width: CGFloat) -> CGSize {
        let sizes = measurements(width: width).sizes
        let textHeight = sizes.reduce(CGFloat.zero) { $0 + $1.height }
        let gaps = CGFloat(max(0, sizes.count - 1)) * UserMessageStyle.paragraphSpacing
        let natural = textHeight + gaps
        let folds = natural > UserMessageStyle.foldThreshold
        let visible = folds && !expanded ? UserMessageStyle.collapsedHeight : natural
        let toggle = folds ? UserMessageStyle.toggleSpacing + UserMessageStyle.toggleHeight : 0
        return CGSize(width: width, height: UserMessageStyle.topSpacing + UserMessageStyle.verticalPadding * 2 + visible + toggle)
    }
    func place(width: CGFloat) {
        let layout = measurements(width: width)
        let x = width - layout.bubbleWidth
        let natural = layout.sizes.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(0, layout.sizes.count - 1)) * UserMessageStyle.paragraphSpacing
        let folds = natural > UserMessageStyle.foldThreshold
        let visible = folds && !expanded ? UserMessageStyle.collapsedHeight : natural
        promptClip.frame = CGRect(x: x, y: UserMessageStyle.topSpacing + UserMessageStyle.topPadding,
                                  width: layout.bubbleWidth, height: visible)
        expandButton.isHidden = !folds
        if folds {
            let title = L(expanded ? "收起问题" : "展开完整问题")
            if expandButton.title != title || toggleTitleSize != UserMessageStyle.toggleFontSize {
                toggleTitleSize = UserMessageStyle.toggleFontSize
                let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left
                expandButton.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: UserMessageStyle.toggleFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
                ])
                expandButton.setAccessibilityLabel(title)
            }
            // At the text inset, toggleSpacing below the prompt, on the row
            // LongUserPrompt gives its button. It hugs its title like that button,
            // so the bubble's blank corner is no hit target.
            let textWidth = max(1, layout.bubbleWidth - UserMessageStyle.horizontalPadding * 2)
            let titleWidth = expandButton.intrinsicContentSize.width
            expandButton.frame = CGRect(x: x + UserMessageStyle.horizontalPadding,
                                        y: promptClip.frame.maxY + UserMessageStyle.toggleSpacing,
                                        width: titleWidth > 0 ? min(titleWidth, textWidth) : textWidth,
                                        height: UserMessageStyle.toggleHeight)
        }
        var y: CGFloat = 0
        for (text, size) in zip(texts, layout.sizes) {
            let frame = CGRect(x: UserMessageStyle.horizontalPadding, y: y,
                               width: max(1, layout.bubbleWidth - UserMessageStyle.horizontalPadding * 2), height: size.height)
            if text.frame != frame { text.frame = frame }
            y += size.height + UserMessageStyle.paragraphSpacing
        }
        let height = measure(width: width).height - UserMessageStyle.topSpacing
        let next = CGRect(x: x, y: UserMessageStyle.topSpacing, width: layout.bubbleWidth, height: height)
        if bubbleBackground.frame != next { bubbleBackground.frame = next }
    }
}

@MainActor @Observable
private final class NativeAssistantActionsModel {
    struct Configuration: Equatable {
        var source: String?
        var enabled = true
        var context: ConversationActionContext?
        var messageID: String?
    }

    var configuration = Configuration()

    func update(source: String?, enabled: Bool = true,
                context: ConversationActionContext? = nil, messageID: String? = nil) {
        let next = Configuration(source: source, enabled: enabled, context: context, messageID: messageID)
        if configuration != next { configuration = next }
    }
}

private struct NativeAssistantActions: View {
    let model: NativeAssistantActionsModel
    var body: some View {
        let configuration = model.configuration
        HStack(spacing: 2) {
            if let source = configuration.source {
                ReplyCopyButton(text: source).id(source).disabled(!configuration.enabled)
            }
            if let context = configuration.context, let source = configuration.source {
                Button { context.post(.quote(source)) } label: {
                    Image(systemName: "quote.opening").font(.system(size: ReplyStyle.captionSize))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(ReplyActionButtonStyle()).foregroundStyle(WorkbenchTheme.quiet).help("引用到输入框")
                    .accessibilityLabel("引用到输入框")
                if let messageID = configuration.messageID, !messageID.isEmpty {
                    Button { context.post(.regenerate(before: messageID)) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: ReplyStyle.captionSize))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(ReplyActionButtonStyle()).foregroundStyle(WorkbenchTheme.quiet).help("重新生成（重发上一条提问）")
                        .accessibilityLabel("重新生成")
                    if let recapKey = context.recapKey, context.recapMessageID == messageID,
                       let makeRecap = NativeAssistantMessageView.makeRecapButton {
                        makeRecap(recapKey).disabled(!configuration.enabled)
                    }
                }
            }
        }
    }
}

final class NativeAssistantMessageView: NSView {
    @MainActor static var makeRecapButton: ((String) -> AnyView)?
    private static var recycled: [NativeAssistantMessageView] = []
    private let links = SelectableReplyText.Coordinator()
    private let stack: NativeAssistantStackView
    private let actionModel: NativeAssistantActionsModel
    private let actions: NSHostingView<NativeAssistantActions>
    private var showsActions = true
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        let actionModel = NativeAssistantActionsModel()
        self.actionModel = actionModel
        actions = NSHostingView(rootView: NativeAssistantActions(model: actionModel))
        stack = NativeAssistantStackView(compact: false, links: links)
        super.init(frame: frameRect)
        actions.sizingOptions = []
        actions.safeAreaRegions = []
        addSubview(stack)
        addSubview(actions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func acquire() -> NativeAssistantMessageView {
        #if TRANSCRIPT_CHECKS
        NavigationRenderMetrics.record(recycled.isEmpty ? "native_assistant_create" : "native_assistant_reuse", since: CACurrentMediaTime())
        #endif
        return recycled.popLast() ?? NativeAssistantMessageView(frame: .zero)
    }
    static func recycle(_ view: NativeAssistantMessageView) {
        view.removeFromSuperview()
        view.actionModel.update(source: nil)
        view.actions.isHidden = false
        view.showsActions = true
        view.showsRecap = false
        // Block containers are torn down; their text views return to the shared pool
        // cleared of content and selection, so recycled shells hold no conversation data.
        view.stack.teardown()
        if recycled.count < 16 { recycled.append(view) }
    }
    func update(_ blocks: [NativeAssistantBlock], source: String, dark: Bool, enabled: Bool = true,
                actionContext: ConversationActionContext? = nil, messageID: String? = nil,
                showsActions: Bool = true, unchangedPrefix: Int = 0) {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        stack.update(blocks, unchangedPrefix: unchangedPrefix)
        self.showsActions = showsActions
        actions.isHidden = !showsActions
        let source = showsActions ? source : nil
        let actionContext = showsActions ? actionContext : nil
        let messageID = showsActions ? messageID : nil
        actionModel.update(source: source, enabled: enabled, context: actionContext, messageID: messageID)
        // The hosting view hugs its buttons so hit targets never sit in padding.
        actionButtonCount = (source == nil ? 0 : 1) + (actionContext != nil && source != nil ? 1 : 0)
            + (actionContext != nil && messageID?.isEmpty == false ? 1 : 0)
        showsRecap = actionContext?.recapKey != nil && messageID?.isEmpty == false && actionContext?.recapMessageID == messageID
    }
    private var actionButtonCount = 1
    private var showsRecap = false
    private var actionsWidth: CGFloat {
        let base = CGFloat(actionButtonCount) * 24 + CGFloat(max(0, actionButtonCount - 1)) * 2
        return showsRecap ? max(base + 76, ceil(actions.fittingSize.width)) : base
    }
    func measure(width: CGFloat) -> CGSize {
        let actionsHeight = showsActions ? ReplyStyle.entryPartSpacing + 24 : 0
        return CGSize(width: width, height: stack.contentHeight(width: width) + actionsHeight)
    }
    func place(width: CGFloat) {
        let content = stack.contentHeight(width: width)
        let stackFrame = CGRect(x: 0, y: 0, width: width, height: content)
        if stack.frame != stackFrame { stack.frame = stackFrame }
        stack.place(width: width)
        let frame = showsActions
            ? CGRect(x: 0, y: content + ReplyStyle.entryPartSpacing, width: actionsWidth, height: 24)
            : .zero
        if actions.frame != frame { actions.frame = frame }
    }
    #if TRANSCRIPT_CHECKS
    static var poolState: [String: Any] {
        ["rows": recycled.count,
         "cleared": recycled.allSatisfy { view in
             view.actionModel.configuration.source == nil && view.stack.blocks.isEmpty && view.stack.textViews().isEmpty
         }]
    }
    #endif
}

final class ReplyTextView: NSTextView {
    var codeHighlighting: CodeHighlightController?
    func highlightCode(language: String, debounce: Bool = false) {
        if codeHighlighting == nil { codeHighlighting = CodeHighlightController(view: self) }
        codeHighlighting?.update(source: string, language: language, debounce: debounce)
    }
    /// Chips (inline code, mentions) hug their glyphs. TextKit's background
    /// attribute fills the whole line fragment — leading included — which reads
    /// as a floating band on a 24 pt line. Painted under the text; selection and
    /// find highlights still draw above.
    override func draw(_ dirtyRect: NSRect) {
        paintChips()
        super.draw(dirtyRect)
    }
    private func paintChips() {
        guard let storage = textStorage else { return }
        var runs: [(color: NSColor, range: NSRange)] = []
        storage.enumerateAttribute(.replyChip, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let color = value as? NSColor, range.length > 0 { runs.append((color, range)) }
        }
        guard !runs.isEmpty else { return }
        // Asking a TextKit 2 view for layoutManager silently converts it to
        // TextKit 1 and restores synchronous layout of the entire tall thought.
        if let layout = textLayoutManager, let content = layout.textContentManager {
            for run in runs {
                guard let start = content.location(content.documentRange.location, offsetBy: run.range.location),
                      let end = content.location(start, offsetBy: run.range.length),
                      let range = NSTextRange(location: start, end: end),
                      let font = storage.attribute(.font, at: run.range.location, effectiveRange: nil) as? NSFont else { continue }
                layout.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, segment, baseline, _ in
                    let rect = CGRect(x: segment.minX + self.textContainerOrigin.x,
                                      y: segment.minY + baseline - font.ascender + self.textContainerOrigin.y,
                                      width: segment.width, height: font.ascender - font.descender)
                    self.paintChip(rect, color: run.color)
                    return true
                }
            }
            return
        }
        guard let manager = layoutManager, let container = textContainer else { return }
        if ProcessInfo.processInfo.environment["CHIP_TRACE"] != nil {
            let snippet = storage.string.count > 30 ? String(storage.string.prefix(30)) : storage.string
            print("CHIP-PAINT view=\(Unmanaged.passUnretained(self).toOpaque()) runs=\(runs.count) bounds=\(NSStringFromRect(bounds)) text=«\(snippet)»")
        }
        manager.ensureLayout(for: container)
        for run in runs {
            if ProcessInfo.processInfo.environment["CHIP_RED"] != nil { NSColor.red.setFill() } else { run.color.setFill() }
            let glyphs = manager.glyphRange(forCharacterRange: run.range, actualCharacterRange: nil)
            manager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
                let segment = NSIntersectionRange(glyphs, lineGlyphs)
                guard segment.length > 0 else { return }
                // Horizontal: glyph locations, not boundingRect — the latter can
                // extend past the last glyph and swallow following punctuation.
                // location(forGlyphAt:) is line-fragment-relative: the fragment
                // origin must be added back, or a wrapped chip's later segments
                // paint over the first line.
                let horizontal = manager.boundingRect(forGlyphRange: segment, in: container)
                let charIndex = manager.characterIndexForGlyph(at: segment.location)
                guard let runFont = storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont else { return }
                let left = lineRect.origin.x + manager.location(forGlyphAt: segment.location).x
                let right: CGFloat
                if NSMaxRange(segment) < NSMaxRange(lineGlyphs) {
                    right = lineRect.origin.x + manager.location(forGlyphAt: NSMaxRange(segment)).x
                } else {
                    right = horizontal.maxX
                }
                // Vertical: anchor to the run's own baseline. boundingRect's y
                // tracks the line fragment, whose leading sits above the glyphs.
                let glyphOrigin = manager.location(forGlyphAt: segment.location)
                var rect = CGRect(x: left, y: lineRect.origin.y + glyphOrigin.y - runFont.ascender,
                                  width: right - left, height: runFont.ascender - runFont.descender)
                rect.origin.x += self.textContainerInset.width
                rect.origin.y += self.textContainerInset.height
                if ProcessInfo.processInfo.environment["CHIP_DEBUG"] != nil {
                    print("CHIP-DRAW range=\(run.range) rect=\(rect) lineGlyphs=\(lineGlyphs) segment=\(segment)")
                }
                self.paintChip(rect, color: run.color)
            }
        }
    }
    private func paintChip(_ glyphBounds: CGRect, color: NSColor) {
        let rect = backingAlignedRect(glyphBounds.insetBy(dx: -4, dy: -2.5), options: .alignAllEdgesNearest)
        (ProcessInfo.processInfo.environment["CHIP_RED"] != nil ? NSColor.red : color).setFill()
        let radius = min(7, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.5; path.stroke()
    }
    var isConversationBodyText = false
    /// Extra context-menu items (message-level actions) supplied by the row.
    var extraMenuItems: (() -> [NSMenuItem])?
    /// Active find-bar query to highlight across this text. Re-applied after
    /// every content update, since streaming replaces the text storage.
    var findHighlight: (query: String, caseSensitive: Bool, regex: Bool)?
    private var hasFindHighlight = false
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let extra = extraMenuItems?(), !extra.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            extra.forEach { menu.addItem($0) }
        }
        // The whole reply without Markdown syntax, whichever paragraph was clicked.
        if let source = ReplySelection.scope(of: self)?.replySource, !source.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: L("复制整条回复（纯文本）"), action: #selector(CopyTextTarget.perform(_:)), keyEquivalent: "")
            item.target = CopyTextTarget.shared
            item.representedObject = ReplyPlainText.text(from: source)
            menu.addItem(item)
        }
        return menu
    }

    // A selection can span the entry's text views (ReplySelection). AppKit's own
    // tracking still runs the drag; these hooks extend it and read the whole span.
    override func mouseDown(with event: NSEvent) {
        ReplySelection.shared.begin(self, event: event)
        super.mouseDown(with: event)
        ReplySelection.shared.end(self)
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRanges(ReplySelection.shared.track(self, proposed: ranges), affinity: affinity, stillSelecting: flag)
        ReplySelection.shared.selectionChanged(self)
    }
    override func copy(_ sender: Any?) {
        guard let text = ReplySelection.shared.text(from: self) else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        ReplySelection.shared.selectAll(from: self)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        ReplySelection.shared.refreshHighlight()
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        ReplySelection.shared.refreshHighlight()
        return resigned
    }
    /// The find bar's highlight color, kept as one instance so clearing it can
    /// match by identity.
    private static let findHighlightColor = NSColor.systemYellow.withAlphaComponent(0.35)
    /// Clearing removes only ranges painted with the find-highlight instance.
    /// (Inline-code and mention chips ride `.replyChip`, not the background.)
    func applyFindHighlight() {
        guard let storage = textStorage, findHighlight != nil || hasFindHighlight else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        var stale: [NSRange] = []
        storage.enumerateAttribute(.backgroundColor, in: full, options: []) { value, range, _ in
            guard let color = value as? NSColor, color === Self.findHighlightColor else { return }
            stale.append(range)
        }
        for range in stale { storage.removeAttribute(.backgroundColor, range: range) }
        if let highlight = findHighlight, !highlight.query.isEmpty, storage.length > 0 {
            let color = Self.findHighlightColor
            if highlight.regex, let expression = try? NSRegularExpression(
                pattern: highlight.query, options: highlight.caseSensitive ? [] : [.caseInsensitive]) {
                for match in expression.matches(in: storage.string, range: full) {
                    storage.addAttribute(.backgroundColor, value: color, range: match.range)
                }
            } else if !highlight.regex {
                let options: NSString.CompareOptions = highlight.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
                let source = storage.string as NSString
                var search = full
                while search.length > 0 {
                    let found = source.range(of: highlight.query, options: options, range: search)
                    guard found.location != NSNotFound else { break }
                    storage.addAttribute(.backgroundColor, value: color, range: found)
                    search = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
                }
            }
        }
        hasFindHighlight = findHighlight != nil
        storage.endEditing()
    }
    private struct SharedMeasurementKey: Hashable {
        let content: NSAttributedString
        let width: CGFloat
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.content === rhs.content && lhs.width == rhs.width
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(content))
            hasher.combine(width)
        }
    }
    private static let sharedMeasurementLimit = 4096
    private static let sharedMeasurementCharacterLimit = 2_000_000
    #if TRANSCRIPT_CHECKS
    private static let sharedMeasurementEnabled = ProcessInfo.processInfo.environment["NAVIGATION_NATIVE_BODY_INCREMENTAL"] != "0"
    #else
    private static let sharedMeasurementEnabled = true
    #endif
    private static var sharedMeasurements: [SharedMeasurementKey: CGSize] = [:]
    private static var sharedMeasurementOrder = [SharedMeasurementKey?](repeating: nil, count: sharedMeasurementLimit)
    private static var sharedMeasurementCursor = 0
    private static var sharedMeasurementCharacters = 0
    private var measurementContent: NSAttributedString?

    private static func sharedMeasurement(for content: NSAttributedString, width: CGFloat) -> CGSize? {
        sharedMeasurements[SharedMeasurementKey(content: content, width: width)]
    }
    private static func storeSharedMeasurement(_ size: CGSize, for content: NSAttributedString, width: CGFloat) {
        guard content.length <= sharedMeasurementCharacterLimit else { return }
        let key = SharedMeasurementKey(content: content, width: width)
        guard sharedMeasurements[key] == nil else { return }
        while true {
            if sharedMeasurements.count < sharedMeasurementLimit,
               sharedMeasurementCharacters + content.length <= sharedMeasurementCharacterLimit,
               sharedMeasurementOrder[sharedMeasurementCursor] == nil {
                sharedMeasurementOrder[sharedMeasurementCursor] = key
                sharedMeasurements[key] = size
                sharedMeasurementCharacters += content.length
                sharedMeasurementCursor = (sharedMeasurementCursor + 1) % sharedMeasurementLimit
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.count("text_measure_shared_cache_store")
                #endif
                return
            }
            if let oldest = sharedMeasurementOrder[sharedMeasurementCursor] {
                sharedMeasurements.removeValue(forKey: oldest)
                sharedMeasurementCharacters -= oldest.content.length
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.count("text_measure_shared_cache_evict")
                #endif
            }
            sharedMeasurementOrder[sharedMeasurementCursor] = nil
            if sharedMeasurements.count >= sharedMeasurementLimit
                || sharedMeasurementCharacters + content.length > sharedMeasurementCharacterLimit {
                sharedMeasurementCursor = (sharedMeasurementCursor + 1) % sharedMeasurementLimit
            }
        }
    }

    // SwiftUI alternates minimum, ideal and final width proposals. Retain those
    // sizes together; a single last-width cache remeasures unchanged history.
    private var measurements: [(width: CGFloat, size: CGSize)] = []
    func update(_ value: NSAttributedString, preservingSelectionOnAppend: Bool = false, replacingAttributes: Bool = false) {
        guard let storage = textStorage, !storage.isEqual(to: value) else { return }
        let appending = value.string.hasPrefix(storage.string)
        let retainedSelection = (preservingSelectionOnAppend || replacingAttributes) && appending ? selectedRange() : nil
        let unchangedPrefix = appending && !replacingAttributes
            && storage.isEqual(to: value.attributedSubstring(from: NSRange(location: 0, length: storage.length)))
        if unchangedPrefix {
            // Streaming prefix growth appends only the delta so TextKit layout
            // invalidates the tail, not the whole paragraph.
            storage.append(value.attributedSubstring(from: NSRange(location: storage.length, length: value.length - storage.length)))
        } else {
            storage.setAttributedString(value)
        }
        if let retainedSelection { setSelectedRange(retainedSelection) }
        measurementContent = value
        measurements.removeAll(keepingCapacity: true)
        applyFindHighlight()
    }
    func measure(width proposed: CGFloat?) -> CGSize {
        // A nil proposal is the ideal unwrapped width used by code and wide tables.
        let width = max(1, proposed?.isFinite == true ? proposed! : 1_000_000)
        if let cached = measurements.first(where: { $0.width == width }) {
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("text_measure_cache_hit")
            #endif
            return cached.size
        }
        guard let storage = textStorage else { return .zero }
        if Self.sharedMeasurementEnabled, textLayoutManager == nil, let content = measurementContent {
            if let cached = Self.sharedMeasurement(for: content, width: width) {
                if measurements.count == 8 { measurements.removeFirst() }
                measurements.append((width, cached))
                #if TRANSCRIPT_CHECKS
                NavigationRenderMetrics.count("text_measure_shared_cache_hit")
                #endif
                return cached
            }
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("text_measure_shared_cache_miss")
            #endif
        }
        let perfProbe = PerfDiagnostics.begin()
        defer { PerfDiagnostics.end("text_measure", perfProbe, detail: "length=\(storage.length) wrapped=\(width < 1_000_000)") }
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer {
            NavigationRenderMetrics.record("text_measure", since: start)
            // An unwrapped probe lays the whole string out on one 1,000,000pt line;
            // splitting it from wrapped measurement is what makes a redundant
            // ideal-width probe visible instead of hiding inside text_measure.
            NavigationRenderMetrics.record(width >= 1_000_000 ? "text_measure_unwrapped" : "text_measure_wrapped", since: start)
        }
        #endif
        // Plain prose and ideal/minimum probes stay independent of the drawing
        // container. Wrapped thoughts use their actual TextKit 2 glyph layout.
        let used: CGRect
        if let layout = textLayoutManager, let content = layout.textContentManager,
           let container = textContainer, proposed != nil, width >= 32, width < 1_000_000 {
            // A thought's final wrapped proposal must match the text system's
            // real glyph layout, including its paragraph rendering attributes.
            // Ideal/minimum probes keep the independent boundingRect path.
            if container.size.width != width {
                container.size = CGSize(width: width, height: 10_000_000)
                layout.invalidateLayout(for: content.documentRange)
            }
            layout.ensureLayout(for: content.documentRange)
            used = layout.usageBoundsForTextContainer
        } else {
            used = storage.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        let size = CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
        if measurements.count == 8 { measurements.removeFirst() }
        measurements.append((width, size))
        if Self.sharedMeasurementEnabled, textLayoutManager == nil, let content = measurementContent {
            Self.storeSharedMeasurement(size, for: content, width: width)
        }
        return size
    }

}

/// A disclosure should not synchronously lay out an unbounded log on opening.
/// Keep the full source available for explicit inspection and copying.
struct DisclosureReplyText: View {
    let text: String
    var attributes: [NSAttributedString.Key: Any]? = nil
    var attributedText: ((String) -> NSAttributedString)? = nil
    @State private var fullOverride: Bool?
    @Environment(\.conversationMemoryKey) private var memoryKey
    private var showingAll: Bool {
        fullOverride ?? (!memoryKey.isEmpty && ConversationReadingMemory.shared.expansions[memoryKey + ":full-output"] == true)
    }
    @State private var reader = LongOutputReaderHandle()
    @Environment(\.conversationDisclosureWillChange) private var disclosureWillChange

    private var expansion: Binding<Bool> {
        Binding(get: { showingAll }, set: { value in
            disclosureWillChange()
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { fullOverride = value }
        })
    }
    private var usesViewport: Bool {
        #if TRANSCRIPT_CHECKS
        return ProcessInfo.processInfo.environment["NAVIGATION_LONG_OUTPUT_VARIANT"] != "inline"
        #else
        return true
        #endif
    }

    var body: some View {
        let prefix = text.prefix(4_000)
        let isLong = prefix.endIndex != text.endIndex
        let visible = showingAll || !isLong ? text : String(prefix)
        #if TRANSCRIPT_CHECKS
        let _ = { if ConversationDisclosureFixture.enabled && isLong {
            ConversationDisclosureFixture.fullBindings[text] = expansion
        } }()
        #endif
        VStack(alignment: .leading, spacing: 8) {
            if showingAll && isLong && usesViewport {
                LongOutputReader(text: text, attributes: attributes, handle: reader)
                    .frame(height: 360)
            } else {
                Group {
                    if let attributedText {
                        SelectableReplyText(attributed: attributedText(visible))
                    } else if let attributes {
                        SelectableReplyText(attributed: NSAttributedString(string: visible, attributes: attributes))
                    } else {
                        SelectableReplyText(visible)
                    }
                }.frame(height: isLong && usesViewport ? 360 : nil, alignment: .top).clipped()
            }
            if isLong {
                HStack(spacing: 12) {
                    if !showingAll { Text("…").foregroundStyle(.secondary) }
                    Button(showingAll ? "收起长内容" : "显示完整内容") { expansion.wrappedValue.toggle() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    if showingAll && usesViewport {
                        Button("查找完整内容") { reader.showFindBar() }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    ReplyCopyButton(text: text, label: "复制完整内容")
                }.font(.system(size: ReplyStyle.captionSize))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Complete text has its own viewport. The transcript measures only this fixed
/// viewport, never the full text height. TextKit owns selection and text layout.
@MainActor @Observable final class LongOutputReaderHandle {
    @ObservationIgnored weak var textView: NSTextView?
    var searchVisible = false
    var query = ""
    var found: Bool?
    func showFindBar() { searchVisible = true }
    func find(backwards: Bool = false) {
        guard let textView, !query.isEmpty else { found = nil; return }
        let source = textView.string as NSString
        let selection = textView.selectedRange()
        let start = min(source.length, backwards ? selection.location : NSMaxRange(selection))
        let range = backwards ? NSRange(location: 0, length: start) : NSRange(location: start, length: source.length - start)
        var options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if backwards { options.insert(.backwards) }
        var hit = source.range(of: query, options: options, range: range)
        if hit.location == NSNotFound { hit = source.range(of: query, options: options) }
        found = hit.location != NSNotFound
        if found == true {
            textView.setSelectedRange(hit)
            textView.scrollRangeToVisible(hit)
        }
    }
}

struct LongOutputReader: View {
    let text: String
    let attributes: [NSAttributedString.Key: Any]?
    @Bindable var handle: LongOutputReaderHandle
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 6) {
            if handle.searchVisible {
                HStack(spacing: 8) {
                    TextField("查找完整内容", text: $handle.query)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                        .onSubmit { handle.find() }
                    if handle.found == false { Text("未找到").foregroundStyle(.secondary) }
                    Button { handle.find(backwards: true) } label: { Image(systemName: "chevron.up") }
                        .help("上一个匹配").accessibilityLabel("上一个匹配")
                    Button { handle.find() } label: { Image(systemName: "chevron.down") }
                        .help("下一个匹配").accessibilityLabel("下一个匹配")
                    Button { handle.searchVisible = false } label: { Image(systemName: "xmark") }
                        .help("关闭查找").accessibilityLabel("关闭查找")
                }.font(.system(size: ReplyStyle.captionSize)).frame(height: 28)
            }
            LongOutputViewport(text: text, attributes: attributes, handle: handle)
                .frame(height: handle.searchVisible ? 326 : 360)
        }.frame(height: 360)
            .onChange(of: handle.searchVisible) { _, visible in searchFocused = visible }
            .onChange(of: handle.query) { _, _ in handle.found = nil }
    }
}

private final class LongOutputTextView: NSTextView {
    var find: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" { find?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

private struct LongOutputViewport: NSViewRepresentable {
    let text: String
    let attributes: [NSAttributedString.Key: Any]?
    let handle: LongOutputReaderHandle

    final class Coordinator {
        var text: String?
        var attributes: NSDictionary?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.identifier = .init("perch-long-output")
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = LongOutputTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 360)
        view.minSize = NSSize(width: 0, height: 360)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.enabledTextCheckingTypes = 0
        view.find = { [weak handle] in handle?.showFindBar() }
        view.setAccessibilityLabel(L("完整内容"))
        scroll.documentView = view
        handle.textView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        handle.textView = view
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let style = attributes ?? [.font: NSFont.monospacedSystemFont(ofSize: ReplyStyle.captionSize, weight: .regular),
                                   .foregroundColor: ReplyStyle.nativeInk, .paragraphStyle: paragraph]
        let dictionary = style as NSDictionary
        guard context.coordinator.text != text || context.coordinator.attributes != dictionary else { return }
        let previous = context.coordinator.text
        let appending = context.coordinator.attributes == dictionary && previous.map { text.hasPrefix($0) } == true
        let sourceChanged = context.coordinator.text != text
        context.coordinator.text = text
        context.coordinator.attributes = dictionary
        if appending, let previous {
            let suffix = (text as NSString).substring(from: previous.utf16.count)
            view.textStorage?.append(NSAttributedString(string: suffix, attributes: style))
        } else {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: style))
        }
        if sourceChanged && !appending {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? ReplyStyle.readingWidth, height: proposal.height ?? 360)
    }
}

struct ReplyActionButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                (configuration.isPressed ? WorkbenchTheme.Fill.pressed : hovered ? WorkbenchTheme.Fill.hover : Color.clear),
                in: RoundedRectangle(cornerRadius: WorkbenchTheme.Composer.CompactShape.cornerRadius, style: .continuous))
            .onHover { hovered = $0 }
    }
}

struct ReplyCopyButton: View {
    let text: String
    var label: LocalizedStringKey = "复制回复"
    /// Card banners read the affordance at full strength (DSH's copy label is primary).
    var prominent = false
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: ReplyStyle.captionSize, weight: copied ? .semibold : .regular))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(ReplyActionButtonStyle())
            .foregroundStyle(copied ? Color(nsColor: WorkbenchTheme.statusSuccessNS) : (prominent ? Color.primary.opacity(0.84) : WorkbenchTheme.quiet))
            .help(copied ? "已复制" : label)
            .accessibilityLabel(copied ? "已复制" : label)
            .task(id: copied) {
                if copied { try? await Task.sleep(for: .seconds(2)); copied = false }
            }
    }
}

/// The code card's scrolling text area, shared by the mermaid card's source view.
struct ReplyCodeBody: View {
    let source: String
    var language = ""
    private var lineCount: Int { CodeLineNumbers.count(in: source) }
    var body: some View {
        ReplyHorizontalScroll {
            HStack(alignment: .top, spacing: 0) {
                if lineCount > 1 {
                    SelectableReplyText(attributed: ReplyTextAttributes.codeGutter(lineCount), selectable: false)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.leading, ReplyStyle.Code.gutterLeading).padding(.trailing, ReplyStyle.Code.gutterTrailing)
                        .padding(.vertical, ReplyStyle.Code.inset)
                }
                SelectableReplyText(attributed: ReplyTextAttributes.code(source), preservesSelectionOnAppend: true, codeLanguage: language)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(EdgeInsets(top: ReplyStyle.Code.inset, leading: lineCount > 1 ? 0 : ReplyStyle.Code.inset,
                                        bottom: ReplyStyle.Code.inset, trailing: ReplyStyle.Code.inset))
            }
        }
    }
}

struct ReplyCode: View {
    let language: String
    let source: String
    @State private var hovered = false
    private var lineCount: Int { CodeLineNumbers.count(in: source) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // DSH shows the banner on single-line blocks too; the language
                // slot stays empty when the fence carries none.
                if !language.isEmpty {
                    Text(language).font(.system(size: ReplyStyle.Code.labelSize, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Spacer()
                ReplyCopyButton(text: source, label: "复制代码", prominent: true)
            }.padding(.horizontal, ReplyStyle.Code.headerHorizontalPadding).padding(.vertical, ReplyStyle.Code.headerVerticalPadding)
                // DSH banner strip: the card's surface in light, lighter in dark.
                .background(Color(nsColor: WorkbenchTheme.replyBannerNS),
                            in: UnevenRoundedRectangle(topLeadingRadius: ReplyStyle.Code.cornerRadius, topTrailingRadius: ReplyStyle.Code.cornerRadius))
                .overlay(alignment: .bottom) {
                    Color(nsColor: WorkbenchTheme.codeHeaderDividerNS).frame(height: 0.5)
                }
            ReplyCodeBody(source: source, language: language)
                .overlay(alignment: .bottomTrailing) {
                    if hovered && lineCount > 8 {
                        ReplyCopyButton(text: source, label: "复制代码", prominent: true)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row, style: .continuous))
                            .padding(8)
                    }
                }
        }.background(ReplyStyle.paper, in: RoundedRectangle(cornerRadius: ReplyStyle.Code.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ReplyStyle.Code.cornerRadius).strokeBorder(WorkbenchTheme.Stroke.hairline, lineWidth: 1))
            .onHover { hovered = $0 }
    }
}

/// Sideways scrolling for code cards and tables wider than the column. While the
/// content is wider than the viewport, its trailing edge fades out so a cut-off
/// line reads as continuing; `NativeCodeCardView` draws the same fade. The fade is
/// a mask, so layout and hit testing are untouched, and the flag it keeps feeds no
/// layout: it cannot start a geometry loop.
private struct ReplyHorizontalScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var overflows = false
    var body: some View {
        // The settled native card uses an overlay scroller that takes no height.
        // When macOS shows legacy scrollers (a mouse is attached), a SwiftUI
        // scroll view reserves a scroller band below an overflowing line once it
        // is displayed, so a card would be taller than the native card it settles
        // into. Never reserve it; trackpad and Shift-wheel still scroll.
        ScrollView(.horizontal) {
            content.onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > (proxy.bounds(of: .scrollView)?.width ?? proxy.size.width) + 0.5
            } action: { overflows = $0 }
        }
        .scrollIndicators(.never, axes: .horizontal)
        .mask { ReplyOverflowFade(active: overflows) }
    }
}

/// Opaque, then clear across the trailing `overflowFadeWidth`; fully opaque while inactive.
private struct ReplyOverflowFade: View {
    let active: Bool
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.black)
            LinearGradient(colors: [Color.black, active ? Color.clear : Color.black],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: ReplyStyle.overflowFadeWidth)
                .flipsForRightToLeftLayoutDirection(true)
        }
    }
}

private struct ReplyTable: View {
    @Environment(\.documentReadingStyle) private var documentReadingStyle
    @Environment(\.documentFontScale) private var documentFontScale
    let headers: [[ReplyInline]]
    let rows: [[[ReplyInline]]]
    let alignments: [ReplyAlignment]
    /// The preview sheet renders the same cells without re-nesting its own bar.
    var showsActions = true
    @State private var previewPresented = false
    private var cellSize: CGFloat { ReplyStyle.tableCellSize }
    private var geometry: ReplyTableGeometry {
        documentReadingStyle ? ReplyTableGeometry(fontSize: cellSize * documentFontScale) : ReplyStyle.tableGeometry
    }
    /// Math/code content survives extraction from the rendered cell runs.
    private var tableData: TableData {
        TableData(headerCells: headers.map { TableCell(inlines: $0) },
                  cellRows: rows.map { $0.map { TableCell(inlines: $0) } },
                  alignments: alignments)
    }

    var body: some View {
        let geometry = geometry
        let data = tableData
        let contents = ReplyTableGeometry.contentWidths(headers: headers, rows: rows, fontSize: geometry.fontSize)
        let minimumTotal = geometry.minimumWidths(contentWidths: contents).reduce(0, +)
        VStack(alignment: .leading, spacing: 2) {
            if showsActions {
                HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    ReplyTableCopyButton(data: data)
                    ReplyTableActionButton(symbol: "square.and.arrow.up", label: "导出 CSV") { exportTableCSV(data) }
                    ReplyTableActionButton(symbol: "arrow.up.left.and.arrow.down.right", label: "放大表格") {
                        previewPresented = true
                    }
                }
            }
            // Fit the viewport first; only the minimum column widths can cause overflow.
            ReplyHorizontalScroll {
                ReplyTableLayout(contents: contents, geometry: geometry, columnCount: headers.count) {
                    cells
                }
                .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                    max(width, minimumTotal)
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .sheet(isPresented: $previewPresented) {
            ReplyTablePreview(headers: headers, rows: rows, alignments: alignments, tableData: data)
        }
    }

    /// Header cells first, then one separator and one row of cells per data row,
    /// closing with the trailing row rule: the order `ReplyTableLayout` walks.
    /// The first separator is the header rule (DSH: th border-bottom l3, td l2,
    /// the last row included).
    @ViewBuilder private var cells: some View {
        ForEach(Array(headers.indices), id: \.self) { column in
            cell(headers[column], column: column, header: true)
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            Rectangle()
                .fill(.primary.opacity(index == 0 ? ReplyStyle.Table.headerRuleOpacity : ReplyStyle.Table.rowRuleOpacity))
                .frame(height: 1)
            ForEach(Array(headers.indices), id: \.self) { column in
                cell(column < row.count ? row[column] : [], column: column, header: false)
            }
        }
        Rectangle()
            .fill(.primary.opacity(rows.isEmpty ? ReplyStyle.Table.headerRuleOpacity : ReplyStyle.Table.rowRuleOpacity))
            .frame(height: 1)
    }

    private func cell(_ runs: [ReplyInline], column: Int, header: Bool) -> some View {
        // DSH table cells: 10 pt vertical, 16 pt side padding, with the first
        // column flush to the column edge and the last flush to the right.
        ReplyText(runs: runs, size: cellSize, weight: header ? .medium : .regular,
                  alignment: alignments[column] == .trailing ? .trailing : alignments[column] == .center ? .center : .leading,
                  lineHeight: documentReadingStyle ? cellSize * 1.65 : ReplyStyle.Table.cellLineHeight)
            .environment(\.documentMutedText, documentReadingStyle && header)
            .padding(.leading, column == 0 ? 0 : geometry.cellPadding)
            .padding(.trailing, column == headers.count - 1 ? 0 : geometry.cellPadding)
            .padding(.vertical, documentReadingStyle ? 11 : ReplyStyle.Table.cellVerticalPadding)
    }
}

/// Shared by the transcript row and the preview sheet; the BOM keeps Chinese
/// readable when the CSV lands in Excel.
@MainActor private func exportTableCSV(_ tableData: TableData) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = L("表格.csv")
    panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        try ("\u{FEFF}" + TableSerialization.csv(tableData)).write(to: url, atomically: true, encoding: .utf8)
    } catch {
        NSAlert(error: error).runModal()
    }
}

/// A table action sharing the code card's copy-button geometry: 24 pt hit area,
/// caption-size glyph, quiet until hovered.
private struct ReplyTableActionButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: ReplyStyle.captionSize))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary).help(label)
            .accessibilityLabel(label)
    }
}

/// Serialize on the copy action rather than on every streamed table update.
private struct ReplyTableCopyButton: View {
    let data: TableData
    @State private var copied = false
    var body: some View {
        ReplyTableActionButton(symbol: copied ? "checkmark" : "doc.on.doc", label: copied ? "已复制" : "复制 Markdown") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(TableSerialization.markdown(data), forType: .string)
            copied = true
        }
        .onChange(of: data) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}

/// The table's own wider surface: same cells and actions, more room, Escape or
/// 关闭 returns to the reader's scroll position untouched.
private struct ReplyTablePreview: View {
    let headers: [[ReplyInline]]
    let rows: [[[ReplyInline]]]
    let alignments: [ReplyAlignment]
    let tableData: TableData
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Text("表格预览").font(.system(size: ReplyStyle.labelSize, weight: .medium))
                Spacer(minLength: 0)
                ReplyTableCopyButton(data: tableData)
                ReplyTableActionButton(symbol: "square.and.arrow.up", label: "导出 CSV") { exportTableCSV(tableData) }
                ReplyTableActionButton(symbol: "xmark", label: "关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView(.vertical) {
                ReplyTable(headers: headers, rows: rows, alignments: alignments, showsActions: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 880, minHeight: 240, idealHeight: 480)
        .onExitCommand { dismiss() }
    }
}

/// Places cells row-major at the column totals from `ReplyTableGeometry`. Cells are
/// measured only for row height, at their final width, so a table makes fewer text
/// probes than the equal-split grid it replaces. Widths are arithmetic over content,
/// which keeps GeometryReader and state — and with them any layout feedback loop —
/// out of the transcript, matching `ReplyListLayout`.
private struct ReplyTableLayout: Layout {
    let contents: [CGFloat]
    let geometry: ReplyTableGeometry
    let columnCount: Int
    private let separatorHeight: CGFloat = 1

    struct Measurement {
        let width: CGFloat?
        let size: CGSize
        let placements: [(point: CGPoint, size: CGSize)]
    }
    func makeCache(subviews: Subviews) -> [Measurement] { [] }
    func updateCache(_ cache: inout [Measurement], subviews: Subviews) { cache.removeAll(keepingCapacity: true) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [Measurement]) -> CGSize {
        measure(width: proposal.width.flatMap { $0.isFinite ? $0 : nil }, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [Measurement]) {
        let placed = measure(width: bounds.width.isFinite ? bounds.width : nil, subviews: subviews, cache: &cache).placements
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + placed[index].point.x, y: bounds.minY + placed[index].point.y),
                                  anchor: .topLeading, proposal: ProposedViewSize(placed[index].size))
        }
    }

    /// Both passes share one bounded measurement per width, as `ReplyListLayout` does.
    private func measure(width: CGFloat?, subviews: Subviews, cache: inout [Measurement]) -> Measurement {
        if let measured = cache.first(where: { $0.width == width }) { return measured }
        let widths = geometry.columnWidths(contentWidths: contents, available: width)
        var placements: [(point: CGPoint, size: CGSize)] = Array(repeating: (.zero, .zero), count: subviews.count)
        guard columnCount > 0, widths.count == columnCount else {
            return Measurement(width: width, size: CGSize(width: width ?? 0, height: 0), placements: placements)
        }
        let total = widths.reduce(0, +)
        var height: CGFloat = 0
        var index = 0
        while index < subviews.count {
            if isSeparator(index) {
                placements[index] = (CGPoint(x: 0, y: height), CGSize(width: total, height: separatorHeight))
                height += separatorHeight
                index += 1
                continue
            }
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            for column in 0..<columnCount {
                guard index < subviews.count else { break }
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: widths[column], height: nil))
                placements[index] = (CGPoint(x: x, y: height), CGSize(width: widths[column], height: size.height))
                rowHeight = max(rowHeight, size.height)
                x += widths[column]
                index += 1
            }
            height += rowHeight
        }
        let measured = Measurement(width: width, size: CGSize(width: width ?? widths.reduce(0, +), height: height), placements: placements)
        if cache.count == 4 { cache.removeFirst() }
        cache.append(measured)
        return measured
    }

    private func isSeparator(_ index: Int) -> Bool {
        index >= columnCount && (index - columnCount) % (columnCount + 1) == 0
    }
}

// Document controls stay local to the reader; conversation rendering keeps defaults.
extension EnvironmentValues {
    @Entry var documentFontScale: CGFloat = 1
    @Entry var documentReadingStyle = false
    @Entry var documentMutedText = false
    @Entry var documentQuery: String = ""
    @Entry var documentOpenLink: ((URL) -> Bool)? = nil
    @Entry var documentSelection: ((String) -> Void)? = nil
}
@MainActor private final class DocumentSelectionAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func performSelection(_ sender: NSMenuItem) { action() }
}
