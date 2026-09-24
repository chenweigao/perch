import AppKit
import SwiftUI
import WorkbenchCore

/// AppKit animates the system spinner without invalidating the transcript graph.
struct ConversationBusyIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion { Image(systemName: "hourglass").font(.system(size: 12)).foregroundStyle(.secondary) }
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
struct ConversationActivityBar: View {
    let activity: ConversationActivity
    let isRunning: Bool
    var timing: ConversationTiming? = nil
    var online = true
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
    /// Kimi's subagent roster and background task list. Other runtimes report
    /// neither yet, so the sections stay hidden for them.
    var board: KimiTaskBoard = KimiTaskBoard()
    var loadingTaskOutput: Set<String> = []
    var stoppingTasks: Set<String> = []
    var taskListError: String? = nil
    var onTaskOutput: (KimiTask) -> Void = { _ in }
    var onTaskStop: (KimiTask) -> Void = { _ in }
    var onTasksRefresh: () -> Void = {}
    var onOpenTranscript: (KimiTask) -> Void = { _ in }
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

    var body: some View {
        ZStack {
            if activity.isVisible || timing != nil || narrative != nil || !board.isEmpty || taskListError != nil || recapKey != nil {
                HStack(spacing: 10) {
                    Button { pointerAnchor = nil; expanded.toggle() } label: {
                        HStack(spacing: 9) {
                            if activity.animates { ConversationBusyIndicator() }
                            else {
                                Image(systemName: activity.symbol).frame(width: 16)
                                    .foregroundStyle(activity.needsAttention ? Color.orange : Color.secondary)
                            }
                            statusTitle
                                .foregroundStyle(activity.needsAttention ? Color.orange : Color.secondary)
                                .lineLimit(1).truncationMode(.tail)
                                .contentTransition(.opacity)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: activity.title)
                            Spacer(minLength: 4)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) { counts; clock }
                                counts
                                EmptyView()
                            }.font(.system(size: 11)).foregroundStyle(.secondary).layoutPriority(-1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }.frame(minHeight: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(Text("本轮活动"))
                        .accessibilityValue(statusTitle).help("查看本轮活动与计划")
                        .highPriorityGesture(SpatialTapGesture().onEnded { value in
                            pointerAnchor = CGRect(x: value.location.x, y: value.location.y, width: 1, height: 1)
                            expanded.toggle()
                        })
                        .popover(isPresented: $expanded,
                                 attachmentAnchor: .rect(pointerAnchor.map { .rect($0) } ?? .bounds),
                                 arrowEdge: .top) { details }
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
                        Button("重新连接", action: onReconnect).buttonStyle(.borderless)
                    } else if pendingCount > 0 {
                        Button("查看") { onReview() }.buttonStyle(.bordered).controlSize(.small).tint(.orange)
                    }
                }.font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(height: activity.needsAttention ? 36 : 28)
                    .background {
                        if activity.needsAttention {
                            RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08))
                        }
                    }
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: activity.isVisible)
    }

    private var statusTitle: Text {
        if !online { return Text(LocalizedStringKey(activity.title)) }
        if pendingCount > 0 { return Text("等待你确认 · \(pendingCount) 项") }
        if !isRunning && (timing?.endedAt != nil || narrative != nil || recapKey != nil) { return Text("本轮结束") }
        if activity.needsAttention || activity.title == L("Stopping…") { return Text(LocalizedStringKey(activity.title)) }
        if isRunning, let narrative { return Text(verbatim: narrative.headline) }
        if let description = activity.operationDescription { return Text(verbatim: description) }
        return Text(LocalizedStringKey(activity.title))
    }

    @ViewBuilder private var counts: some View {
        HStack(spacing: 10) {
            if !activity.todos.isEmpty { Text("\(activity.completedSteps)/\(activity.todos.count) steps") }
            if !activity.activeTools.isEmpty { Text("\(activity.activeTools.count) \(activity.activeTools.count == 1 ? "tool" : "tools")") }
            if board.runningCount > 0 { Text("\(board.runningCount) 运行中") }
        }.fixedSize().monospacedDigit()
    }
    @ViewBuilder private var clock: some View {
        if let timing { ActivityTurnClock(timing: timing) }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("本轮活动", systemImage: "list.bullet.rectangle").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { expanded = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(Text("关闭活动详情"))
            }
            if !online {
                Text("连接已断开，以下为最后收到的工具状态。").foregroundStyle(.secondary)
                Button("重新连接") { expanded = false; onReconnect() }
            } else if pendingCount > 0 {
                Label { Text("等待你确认 · \(pendingCount) 项") } icon: { Image(systemName: "hand.raised") }
                    .foregroundStyle(.orange)
                Button("查看") { expanded = false; onReview() }.buttonStyle(.bordered).tint(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let narrative {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(narrative.headline).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                            if let detail = narrative.detail, !detail.isEmpty {
                                Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text("\(narrative.phase.label) · \(narrative.source.label) · \(narrative.lifecycle == .streaming ? L("正在更新") : L("阶段已完成"))")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                            let evidence = narrative.evidenceIDs.compactMap { id in activity.tools.first { $0.id == id } }
                            if !evidence.isEmpty {
                                Text("依据").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                ForEach(evidence) { tool in
                                    Text("• \(ToolPresentation.action(tool.name)) \(ToolPresentation.compactTarget(tool))")
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
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
                        statusTitle.foregroundStyle(.secondary)
                    }
                    if !activity.todos.isEmpty {
                        HStack {
                            Text("任务计划").fontWeight(.semibold)
                            Spacer()
                            Text("\(activity.completedSteps)/\(activity.todos.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        ForEach(activity.todos) { item in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: item.status == .done ? "checkmark.circle.fill" : item.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                                    .foregroundStyle(item.status == .inProgress ? Color.accentColor : Color.secondary)
                                Text(item.title).fontWeight(item.status == .inProgress ? .medium : .regular)
                                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                            }.accessibilityElement(children: .combine)
                                .accessibilityLabel("\(item.status == .done ? "Completed" : item.status == .inProgress ? "In progress" : "Pending"): \(item.title)")
                        }
                    }
                    KimiTaskSections(board: board, loadingOutput: loadingTaskOutput, stopping: stoppingTasks,
                                     listError: taskListError, onLoadOutput: onTaskOutput,
                                     onStop: onTaskStop, onRefresh: onTasksRefresh,
                                     onOpenTranscript: onOpenTranscript)
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
        }.font(.system(size: 12)).padding(16).frame(width: 390)
    }
}

private struct TaskRecapPopover: View {
    let key: String
    let messages: (@MainActor () async throws -> [KimiMessage])?
    let stateOverride: TaskRecapState?
    let configuredOverride: Bool?
    let onGenerateOverride: ((Bool) -> Void)?
    @ObservedObject private var store = TaskRecapStore.shared
    @ObservedObject private var settings = ActivitySummarySettings.shared
    @State private var showSettings = false
    @State private var copied = false

    private var state: TaskRecapState { stateOverride ?? store.state(for: key) }
    private var configured: Bool {
        configuredOverride ?? (settings.configuration.enabled && settings.configuration.isValid)
    }
    private var warning: String? { stateOverride == nil ? store.warning(for: key) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Task Recap", systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
                Spacer()
                if configured {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).accessibilityLabel(Text("配置 Recap 服务"))
                }
            }
            content
            if let warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.font(.system(size: 12)).padding(16).frame(width: 420)
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
                Text("正在读取任务记录并生成 Recap…").foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            Button("配置活动叙事与 Recap…") { showSettings = true }.buttonStyle(.borderedProminent)
        }
    }

    private func resultView(_ result: TaskRecapResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text(result.outcome).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                recapSection("主要改动", items: result.changes)
                recapSection("验证", items: result.validation)
                recapSection("遗留", items: result.remaining)
                recapSection("下一步", items: result.nextSteps)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
        }.frame(maxHeight: 360)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 14) {
                    Button(copied ? "已复制" : "复制") { copy(result) }.buttonStyle(.borderless)
                    Spacer()
                    if configured {
                        Button("重新生成") { generate(force: true) }.buttonStyle(.borderless)
                    } else {
                        Button("配置后重新生成") { showSettings = true }.buttonStyle(.borderless)
                    }
                }.padding(.top, 8).background(.background)
            }
    }

    @ViewBuilder private func recapSection(_ title: LocalizedStringKey, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.semibold)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
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
        for (title, items) in [("主要改动", result.changes), ("验证", result.validation),
                               ("遗留", result.remaining), ("下一步", result.nextSteps)] where !items.isEmpty {
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
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
                }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(tool.name).fontWeight(.medium)
                    Spacer()
                    Text(tool.hasCall ? ConversationActivity.status(of: tool) : "Call record missing")
                        .foregroundStyle(tool.staysVisible && tool.status != .running ? Color.orange : Color.secondary)
                }
                let summary = ConversationActivity.summary(of: tool)
                if summary != tool.name { Text(summary).lineLimit(2).foregroundStyle(.secondary) }
                if let progress = tool.progress { Text(progress.display).lineLimit(2).foregroundStyle(.secondary) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !board.subagents.isEmpty {
                section("子 Agent", tasks: board.subagents, readsOutput: false)
            }
            if !board.backgroundTasks.isEmpty {
                section("后台任务", tasks: board.backgroundTasks, readsOutput: true)
            }
            if let listError {
                VStack(alignment: .leading, spacing: 5) {
                    Text(listError).foregroundStyle(.orange).textSelection(.enabled)
                    Button("重试读取任务") { onRefresh() }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, tasks: [KimiTask], readsOutput: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                let running = tasks.filter(\.isRunning).count
                if running > 0 { Text("\(running) 运行中").monospacedDigit().foregroundStyle(.secondary) }
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
                            onOpenTranscript: { onOpenTranscript(task) })
            }
        }
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
    @State private var expanded = false

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

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded { details }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint).accessibilityHidden(true)
                Text(task.description).lineLimit(1).truncationMode(.middle)
                if let chip, chip != task.description {
                    Text(LocalizedStringKey(chip)).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize()
                }
                Spacer(minLength: 4)
                KimiTaskClock(task: task)
                Text(task.phaseLabel).foregroundStyle(tint).fixedSize()
            }.font(.system(size: 12)).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "\(task.kindLabel) \(task.description) \(task.phaseLabel)"))
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
            }.font(.system(size: 11))
            if task.transcriptAgentId != nil {
                Button("查看过程") { onOpenTranscript() }.buttonStyle(.borderless)
                    .help("读取这个子 Agent 自己的轮次、思考与工具调用")
            }
            if readsOutput || output != nil {
                Text("输出").fontWeight(.medium).foregroundStyle(.secondary)
                if isLoadingOutput {
                    ProgressView().controlSize(.small)
                } else if let output, !output.isEmpty {
                    ScrollView {
                        Text(output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }.frame(maxHeight: 220)
                } else {
                    Text("暂无输出").foregroundStyle(.tertiary)
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
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            .padding(.leading, 10).padding(.top, 5)
    }

    private func meta(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(.tertiary).frame(width: 84, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Only a running task needs a clock that redraws; a finished one is fixed.
private struct KimiTaskClock: View {
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
        }.font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
    }
    private func duration(_ interval: TimeInterval) -> String {
        ConversationTiming.duration(max(0, interval), chinese: locale.language.languageCode?.identifier == "zh")
    }
}
