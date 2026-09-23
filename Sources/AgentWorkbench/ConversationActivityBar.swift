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
    var onReview: () -> Void = {}
    var onReconnect: () -> Void = {}
    var onRetryExternal: (() -> Void)? = nil
    @State private var expanded = false
    @State private var pointerAnchor: CGRect?
    @ObservedObject private var narrativeStore = ActivityNarrativeStore.shared
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
            if activity.isVisible || timing != nil || narrative != nil {
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
        if activity.needsAttention || activity.title == L("Stopping…") { return Text(LocalizedStringKey(activity.title)) }
        if let narrative { return Text(verbatim: narrative.headline) }
        if !isRunning && timing?.endedAt != nil { return Text("本轮结束") }
        if let description = activity.operationDescription { return Text(verbatim: description) }
        return Text(LocalizedStringKey(activity.title))
    }

    @ViewBuilder private var counts: some View {
        HStack(spacing: 10) {
            if !activity.todos.isEmpty { Text("\(activity.completedSteps)/\(activity.todos.count) steps") }
            if !activity.activeTools.isEmpty { Text("\(activity.activeTools.count) \(activity.activeTools.count == 1 ? "tool" : "tools")") }
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
