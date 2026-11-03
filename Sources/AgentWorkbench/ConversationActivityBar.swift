import AppKit
import SwiftUI
import WorkbenchCore

/// Running in session lists: the Perch sun chasing on its own. CoreAnimation
/// only; the transcript graph is never invalidated.
struct ConversationBusyIndicator: View {
    var body: some View { PerchBusyIndicator() }
}

/// Results the reader has moved on from, by session and end time. In memory only:
/// a relaunch starts with no results, because it watched no turn end.
@MainActor enum TurnResultMemory {
    private static var dismissed: Set<String> = []
    private static var order: [String] = []
    static func contains(_ key: String) -> Bool { dismissed.contains(key) }
    static func dismiss(_ key: String) {
        guard dismissed.insert(key).inserted else { return }
        order.append(key)
        if order.count > 500 { dismissed.remove(order.removeFirst()) }
    }
}

/// The status line between the transcript and the composer. It answers three
/// questions only (`TurnStatus`): is the turn alive, what is it doing, what does
/// it need from the reader. It has no leading mark: a running turn's title
/// shimmers (`ShimmerGlint`), and everything that needs the reader is orange text
/// with its own button. A click on the line opens the task panel's 本轮 section
/// (plan, edits by file, timing, subagents and background tasks), shown by a
/// trailing chevron; the turn's +a −d on the right opens the changes page.
/// Every visible state shares one transparent row height, so a run starting,
/// waiting or failing never resizes the transcript; an idle session takes no
/// space. Only the clock and the shimmer move on their own.
struct ConversationActivityBar: View {
    static let height: CGFloat = 32
    let activity: ConversationActivity
    /// The session's turn facts, built by the constructors the sidebar and
    /// notifications use, so all of them agree on running, waiting and failed.
    let turn: SessionTurn
    var timing: ConversationTiming? = nil
    var online = true
    /// Last connection error; the reconnect tooltip shows it.
    var offlineDetail: String? = nil
    var pendingCount = 0
    /// What the agent waits for, in its own words.
    var request: TurnRequest? = nil
    /// The session's reading key: its narratives and its remembered result.
    var narrativeSession: String? = nil
    var narrativeOverride: ActivityNarrative? = nil
    var recapKey: String? = nil
    var recapMessages: (@MainActor () async throws -> [KimiMessage])? = nil
    var recapStateOverride: TaskRecapState? = nil
    var recapConfiguredOverride: Bool? = nil
    var onRecapGenerateOverride: ((Bool) -> Void)? = nil
    var onReview: () -> Void = {}
    var onReconnect: () -> Void = {}
    /// Opens this turn in the task panel.
    var onDetails: () -> Void = {}
    /// Opens the working-tree changes; nil hides 查看改动.
    var onChanges: (() -> Void)? = nil
    /// Once per quiet stretch past the stall threshold, with its minutes.
    var onStall: (Int) -> Void = { _ in }
    @UILocalization private var L
    @State private var recapPresented = false
    @State private var progress = TurnProgressClock()
    @State private var stalledMinutes: Int?
    @State private var highlight = false
    @ObservedObject var narrativeStore = ActivityNarrativeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    private var narrative: ActivityNarrative? {
        narrativeOverride ?? narrativeSession.flatMap { narrativeStore.narrative(session: $0) }
    }
    /// The result this line shows once the turn ends, by session and end time.
    private var resultKey: String? {
        guard let narrativeSession, let end = timing?.endedAt else { return nil }
        return "\(narrativeSession):\(end.timeIntervalSinceReferenceDate)"
    }
    private var status: TurnStatus {
        TurnStatus(activity: activity, turn: turn, online: online, pendingCount: pendingCount,
                   request: request, timing: timing, narrativeHeadline: turn.running ? narrative?.headline : nil,
                   stalledMinutes: activity.animates ? stalledMinutes : nil,
                   resultDismissed: resultKey.map { TurnResultMemory.contains($0) } ?? false, locale: locale)
    }
    private var progressKey: TurnProgressClock.Key {
        TurnProgressClock.Key(signature: activity.progressSignature, toolRunning: !activity.activeTools.isEmpty)
    }

    var body: some View {
        let status = self.status
        ZStack {
            if status.state != .hidden {
                line(status).font(.system(size: WorkbenchTheme.Reading.labelSize))
                    .foregroundStyle(WorkbenchTheme.quiet)
                    .padding(.horizontal, 2).frame(height: Self.height)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: status.state == .hidden)
        // A reference write per update: progress never invalidates this body.
        .onChange(of: progressKey, initial: true) { _, key in
            progress.mark(key)
            if stalledMinutes != nil { stalledMinutes = nil }
        }
        .task(id: activity.animates) { await watchStall(running: activity.animates) }
        .onChange(of: status.state) { old, new in
            // One soft emphasis when a watched turn ends, never a loop.
            guard new == .done, old == .running, !reduceMotion else { return }
            highlight = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeOut(duration: 0.9)) { highlight = false }
            }
        }
        // Switching away is moving on: the result collapses until the next turn.
        .onDisappear {
            if status.state == .done, let resultKey { TurnResultMemory.dismiss(resultKey) }
        }
    }

    /// Checks every 15 s while the turn runs; progress resets the clock.
    private func watchStall(running: Bool) async {
        guard running else {
            if stalledMinutes != nil { stalledMinutes = nil }
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            let minutes = progress.stalledMinutes(now: Date())
            if minutes != stalledMinutes { stalledMinutes = minutes }
            if let minutes, !progress.reported {
                progress.reported = true
                onStall(minutes)
            }
        }
    }

    /// The line is a button behind the row: the task panel, or the pending card
    /// while waiting. The turn's edits, Recap and the state's own action are
    /// buttons on top; text and facts let clicks through to the line.
    private func line(_ status: TurnStatus) -> some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                headline(status, level: 1)
                headline(status, level: 0)
            }.layoutPriority(1).allowsHitTesting(false)
            if status.state == .running && status.attention > 0 {
                // A running agent may still recover: a count, not a new color for the action.
                Text("\(status.attention) 项需关注").foregroundStyle(Color.orange).fixedSize().allowsHitTesting(false)
            }
            Spacer(minLength: 6).layoutPriority(-2)
            trailing(status)
        }.padding(.horizontal, 8).frame(height: 28)
            .background { lineButton(status) }
    }

    private func lineButton(_ status: TurnStatus) -> some View {
        Button { status.state == .waiting ? onReview() : onDetails() } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(WorkbenchDisclosureButtonStyle())
            .accessibilityLabel(Text("本轮状态"))
            .accessibilityValue(Text(verbatim: accessibilityValue(status)))
            .accessibilityHint(status.state == .waiting ? Text("查看等待你确认的事项") : Text("在任务面板查看本轮详情"))
            .help(status.state == .waiting ? Text(verbatim: status.headline) : Text("在任务面板查看本轮详情"))
    }

    /// Level 1 says everything; level 0 is the title alone, which truncates last.
    private func headline(_ status: TurnStatus, level: Int) -> some View {
        HStack(spacing: status.result == nil ? 6 : 4) {
            title(status).layoutPriority(1)
            if let detail = status.detail, level > 0 {
                Text(verbatim: detail).foregroundStyle(WorkbenchTheme.quiet)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let result = status.result, let duration = result.duration, level > 0 {
                let value = TurnStatus.clock(duration, chinese: chinese)
                Group {
                    if result.observedOnly { Text("· 观察时长 \(value)") } else { Text("· 用时 \(value)") }
                }.fixedSize()
            }
        }.accessibilityHidden(true)
    }

    /// Every title is plain text in its tone. A running one shimmers: an ink copy
    /// over it, shown through a moving band (`ShimmerGlint`).
    private func title(_ status: TurnStatus) -> some View {
        Text(verbatim: status.headline).fontWeight(status.needsReader ? .medium : .regular)
            .foregroundStyle(status.needsReader ? Color.orange : highlight ? Color.primary : WorkbenchTheme.quiet)
            .lineLimit(1).truncationMode(.tail)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: status.headline)
            .overlay {
                if status.shimmers && !reduceMotion {
                    ShimmerGlint(text: status.headline, size: WorkbenchTheme.Reading.labelSize)
                }
            }
    }

    /// Plan steps, this turn's edits and the clock, then the state's own buttons
    /// and the chevron. In a narrow window plan steps fold first, then edits.
    @ViewBuilder private func trailing(_ status: TurnStatus) -> some View {
        let clock = status.state == .running || status.state == .stopping ? timing : nil
        let progress = [.running, .stopping, .plan].contains(status.state) ? status.progress : nil
        let changes = onChanges == nil ? nil : status.changes
        if progress != nil || changes != nil || clock != nil {
            ViewThatFits(in: .horizontal) {
                facts(progress, changes, clock)
                facts(nil, changes, clock)
                facts(nil, nil, clock)
                Color.clear.frame(width: 0, height: 0)
            }.font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(WorkbenchTheme.quiet)
                .layoutPriority(-1)
        }
        // The state's own buttons keep their size; the title yields first.
        actions(status).fixedSize()
        if status.opensDetails {
            Image(systemName: "chevron.right").font(.system(size: WorkbenchTheme.Reading.captionSize - 1, weight: .semibold))
                .foregroundStyle(WorkbenchTheme.quiet).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private func facts(_ progress: TurnStatus.Progress?, _ changes: TurnStatus.Changes?, _ clock: ConversationTiming?) -> some View {
        HStack(spacing: 10) {
            if let progress {
                Text(verbatim: "\(progress.done) / \(progress.total)").allowsHitTesting(false).accessibilityHidden(true)
            }
            if let changes, let onChanges {
                Button(action: onChanges) {
                    EditStatText(stat: SessionEditStat(additions: changes.additions, deletions: changes.deletions))
                        .padding(.horizontal, 4).frame(height: 22).contentShape(Rectangle())
                }.buttonStyle(WorkbenchDisclosureButtonStyle())
                    .help(Text("查看改动：本轮改了 \(changes.files) 个文件"))
                    .accessibilityLabel(Text("查看改动"))
                    .accessibilityValue(Text(verbatim: L("本轮改了 \(changes.files) 个文件") + " +\(changes.additions) −\(changes.deletions)"))
            }
            if let clock { TurnClock(timing: clock).allowsHitTesting(false) }
        }.fixedSize().monospacedDigit()
    }

    private var chinese: Bool { locale.language.languageCode?.identifier == "zh" }

    private func accessibilityValue(_ status: TurnStatus) -> String {
        var parts = [status.headline]
        if let detail = status.detail { parts.append(detail) }
        if status.state == .running && status.attention > 0 { parts.append(L("\(status.attention) 项需关注")) }
        if let progress = status.progress { parts.append(L("\(progress.done)/\(progress.total) 步")) }
        if let changes = status.changes {
            parts.append(L("本轮改了 \(changes.files) 个文件") + " +\(changes.additions) −\(changes.deletions)")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func actions(_ status: TurnStatus) -> some View {
        switch status.state {
        case .offline:
            Button("重新连接", action: onReconnect).buttonStyle(.bordered).controlSize(.small).tint(.orange)
                .help(offlineDetail.map { Text(verbatim: $0) } ?? Text("重新连接"))
        case .waiting:
            Button("查看") { onReview() }.buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
                .help("查看等待你确认的事项").accessibilityHint(Text("查看等待你确认的事项"))
        case .review:
            Button("查看", action: onDetails).buttonStyle(.bordered).controlSize(.small).tint(.orange)
                .help("在任务面板查看需要关注的工具结果").accessibilityHint(Text("在任务面板查看需要关注的工具结果"))
        case .failed:
            Button("查看", action: onDetails).buttonStyle(.bordered).controlSize(.small).tint(.orange)
                .help("在任务面板查看失败原因").accessibilityHint(Text("在任务面板查看失败原因"))
        case .done:
            if let recapKey {
                Button { recapPresented = true } label: {
                    Label("Recap", systemImage: "sparkles")
                }.buttonStyle(.borderless).controlSize(.small)
                    .help("总结本次任务，不会向 Agent 发送消息")
                    .popover(isPresented: $recapPresented, arrowEdge: .top) {
                        TaskRecapPopover(key: recapKey, messages: recapMessages,
                                         stateOverride: recapStateOverride,
                                         configuredOverride: recapConfiguredOverride,
                                         onGenerateOverride: onRecapGenerateOverride)
                    }
            }
        case .running, .stopping, .plan, .hidden:
            EmptyView()
        }
    }
}

/// The shimmer over a running turn's title, the way Codex's status line does it
/// (codex-rs/tui/src/shimmer.rs): an ink copy of the title, seen through a band
/// that sweeps left to right in 1.6 s, then rests 0.8 s. The copy is the same
/// SwiftUI text rendered once to an image at the title's own frame, so it lines
/// up glyph for glyph and truncates the same way; CoreAnimation moves the band's
/// gradient mask, so nothing is laid out or drawn per frame.
struct ShimmerGlint: NSViewRepresentable {
    let text: String
    let size: CGFloat
    func makeNSView(context: Context) -> ShimmerGlintView { ShimmerGlintView() }
    func updateNSView(_ view: ShimmerGlintView, context: Context) { view.configure(text: text, size: size) }
    static func dismantleNSView(_ view: ShimmerGlintView, coordinator: ()) { view.stopObserving() }
}

final class ShimmerGlintView: PresentationAnimationView {
    static let sweep: CFTimeInterval = 1.6
    static let rest: CFTimeInterval = 0.8
    /// The band's peak: nearly the body ink, as Codex blends 90%.
    static let peak: CGFloat = 0.9
    private let copy = CALayer()
    private let band = CAGradientLayer()
    private var text = ""
    private var size: CGFloat = 0
    private var rendered: (text: String, size: CGFloat, bounds: CGSize, scale: CGFloat, dark: Bool)?

    override var isFlipped: Bool { true }
    /// Clicks reach the status line behind the title.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(copy)
        copy.contentsGravity = .topLeft
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: Self.peak).cgColor,
                       NSColor(white: 1, alpha: 0).cgColor]
        copy.mask = band
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, size: CGFloat) {
        guard text != self.text || size != self.size else { return }
        self.text = text; self.size = size
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }
    override func presentationActivityChanged() { refresh() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rendered = nil
        refresh()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// Renders the ink copy when the text, its frame, the scale or the
    /// appearance changed, and restarts the sweep when the width did.
    private func refresh() {
        guard canAnimate, let window, bounds.width > 0, bounds.height > 0, !text.isEmpty else {
            band.removeAllAnimations()
            copy.contents = nil
            rendered = nil
            return
        }
        let scale = window.backingScaleFactor
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = (text: text, size: size, bounds: bounds.size, scale: scale, dark: dark)
        if let rendered, rendered.text == key.text, rendered.size == key.size, rendered.bounds == key.bounds,
           rendered.scale == key.scale, rendered.dark == key.dark, band.animation(forKey: "sweep") != nil { return }
        var ink = WorkbenchTheme.inkNS
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = WorkbenchTheme.inkNS.usingColorSpace(.sRGB) ?? WorkbenchTheme.inkNS }
        let renderer = ImageRenderer(content: Text(verbatim: text).font(.system(size: size)).foregroundStyle(Color(nsColor: ink))
            .lineLimit(1).truncationMode(.tail)
            .frame(width: bounds.width, height: bounds.height, alignment: .leading))
        renderer.scale = scale
        let widthChanged = rendered?.bounds.width != bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        copy.frame = bounds
        copy.contentsScale = scale
        copy.contents = renderer.cgImage
        let width = max(24, bounds.height * 2.4)
        band.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        rendered = key
        guard widthChanged || band.animation(forKey: "sweep") == nil else { return }
        // The band starts just off the left edge and ends just off the right,
        // then holds there for the rest.
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = [-width / 2, bounds.width + width / 2, bounds.width + width / 2]
        move.keyTimes = [0, NSNumber(value: Self.sweep / (Self.sweep + Self.rest)), 1]
        move.duration = Self.sweep + Self.rest
        move.repeatCount = .infinity
        band.add(move, forKey: "sweep")
    }
}

/// When the turn last showed progress. The status line writes it on every
/// change without invalidating its body; only the stall check reads it.
final class TurnProgressClock {
    struct Key: Equatable {
        let signature: Int
        let toolRunning: Bool
    }
    private var key: Key?
    private var since = Date()
    /// The current quiet stretch was already reported.
    var reported = false
    func mark(_ next: Key) {
        guard next != key else { return }
        key = next; since = Date(); reported = false
    }
    func stalledMinutes(now: Date) -> Int? {
        TurnStatus.stalledMinutes(quietFor: now.timeIntervalSince(since), toolRunning: key?.toolRunning ?? false)
    }
}

/// The running turn's clock: seconds for the first minute, then minutes, and it
/// redraws only when the reading changes.
private struct TurnClock: View {
    let timing: ConversationTiming
    @Environment(\.locale) private var locale
    var body: some View {
        Group {
            if AppPresentationActivity.shared.isActive {
                TimelineView(TurnClockSchedule(start: timing.startedAt)) { context in label(at: context.date) }
            } else { label(at: Date()) }
        }.monospacedDigit().fixedSize()
            .help(timing.observedOnly
                  ? Text("从客户端首次观察到本轮开始计时，包含等待；此前用时未知。")
                  : Text("从提交本轮请求到现在的经过时间，包含通信、工具调用和等待。"))
    }
    private func label(at date: Date) -> some View {
        Text(verbatim: TurnStatus.clock(timing.elapsed(at: date), chinese: locale.language.languageCode?.identifier == "zh"))
    }
}

private struct TurnClockSchedule: TimelineSchedule {
    let start: Date
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let current = next
            next = current.addingTimeInterval(max(0.05, TurnStatus.nextClockChange(after: current.timeIntervalSince(start))))
            return current
        }
    }
}

/// +/− tally in the quiet palette; shared by the result line and the task panel.
struct EditStatText: View {
    let stat: SessionEditStat
    var body: some View {
        HStack(spacing: 4) {
            Text("+\(stat.additions)").foregroundStyle(Color.green.opacity(0.9))
            Text("−\(stat.deletions)").foregroundStyle(Color.red.opacity(0.9))
        }.monospacedDigit()
    }
}

struct TaskRecapPopover: View {
    let key: String
    let messages: (@MainActor () async throws -> [KimiMessage])?
    let stateOverride: TaskRecapState?
    let configuredOverride: Bool?
    let onGenerateOverride: ((Bool) -> Void)?
    @ObservedObject private var store = TaskRecapStore.shared
    @ObservedObject private var settings = ActivitySummarySettings.shared
    @State private var showSettings = false
    @State private var copied = false
    @UILocalization private var L

    private var state: TaskRecapState { stateOverride ?? store.state(for: key) }
    private var configured: Bool {
        configuredOverride ?? (settings.configuration.enabled && settings.configuration.isValid)
    }
    private var warning: String? { stateOverride == nil ? store.warning(for: key) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Task Recap", systemImage: "sparkles").font(.system(size: WorkbenchTheme.Reading.secondarySize, weight: .semibold))
                Spacer()
                if configured {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("配置 Recap 服务").accessibilityLabel(Text("配置 Recap 服务"))
                }
            }
            content
            if let warning {
                Text(warning).font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.font(.system(size: WorkbenchTheme.Reading.labelSize)).padding(16).frame(width: 420)
            .task(id: key) {
                if configured, case .idle = state { generate(force: false) }
            }
            .onChange(of: settings.revision) { _, _ in
                if configured, case .idle = state { generate(force: false) }
            }
            .sheet(isPresented: $showSettings) { ActivitySummarySettingsSheet() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .result(let result):
            resultView(result)
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在读取任务记录并生成 Recap…").foregroundStyle(WorkbenchTheme.quiet)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        case .failed(let error):
            if configured {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    Button("重试") { generate(force: true) }.buttonStyle(.bordered)
                }
            } else { configurationPrompt }
        case .idle:
            if configured {
                Button("生成 Recap") { generate(force: false) }.buttonStyle(.borderedProminent)
            } else { configurationPrompt }
        }
    }

    private var configurationPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recap 使用可选的外部摘要服务。配置前不会联网，也不会向原 Agent 发送消息。")
                .foregroundStyle(WorkbenchTheme.quiet)
            Button("配置活动叙事与 Recap…") { showSettings = true }.buttonStyle(.borderedProminent)
        }
    }

    private func resultView(_ result: TaskRecapResult) -> some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text(result.outcome).font(.system(size: WorkbenchTheme.Reading.labelSize, weight: .medium)).textSelection(.enabled)
                    recapSection("主要改动", items: result.changes)
                    recapSection("验证", items: result.validation)
                    recapSection("遗留", items: result.remaining)
                    recapSection("下一步", items: result.nextSteps)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(height: 360)
            Divider()
            HStack(spacing: 14) {
                Button(copied ? "已复制" : "复制") { copy(result) }.buttonStyle(.borderless)
                Spacer()
                if configured {
                    Button("重新生成") { generate(force: true) }.buttonStyle(.borderless)
                } else {
                    Button("配置后重新生成") { showSettings = true }.buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder private func recapSection(_ title: LocalizedStringKey, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.semibold)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("•").foregroundStyle(WorkbenchTheme.quiet)
                        Text(item).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func generate(force: Bool) {
        copied = false
        if let onGenerateOverride { onGenerateOverride(force); return }
        guard let messages else { return }
        store.generate(key: key, force: force, messages: messages, settings: settings)
    }

    private func copy(_ result: TaskRecapResult) {
        var blocks = [result.outcome]
        // The copied headings match the section titles shown above.
        for (title, items) in [(L("主要改动"), result.changes), (L("验证"), result.validation),
                               (L("遗留"), result.remaining), (L("下一步"), result.nextSteps)] where !items.isEmpty {
            blocks.append(title + "\n" + items.map { "- " + $0 }.joined(separator: "\n"))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copied = pasteboard.setString(blocks.joined(separator: "\n\n"), forType: .string)
    }
}

/// A turn's wall time with its breakdown, for the task panel's 本轮 section.
struct TurnTimingDetails: View {
    let timing: ConversationTiming
    @Environment(\.locale) private var locale
    var body: some View {
        Group {
            if let end = timing.endedAt { content(at: end) }
            else if AppPresentationActivity.shared.isActive {
                TimelineView(.periodic(from: timing.startedAt, by: 1)) { context in content(at: context.date) }
            } else { content(at: Date()) }
        }.monospacedDigit()
            .help(timing.observedOnly
                  ? Text("从客户端首次观察到本轮开始计时，包含等待；此前用时未知。")
                  : Text("从提交本轮请求到收到结束状态的经过时间，包含通信、工具调用和等待。"))
    }
    private func duration(_ value: TimeInterval) -> String {
        ConversationTiming.duration(value, chinese: locale.language.languageCode?.identifier == "zh")
    }
    private func content(at now: Date) -> some View {
        let total = timing.elapsed(at: now), waiting = timing.waiting(at: now)
        return VStack(alignment: .leading, spacing: 4) {
            label(duration(total))
            Text("处理与工具调用：\(duration(total - waiting))").foregroundStyle(WorkbenchTheme.quiet)
            Text("等待确认：\(duration(waiting))").foregroundStyle(WorkbenchTheme.quiet)
            Text("阶段时长按客户端收到的状态估算，包含通信与调度。")
                .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
        }
    }
    @ViewBuilder private func label(_ duration: String) -> some View {
        if timing.observedOnly {
            if timing.endedAt == nil { Text("已观察 \(duration)") }
            else { Text("观察时长 \(duration)") }
        } else if timing.endedAt == nil { Text("已用时 \(duration)") }
        else { Text("用时 \(duration)") }
    }
}

/// Only a running task needs a clock that redraws; a finished one is fixed.
/// Callers set its font and color.
struct KimiTaskClock: View {
    let task: KimiTask
    @Environment(\.locale) private var locale
    var body: some View {
        Group {
            if let started = task.startedDate {
                if let ended = task.completedDate {
                    Text(duration(ended.timeIntervalSince(started)))
                } else if AppPresentationActivity.shared.isActive {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(duration(context.date.timeIntervalSince(started)))
                    }
                } else { Text(duration(Date().timeIntervalSince(started))) }
            }
        }.monospacedDigit().fixedSize()
    }
    private func duration(_ interval: TimeInterval) -> String {
        ConversationTiming.duration(max(0, interval), chinese: locale.language.languageCode?.identifier == "zh")
    }
}
