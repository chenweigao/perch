import AppKit
import SwiftUI
import WorkbenchCore

/// AppKit animates the system spinner without invalidating the transcript graph.
struct ConversationBusyIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion { Image(systemName: "hourglass").font(.system(size: WorkbenchTheme.Reading.labelSize)).foregroundStyle(WorkbenchTheme.quiet) }
            else { BusySpinner() }
        }.frame(width: 16, height: 16).accessibilityHidden(true)
    }
}

private struct BusySpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let view = NSProgressIndicator()
        view.style = .spinning
        view.controlSize = .small
        view.isIndeterminate = true
        view.startAnimation(nil)
        return view
    }
    func updateNSView(_ view: NSProgressIndicator, context: Context) {}
    static func dismantleNSView(_ view: NSProgressIndicator, coordinator: ()) { view.stopAnimation(nil) }
}

/// Kept outside the transcript; only the clock subview refreshes every second.
/// Every state uses the same transparent row height, so a run starting, waiting
/// for input or failing never resizes the transcript above it. Attention adds
/// color and an explicit action instead of a filled strip.
struct ConversationActivityBar: View {
    static let height: CGFloat = 32
    let activity: ConversationActivity
    let isRunning: Bool
    var timing: ConversationTiming? = nil
    var online = true
    /// Last connection error; the details and the reconnect tooltip show it.
    var offlineDetail: String? = nil
    var pendingCount = 0
    var narrativeSession: String? = nil
    var narrativeOverride: ActivityNarrative? = nil
    var externalFailureOverride: String? = nil
    var recapKey: String? = nil
    var recapMessages: (@MainActor () async throws -> [KimiMessage])? = nil
    var recapStateOverride: TaskRecapState? = nil
    var recapConfiguredOverride: Bool? = nil
    var onRecapGenerateOverride: ((Bool) -> Void)? = nil
    var onReview: () -> Void = {}
    var onReconnect: () -> Void = {}
    var onRetryExternal: (() -> Void)? = nil
    /// The subagent roster and background task list: Kimi's, and the native
    /// roster of bridge protocol 7 (subagents only). Without either the
    /// sections stay hidden.
    var board: KimiTaskBoard = KimiTaskBoard()
    var loadingTaskOutput: Set<String> = []
    var stoppingTasks: Set<String> = []
    var taskListError: String? = nil
    var onTaskOutput: (KimiTask) -> Void = { _ in }
    var onTaskStop: (KimiTask) -> Void = { _ in }
    var onTasksRefresh: () -> Void = {}
    var onOpenTranscript: (KimiTask) -> Void = { _ in }
    /// Stops one subagent on its own, for rows marked stoppable. nil keeps the
    /// subagent rows read-only (Kimi: the conversation's Stop covers them).
    var onSubagentStop: ((KimiTask) -> Void)? = nil
    /// Why stopping a subagent failed, by task id.
    var taskStopErrors: [String: String] = [:]
    @UILocalization private var L
    @State private var expanded = false
    @State private var recapPresented = false
    @State private var pointerAnchor: CGRect?
    @ObservedObject var narrativeStore = ActivityNarrativeStore.shared
    @ObservedObject private var recapStore = TaskRecapStore.shared
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var narrative: ActivityNarrative? {
        narrativeOverride ?? narrativeSession.flatMap { narrativeStore.narrative(session: $0) }
    }
    private var externalFailure: String? {
        externalFailureOverride ?? narrativeSession.flatMap { narrativeStore.failure(session: $0)?.message }
    }
    private var canRetryExternal: Bool {
        if externalFailureOverride != nil { return onRetryExternal != nil }
        return narrativeSession.map { narrativeStore.canRetry(session: $0) } ?? false
    }
    private func retryExternal() {
        if let onRetryExternal { onRetryExternal() }
        else if let narrativeSession { narrativeStore.retry(session: narrativeSession, settings: summarySettings) }
    }

    /// A lost connection and a pending decision stop progress and own the tone.
    private var blocking: Bool { !online || pendingCount > 0 }
    /// `activity.title` carries untranslated keys; compare the key itself.
    private var stopping: Bool { activity.title == "Stopping…" }
    private var turnEnded: Bool {
        !isRunning && (timing?.endedAt != nil || narrative != nil || recapKey != nil || activity.edits != nil)
    }
    /// Uncertain tool results: failed without an exit code, missing, disconnected
    /// or unconfirmed. A running agent may still recover, so they add a count
    /// rather than recoloring the current action. Blocking states supersede them.
    private var reviewCount: Int { blocking ? 0 : activity.attentionTools.count }

    var body: some View {
        ZStack {
            if activity.isVisible || timing != nil || narrative != nil || !board.isEmpty || taskListError != nil || recapKey != nil || activity.edits != nil {
                HStack(spacing: 8) {
                    summaryButton
                    actions
                }.font(.system(size: WorkbenchTheme.Reading.labelSize))
                    .foregroundStyle(WorkbenchTheme.quiet)
                    .padding(.horizontal, 2).frame(height: Self.height)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: activity.isVisible)
        #if PERCH_ACCEPTANCE
        // The subagents fixture opens and closes the details popover without a pointer.
        .onReceive(NotificationCenter.default.publisher(for: .init("PerchAcceptanceActivityDetails"))) { notice in
            pointerAnchor = nil
            expanded = notice.object as? Bool ?? true
        }
        #endif
    }

    /// Priority from left to right: the current action, then elapsed time; plan
    /// steps, session edits and concurrency fold away first in a narrow window.
    /// The details popover always lists everything.
    private var summaryButton: some View {
        Button { pointerAnchor = nil; expanded.toggle() } label: {
            HStack(spacing: 8) {
                indicator
                titleRow.layoutPriority(1)
                if reviewCount > 0 {
                    Text("\(reviewCount) 项需关注").foregroundStyle(Color.orange).fixedSize()
                }
                // Lowest priority: the spacer takes only what the metrics leave.
                // Facts stay right-aligned, so a changing title never shifts them.
                Spacer(minLength: 6).layoutPriority(-2)
                // The zero-size last candidate always fits. EmptyView would add no
                // candidate, and ViewThatFits shows its last child when none fits.
                ViewThatFits(in: .horizontal) {
                    metrics(upTo: 3)
                    metrics(upTo: 2)
                    metrics(upTo: 1)
                    Color.clear.frame(width: 0, height: 0)
                }.font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(WorkbenchTheme.quiet).layoutPriority(-1)
                if let timing {
                    ActivityTurnClock(timing: timing).font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(WorkbenchTheme.quiet)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WorkbenchTheme.quiet).accessibilityHidden(true)
            }.padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
        }.buttonStyle(WorkbenchDisclosureButtonStyle())
            .accessibilityLabel(Text("本轮活动"))
            .accessibilityValue(Text(verbatim: accessibilityValue))
            .accessibilityHint(Text("查看本轮活动与计划"))
            .help("查看本轮活动与计划")
            .highPriorityGesture(SpatialTapGesture().onEnded { value in
                pointerAnchor = CGRect(x: value.location.x, y: value.location.y, width: 1, height: 1)
                expanded.toggle()
            })
            .popover(isPresented: $expanded,
                     attachmentAnchor: .rect(pointerAnchor.map { .rect($0) } ?? .bounds),
                     arrowEdge: .top) { details }
    }

    /// Only real execution hops the Perch sun; every other state names itself with a symbol.
    @ViewBuilder private var indicator: some View {
        if activity.animates { PerchBusyIndicator() }
        else {
            Image(systemName: symbol).font(.system(size: WorkbenchTheme.Reading.labelSize)).frame(width: 16, height: 16)
                .foregroundStyle(blocking || (reviewCount > 0 && !isRunning) ? Color.orange : WorkbenchTheme.quiet)
                .accessibilityHidden(true)
        }
    }
    private var symbol: String {
        if blocking || stopping { return activity.symbol }
        if turnEnded { return reviewCount > 0 ? "exclamationmark.circle" : "checkmark.circle" }
        return activity.symbol
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(verbatim: title).fontWeight(blocking ? .medium : .regular)
                .foregroundStyle(blocking ? Color.orange : WorkbenchTheme.quiet)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if let target = actionTarget {
                Text(verbatim: target).foregroundStyle(WorkbenchTheme.quiet)
                    .lineLimit(1).truncationMode(.middle)
            }
        }.contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: title)
    }

    /// One localized title for the row, the details fallback and VoiceOver.
    private var title: String {
        if !online { return L(key: activity.title) }
        if pendingCount > 0 { return L("等待你确认 · \(pendingCount) 项") }
        if stopping { return L(key: activity.title) }
        if turnEnded { return L("本轮结束") }
        // Long assistant progress can contain a whole Markdown reply. Keep it
        // in the details instead of duplicating the transcript in this one line.
        if isRunning, let narrative, narrative.headline.count <= 48 { return narrative.headline }
        if let description = activity.operationDescription { return description }
        return L(key: activity.title)
    }

    /// A generic running title names what the current tool touches, so the
    /// action stays understandable without opening the details.
    private var actionTarget: String? {
        guard online, isRunning, pendingCount == 0, !stopping, narrative == nil,
              activity.operationDescription == nil, let tool = activity.activeTools.first else { return nil }
        let target = ToolPresentation.compactTarget(tool)
        return target.isEmpty || target == tool.name ? nil : target
    }

    private var accessibilityValue: String {
        var parts = [title]
        if let actionTarget { parts.append(actionTarget) }
        if reviewCount > 0 { parts.append(L("\(reviewCount) 项需关注")) }
        if !activity.todos.isEmpty { parts.append(L("\(activity.completedSteps)/\(activity.todos.count) 步")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var actions: some View {
        if let recapKey, !isRunning, pendingCount == 0 {
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
        if !online {
            Button("重新连接", action: onReconnect).buttonStyle(.bordered).controlSize(.small).tint(.orange)
                .help(offlineDetail.map { Text(verbatim: $0) } ?? Text("重新连接"))
        } else if pendingCount > 0 {
            Button("查看") { onReview() }.buttonStyle(.bordered).controlSize(.small).tint(.orange)
                .help("查看等待你确认的事项").accessibilityHint(Text("查看等待你确认的事项"))
        } else if reviewCount > 0 && !isRunning {
            Button("查看") { pointerAnchor = nil; expanded = true }
                .buttonStyle(.bordered).controlSize(.small).tint(.orange)
                .help("查看需要关注的工具结果").accessibilityHint(Text("查看需要关注的工具结果"))
        }
    }

    /// Facts in fold order: plan steps, then session edits, then concurrency.
    private func metrics(upTo level: Int) -> some View {
        HStack(spacing: 10) {
            if level >= 1, !activity.todos.isEmpty {
                Text("\(activity.completedSteps)/\(activity.todos.count) 步")
            }
            if level >= 2, let edits = activity.edits {
                // Odometer roll as the tally grows (ccgui RollingStat) —
                // SwiftUI's numericText transition is the native equivalent.
                EditStatText(stat: edits.total)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: edits.total)
            }
            if level >= 3 {
                // One running tool is already named by the title.
                if activity.activeTools.count > 1 { Text("\(activity.activeTools.count) 个工具") }
                if board.runningCount > 0 { Text("\(board.runningCount) 运行中") }
            }
        }.fixedSize().monospacedDigit()
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("本轮活动", systemImage: "list.bullet.rectangle").font(.system(size: WorkbenchTheme.Reading.secondarySize, weight: .semibold))
                Spacer()
                Button { expanded = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("关闭活动详情").accessibilityLabel(Text("关闭活动详情"))
            }
            if !online {
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接已断开，以下为最后收到的工具状态。").foregroundStyle(WorkbenchTheme.quiet)
                    if let offlineDetail, !offlineDetail.isEmpty {
                        Text(verbatim: offlineDetail).font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(WorkbenchTheme.quiet)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("重新连接") { expanded = false; onReconnect() }.buttonStyle(.bordered).tint(.orange)
            } else if pendingCount > 0 {
                Label { Text("等待你确认 · \(pendingCount) 项") } icon: { Image(systemName: "hand.raised") }
                    .foregroundStyle(.orange)
                Button("查看") { expanded = false; onReview() }.buttonStyle(.bordered).tint(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let narrative {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(narrative.headline).font(.system(size: WorkbenchTheme.Reading.secondarySize, weight: .semibold)).textSelection(.enabled)
                            if let detail = narrative.detail, !detail.isEmpty {
                                Text(detail).foregroundStyle(WorkbenchTheme.quiet).textSelection(.enabled)
                            }
                            Text("\(narrative.phase.label) · \(narrative.source.label) · \(narrative.lifecycle == .streaming ? L("正在更新") : L("阶段已完成"))")
                                .font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(WorkbenchTheme.quiet)
                            let evidence = narrative.evidenceIDs.compactMap { id in activity.tools.first { $0.id == id } }
                            if !evidence.isEmpty {
                                Text("依据").font(.system(size: WorkbenchTheme.Reading.captionSize, weight: .semibold)).foregroundStyle(WorkbenchTheme.quiet)
                                ForEach(evidence) { tool in
                                    Text("• \(ToolPresentation.action(tool.name)) \(ToolPresentation.compactTarget(tool))")
                                        .font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(WorkbenchTheme.quiet).lineLimit(1)
                                }
                            }
                        }
                    }
                    if !activity.attentionTools.isEmpty {
                        Text("需要处理").fontWeight(.semibold).foregroundStyle(.orange)
                        ForEach(activity.attentionTools) { tool in ActivityToolDetails(tool: tool) }
                    }
                    if !activity.activeTools.isEmpty {
                        Text("当前操作").fontWeight(.semibold)
                        ForEach(activity.activeTools) { tool in ActivityToolDetails(tool: tool) }
                    } else if narrative == nil && online && pendingCount == 0 && activity.attentionTools.isEmpty {
                        Text(verbatim: title).foregroundStyle(WorkbenchTheme.quiet)
                    }
                    if !activity.todos.isEmpty {
                        HStack {
                            Text("任务计划").fontWeight(.semibold)
                            Spacer()
                            Text("\(activity.completedSteps)/\(activity.todos.count)").monospacedDigit().foregroundStyle(WorkbenchTheme.quiet)
                        }
                        ForEach(activity.todos) { item in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: item.status == .done ? "checkmark.circle.fill" : item.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                                    .foregroundStyle(item.status == .inProgress ? WorkbenchTheme.accent : WorkbenchTheme.quiet)
                                Text(item.title).fontWeight(item.status == .inProgress ? .medium : .regular)
                                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                            }.accessibilityElement(children: .combine)
                                .accessibilityLabel(Text(verbatim: "\(todoState(item.status)): \(item.title)"))
                        }
                    }
                    if let edits = activity.edits {
                        HStack {
                            Text("编辑文件").fontWeight(.semibold)
                            Spacer()
                            EditStatText(stat: edits.total)
                        }
                        ForEach(edits.perFile.keys.sorted(), id: \.self) { path in
                            HStack {
                                Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                EditStatText(stat: edits.perFile[path]!)
                            }.help(path)
                        }
                    }
                    KimiTaskSections(board: board, loadingOutput: loadingTaskOutput, stopping: stoppingTasks,
                                     listError: taskListError, onLoadOutput: onTaskOutput,
                                     onStop: onTaskStop, onRefresh: onTasksRefresh,
                                     onOpenTranscript: onOpenTranscript,
                                     onSubagentStop: onSubagentStop, stopErrors: taskStopErrors)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(maxHeight: 300)
            if let externalFailure {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("外部摘要更新失败：\(externalFailure)").foregroundStyle(.orange).textSelection(.enabled)
                    if canRetryExternal {
                        Button("重试外部摘要", action: retryExternal).buttonStyle(.borderless)
                    }
                }
            }
            if let timing {
                Divider()
                ActivityTurnClock(timing: timing, showsDetails: true)
            }
        }.font(.system(size: WorkbenchTheme.Reading.labelSize)).padding(16).frame(width: 390)
    }
    private func todoState(_ status: ConversationTodo.Status) -> String {
        switch status {
        case .done: return L("Completed")
        case .inProgress: return L("In progress")
        case .pending: return L("Pending")
        }
    }
}

/// +/− tally in the quiet palette; shared by the bar pill and the per-file rows.
private struct EditStatText: View {
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

private struct ActivityTurnClock: View {
    let timing: ConversationTiming
    var showsDetails = false
    @Environment(\.locale) private var locale
    var body: some View {
        Group {
            if let end = timing.endedAt { content(at: end) }
            else {
                TimelineView(.periodic(from: timing.startedAt, by: 1)) { context in content(at: context.date) }
            }
        }.monospacedDigit()
            .help(timing.observedOnly
                  ? Text("从客户端首次观察到本轮开始计时，包含等待；此前用时未知。")
                  : Text("从提交本轮请求到收到结束状态的经过时间，包含通信、工具调用和等待。"))
    }
    private func duration(_ value: TimeInterval) -> String {
        ConversationTiming.duration(value, chinese: locale.language.languageCode?.identifier == "zh")
    }
    @ViewBuilder private func content(at now: Date) -> some View {
        let total = timing.elapsed(at: now)
        if showsDetails {
            VStack(alignment: .leading, spacing: 6) {
                label(duration(total))
                Text("处理与工具调用：\(duration(total - timing.waiting(at: now)))")
                Text("等待确认：\(duration(timing.waiting(at: now)))")
                Text("阶段时长按客户端收到的状态估算，包含通信与调度。")
                    .font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(WorkbenchTheme.quiet)
            }
        } else { label(duration(total)).fixedSize() }
    }
    @ViewBuilder private func label(_ duration: String) -> some View {
        if timing.observedOnly {
            if timing.endedAt == nil { Text("已观察 \(duration)") }
            else { Text("观察时长 \(duration)") }
        } else if timing.endedAt == nil { Text("已用时 \(duration)") }
        else { Text("用时 \(duration)") }
    }
}

private struct ActivityToolDetails: View {
    let tool: VisibleTool
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = tool.input { Text("Input").fontWeight(.medium); Text(input.display).textSelection(.enabled) }
                    if let progress = tool.progress { Text("Latest update").fontWeight(.medium); Text(progress.display).textSelection(.enabled) }
                    if let output = tool.output { Text("Result").fontWeight(.medium); Text(output.display).textSelection(.enabled) }
                }.font(.system(size: WorkbenchTheme.Reading.captionSize, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(tool.name).fontWeight(.medium)
                    Spacer()
                    Text(verbatim: ConversationActivity.status(of: tool))
                        .foregroundStyle(tool.staysVisible && tool.status != .running ? Color.orange : WorkbenchTheme.quiet)
                }
                let summary = ConversationActivity.summary(of: tool)
                if summary != tool.name { Text(summary).lineLimit(2).foregroundStyle(WorkbenchTheme.quiet) }
                if let progress = tool.progress { Text(progress.display).lineLimit(2).foregroundStyle(WorkbenchTheme.quiet) }
            }
        }.disclosureGroupStyle(WorkbenchDisclosureStyle())
    }
}

/// Subagent roster and background tasks of the selected session, inside the
/// activity popover. Presentation plus the two actions the task API offers:
/// reading an output tail and stopping one task.
struct KimiTaskSections: View {
    let board: KimiTaskBoard
    var loadingOutput: Set<String> = []
    var stopping: Set<String> = []
    var listError: String? = nil
    var onLoadOutput: (KimiTask) -> Void = { _ in }
    var onStop: (KimiTask) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onOpenTranscript: (KimiTask) -> Void = { _ in }
    /// Stops one subagent row on its own; nil leaves the roster read-only.
    var onSubagentStop: ((KimiTask) -> Void)? = nil
    var stopErrors: [String: String] = [:]

    var body: some View {
        let backgroundTasks = board.backgroundTasks
        LazyVStack(alignment: .leading, spacing: 14) {
            if !board.subagents.isEmpty {
                section("子 Agent", tasks: board.subagents, readsOutput: false)
            }
            if !backgroundTasks.isEmpty {
                section("后台任务", tasks: backgroundTasks, readsOutput: true)
            }
            if let listError {
                VStack(alignment: .leading, spacing: 5) {
                    Text(listError).foregroundStyle(.orange).textSelection(.enabled)
                    Button("重试读取任务") { onRefresh() }.buttonStyle(.borderless)
                }
            }
        }
        #if PERCH_ACCEPTANCE
        .background(NativeSubagentRosterProbe(rows: board.subagents.map {
            "\($0.id)|\($0.status)|\($0.stoppable == true)|\(stopping.contains($0.id))"
        }))
        #endif
    }

    private func section(_ title: LocalizedStringKey, tasks: [KimiTask], readsOutput: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                let running = tasks.filter(\.isRunning).count
                if running > 0 { Text("\(running) 运行中").monospacedDigit().foregroundStyle(WorkbenchTheme.quiet) }
                if readsOutput {
                    Button { onRefresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).accessibilityLabel(Text("刷新后台任务"))
                        .help("重新读取后台任务列表")
                }
            }
            ForEach(tasks) { task in
                KimiTaskRow(task: task, output: board.output(of: task),
                            isLoadingOutput: loadingOutput.contains(task.id),
                            isStopping: stopping.contains(task.id), readsOutput: readsOutput,
                            onLoadOutput: { onLoadOutput(task) }, onStop: { onStop(task) },
                            onOpenTranscript: { onOpenTranscript(task) },
                            onSubagentStop: subagentStop(task, readsOutput: readsOutput),
                            stopError: readsOutput ? nil : stopErrors[task.id])
            }
        }
    }

    /// Only roster rows the runtime marks stoppable stop on their own.
    private func subagentStop(_ task: KimiTask, readsOutput: Bool) -> (() -> Void)? {
        guard !readsOutput, task.stoppable == true, let onSubagentStop else { return nil }
        return { onSubagentStop(task) }
    }
}

private struct KimiTaskRow: View {
    let task: KimiTask
    let output: String?
    let isLoadingOutput: Bool
    let isStopping: Bool
    /// Only the persisted list has an output tail to read and a task to stop. A
    /// foreground child belongs to the running turn, which Stop already covers.
    let readsOutput: Bool
    var onLoadOutput: () -> Void = {}
    var onStop: () -> Void = {}
    var onOpenTranscript: () -> Void = {}
    /// A native roster row the bridge can stop on its own; the main turn keeps running.
    var onSubagentStop: (() -> Void)? = nil
    var stopError: String? = nil
    @State private var expanded = false
    @UILocalization private var L

    private var symbol: String {
        switch task.subagentPhase {
        case "queued": return "clock"
        case "suspended": return "pause.circle"
        default: break
        }
        switch task.status {
        case "running": return "circle.dotted"
        case "completed": return "checkmark"
        case "failed": return "exclamationmark.circle"
        case "cancelled": return "xmark.circle"
        default: return "questionmark.circle"
        }
    }
    private var attention: Bool { task.isFailed || task.subagentPhase == "suspended" }
    private var tint: Color { attention ? .orange : .secondary }
    /// The background list mixes processes, detached children and question
    /// tasks. The roster section holds subagents only, so its rows name the
    /// subagent type instead of the kind.
    private var chip: String? {
        guard readsOutput else { return task.subagentType }
        return task.subagentType ?? task.kindLabel
    }

    /// Tokens, tool calls and the latest tool of a native roster entry; nil for
    /// Kimi records, which report none of them.
    private var usage: String? {
        var parts: [String] = []
        if let tokens = task.tokenCount { parts.append(L("已用 \(tokens) Token")) }
        if let calls = task.toolUseCount { parts.append(L("\(calls) 次调用")) }
        if let tool = task.latestActivity { parts.append(L("最近工具：\(tool)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        let usageLine = usage
        DisclosureGroup(isExpanded: $expanded) {
            if expanded { details }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(tint).accessibilityHidden(true)
                    Text(task.description).lineLimit(1).truncationMode(.middle)
                    if let chip, chip != task.description {
                        Text(LocalizedStringKey(chip)).font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(WorkbenchTheme.quiet).fixedSize()
                    }
                    Spacer(minLength: 4)
                    KimiTaskClock(task: task).font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(.tertiary)
                    Text(task.phaseLabel).foregroundStyle(tint).fixedSize()
                }
                if let usageLine {
                    // Under the description, past the status symbol's column.
                    Text(verbatim: usageLine).font(.system(size: WorkbenchTheme.Reading.captionSize)).foregroundStyle(WorkbenchTheme.quiet)
                        .lineLimit(1).truncationMode(.tail).padding(.leading, 19)
                }
            }.font(.system(size: WorkbenchTheme.Reading.labelSize)).foregroundStyle(WorkbenchTheme.quiet)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: ["\(task.kindLabel) \(task.description) \(task.phaseLabel)", usageLine]
                    .compactMap { $0 }.joined(separator: ", ")))
                .help(Text(verbatim: [task.command, task.model, task.id].compactMap { $0 }.joined(separator: "\n")))
        }.disclosureGroupStyle(WorkbenchDisclosureStyle())
            .onChange(of: expanded) { _, value in
                if value && readsOutput && output == nil { onLoadOutput() }
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                meta("状态", task.statusLabel)
                if let model = task.model {
                    meta("模型", task.thinkingEffort.map { "\(model) · \($0)" } ?? model)
                }
                if let type = task.subagentType { meta("子 Agent 类型", type) }
                if let command = task.command { meta("命令", command) }
                if let index = task.swarmIndex { meta("并行序号", String(index)) }
                if let reason = task.suspendedReason { meta("暂停原因", reason) }
                meta("任务 ID", task.id)
            }.font(.system(size: WorkbenchTheme.Reading.captionSize))
            let stopsAlone = onSubagentStop != nil && task.isRunning
            if task.transcriptAgentId != nil || stopsAlone {
                HStack(spacing: 14) {
                    if task.transcriptAgentId != nil {
                        Button("查看过程") { onOpenTranscript() }.buttonStyle(.borderless)
                            .help("读取这个子 Agent 自己的轮次、思考与工具调用")
                    }
                    if stopsAlone {
                        // Stays 停止中 until the roster shows an outcome.
                        Button { onSubagentStop?() } label: {
                            if isStopping { Text("停止中") } else { Text("停止") }
                        }.buttonStyle(.borderless).disabled(isStopping)
                            .help("只停止这个子 Agent，主会话继续运行")
                    }
                }
            }
            if let stopError, task.isRunning {
                Text(L("单独停止失败：\(stopError)。可以停止整轮。"))
                    .foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if readsOutput || output != nil {
                Text("输出").fontWeight(.medium).foregroundStyle(WorkbenchTheme.quiet)
                if isLoadingOutput {
                    ProgressView().controlSize(.small)
                } else if let output, !output.isEmpty {
                    ScrollView {
                        Text(output).font(.system(size: WorkbenchTheme.Reading.captionSize, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }.frame(maxHeight: 220)
                } else {
                    Text("暂无输出").foregroundStyle(WorkbenchTheme.quiet)
                }
                if readsOutput && task.isRunning {
                    HStack(spacing: 14) {
                        Button("刷新输出") { onLoadOutput() }.buttonStyle(.borderless).disabled(isLoadingOutput)
                        Button { onStop() } label: {
                            if isStopping { Text("正在停止…") } else { Text("停止任务") }
                        }.buttonStyle(.borderless).disabled(isStopping)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(WorkbenchTheme.Fill.surface,
                        in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
            .padding(.leading, 10).padding(.top, 5)
    }

    private func meta(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(WorkbenchTheme.quiet).frame(width: 84, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
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
                } else {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(duration(context.date.timeIntervalSince(started)))
                    }
                }
            }
        }.monospacedDigit().fixedSize()
    }
    private func duration(_ interval: TimeInterval) -> String {
        ConversationTiming.duration(max(0, interval), chinese: locale.language.languageCode?.identifier == "zh")
    }
}
