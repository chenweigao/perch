import SwiftUI
import WorkbenchCore

/// Home offers a bounded overview; the inbox shows every actionable session.
/// Both use the same projection and rows, without maintaining a second inbox state.
struct WorkbenchDashboard<RowActions: View>: View {
    var attentionOnly = false
    var changes: [WorkspaceSession] = []
    var onAcknowledgeChanges: (() -> Void)? = nil
    var onSuggestGroups: (() -> Void)? = nil
    @State private var queueOrder = ActionQueueOrder()
    let projection: DashboardProjection
    var context = DashboardContext()
    var group: WorkItemGroup? = nil
    var hasSessionSearch = false
    var onClearSessionFilters: (() -> Void)? = nil
    var groupHeader: AnyView = AnyView(EmptyView())
    var groupOverview: AnyView = AnyView(EmptyView())
    var groupProgress: AnyView = AnyView(EmptyView())
    var groupHistory: AnyView = AnyView(EmptyView())
    let isArchiving: Bool
    let archiveResult: BatchArchiveRun?
    let onNewTask: () -> Void
    let onOpen: (WorkspaceSession) -> Void
    let onMarkReviewed: (WorkspaceSession) -> Void
    let rowActions: (WorkspaceSession) -> RowActions
    /// The caller builds the membership index once per view pass.
    let groupMemberships: (WorkspaceSession) -> [SessionGroupIndex.Membership]
    let onOpenGroup: (UUID) -> Void
    let onManageGroups: (WorkspaceSession) -> Void
    let onForgetRestoration: (SavedTerminal) -> Void
    var onDismissRestoreReport: (() -> Void)? = nil
    var onOpenRestoreEntry: ((RestoredSession) -> Void)? = nil
    let onUndoArchive: () -> Void
    let onRetryArchive: () -> Void
    let onStartLocal: () -> Void
    let onConnectRemote: () -> Void
    let onShowInbox: () -> Void
    let onShowAll: () -> Void
    let onShowHome: () -> Void
    let onClearScope: (ActiveScope.Facet) -> Void
    let onClearAllScopes: () -> Void

    var body: some View {
        ScrollView {
            // Sections already lay out their rows eagerly. Lazy placement of
            // these variable-height groups can loop when catalog updates move
            // rows between sections while scrolled (also in the full inbox).
            VStack(alignment: .leading, spacing: 28) {
                if let error = context.storageError { storageBanner(error) }
                introduction
                if attentionOnly {
                    if projection.attention.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light))
                                .foregroundStyle(.green)
                            Text("全部处理完了").font(.system(size: 15, weight: .medium))
                            Text("没有等待确认、回答或处理的事项；查看结果请到工作台。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("返回工作台", action: onShowHome).padding(.top, 4)
                        }.frame(maxWidth: .infinity).padding(.vertical, 56)
                    } else {
                        let byID = Dictionary(uniqueKeysWithValues: projection.attention.items.map { ($0.id, $0) })
                        let ordered = queueOrder.ids.compactMap { byID[$0] }
                        section(DashboardSection(section: .attention, items: ordered), limit: ordered.count)
                    }
                } else {
                    groupHeader
                    if let empty = projection.emptyState, empty != .nothingPending,
                       group == nil || hasSessionSearch || context.scope.facets.contains(where: { $0.kind == .host }) { emptyState(empty) }
                    if !projection.attention.isEmpty { section(projection.attention, limit: 3) }
                    groupOverview
                    if group == nil, let onSuggestGroups { Button("Agent 帮我归组", action: onSuggestGroups).buttonStyle(QuietLinkStyle()) }
                    if !changes.isEmpty { changeSummary }
                    groupProgress
                    if !projection.review.isEmpty { section(projection.review, limit: 5) }
                    if !projection.running.isEmpty { section(projection.running, limit: 5) }
                    if !projection.recent.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("最近会话").accessibilityAddTraits(.isHeader)
                                Spacer()
                                if group == nil { Button("查看全部", action: onShowAll).buttonStyle(QuietLinkStyle()) }
                            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
                            ForEach(projection.recent) { row($0, in: .other) }
                            if group != nil && projection.other.count > projection.recent.count {
                                DisclosureGroup("全部关联会话") {
                                    ForEach(projection.other.filter { item in !projection.recent.contains(where: { $0.id == item.id }) }) {
                                        row($0, in: .other)
                                    }
                                }.disclosureGroupStyle(WorkbenchDisclosureStyle(minHeight: 36))
                            }
                        }
                    }
                    if isArchiving {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在归档…")
                        }.font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if archiveResult != nil {
                        BatchArchiveControls(showsArchiveAction: false, count: projection.archiveCount,
                                             blockedSummary: nil, isRunning: isArchiving, result: archiveResult,
                                             onArchive: {}, onUndo: onUndoArchive, onRetry: onRetryArchive)
                    }
                }
                // Connectivity is not an actionable request. Keep stale records separate,
                // including on the inbox, without counting them as live work.
                if !projection.offline.isEmpty {
                    DisclosureGroup("状态未同步 · \(projection.offline.count)") {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("连接后才能确认这些会话的当前状态。")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
                            ForEach(projection.offline) { row($0, in: .other) }
                        }
                    }.disclosureGroupStyle(WorkbenchDisclosureStyle(minHeight: 36))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !attentionOnly { groupHistory }
                if !attentionOnly && !context.restoreReport.isEmpty { restoreReportSection }
                if !attentionOnly && !context.pendingRestoration.isEmpty { restoration }
            }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
                .frame(maxWidth: 944).frame(maxWidth: .infinity)
                #if PERCH_ACCEPTANCE
                .background(NativeDashboardProbe(projection: projection, attentionOnly: attentionOnly, groupID: group?.id))
                #endif
        }
        .onAppear { queueOrder.update(projection.attention.items.map(\.id)) }
        .onChange(of: projection.attention.items.map(\.id)) { _, ids in queueOrder.update(ids) }
    }

    private var changeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("新进展 · \(changes.count)", systemImage: "sparkle")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if let onAcknowledgeChanges { Button("确认看过这些变化", action: onAcknowledgeChanges).buttonStyle(QuietLinkStyle()) }
            }
            Text("自上次确认后新增或变化的请求与结果；首次使用会包含当前事项。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(changes.prefix(5)) { item in
                Button { onOpen(item) } label: {
                    HStack {
                        Text(item.title).lineLimit(1)
                        Spacer()
                        Text(LocalizedStringKey(item.section.rawValue)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(ChangeRowStyle())
            }
            if changes.count > 5 { Text("其余变化可在下方对应分区查看。").font(.caption).foregroundStyle(.secondary) }
        }.font(.system(size: 12))
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private var title: LocalizedStringKey {
        if attentionOnly { return "等你处理" }
        if let group { return LocalizedStringKey(group.name) }
        if projection.emptyState == .noEnvironment || projection.emptyState == .noSessions { return "开始第一段会话" }
        return "工作台"
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let group, !attentionOnly {
                if let facet = context.scope.facets.first(where: { $0.kind == .group }) {
                    Button("工作台") { onClearScope(facet) }.buttonStyle(QuietLinkStyle()).font(.system(size: 12))
                }
                Text(group.name).font(.system(size: 25, weight: .semibold)).textSelection(.enabled)
            } else { Text(title).font(.system(size: 25, weight: .semibold)) }
            if !visibleFacets.isEmpty { scopeChips }
            if attentionOnly && !projection.attention.isEmpty {
                Text("共 \(projection.attention.items.count) 项 · 确认、回答或处理错误；查看结果请到工作台。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !attentionOnly && (group != nil || projection.emptyState == nil || projection.emptyState == .nothingPending) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { summary }
                    VStack(alignment: .leading, spacing: 5) { summary }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// Why this list is shorter than the workspace. Each facet clears on its own: a
    /// group filter and a machine filter answer different questions, and dropping one
    /// should not also drop the other. The whole pill is the target, so there is no
    /// second hit area inside it.
    private var visibleFacets: [ActiveScope.Facet] {
        context.scope.facets.filter { attentionOnly || group == nil || $0.kind == .host }
    }
    private var scopeChips: some View {
        HStack(spacing: 6) {
            Text("筛选中").font(.system(size: 11)).foregroundStyle(.tertiary)
            ForEach(visibleFacets, id: \.self) { facet in
                Button { onClearScope(facet) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: facet.symbol).font(.system(size: 10))
                        Text(facet.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(.horizontal, 9).frame(minHeight: 28)
                        .background(Color.primary.opacity(0.05), in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain)
                    .help("取消筛选：\(facet.name)").accessibilityLabel("取消筛选：\(facet.name)")
            }
            if visibleFacets.count > 1 {
                Button("全部清除", action: onClearAllScopes).buttonStyle(QuietLinkStyle()).font(.system(size: 11))
            }
        }
    }

    @ViewBuilder private var summary: some View {
        if projection.sections.isEmpty && projection.other.isEmpty && !projection.offline.isEmpty {
            Text("连接后查看最新进展")
        } else if projection.attention.isEmpty {
            Text("当前没有待处理事项")
        } else {
            Button(action: onShowInbox) {
                summaryChip("exclamationmark.circle.fill", tint: .orange,
                            text: "\(projection.attention.items.count) 项等你处理", active: true)
            }.buttonStyle(SummaryStatStyle())
        }
        if !projection.review.isEmpty {
            summaryChip("circlebadge.fill", tint: .blue,
                        text: "\(projection.review.items.count) 项结果待查看", active: false)
        }
        if !projection.running.isEmpty {
            summaryChip("circle.dotted", tint: Color(.tertiaryLabelColor),
                        text: "\(projection.running.items.count) 项运行中", active: false)
        }
    }

    private func summaryChip(_ symbol: String, tint: Color, text: LocalizedStringKey, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).foregroundStyle(.primary)
        }.padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(active ? 0.09 : 0.06), in: Capsule())
    }

    private func section(_ value: DashboardSection, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The inbox intro already names the queue; repeat only the count there.
            if !attentionOnly {
                HStack(spacing: 7) {
                    QueueSectionMark(section: value.section)
                    Text(LocalizedStringKey(value.section.rawValue)).accessibilityAddTraits(.isHeader)
                    Text("\(value.items.count)").foregroundStyle(.tertiary)
                    Spacer()
                    if value.section == .attention {
                        Button("进入待处理", action: onShowInbox).buttonStyle(QuietLinkStyle())
                    }
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            ForEach(value.items.prefix(limit)) { row($0, in: value.section) }
            if value.items.count > limit && value.section != .attention {
                DisclosureGroup("展开其余 \(value.items.count - limit) 个会话") {
                    VStack(spacing: 0) { ForEach(value.items.dropFirst(limit)) { row($0, in: value.section) } }
                }.disclosureGroupStyle(WorkbenchDisclosureStyle(minHeight: 36))
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
            }
        }
    }

    private func emptyState(_ state: DashboardEmptyState) -> some View {
        VStack(spacing: 10) {
            Image(systemName: state.symbol).font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(state.title)).font(.system(size: 15, weight: .medium))
            if state == .noEnvironment {
                HStack(spacing: 10) {
                    Button("连接远程机器…", action: onConnectRemote).buttonStyle(.borderedProminent)
                        .tint(WorkbenchTheme.accent).foregroundStyle(WorkbenchTheme.actionGlyph)
                    Button("检测本机 Agent…", action: onStartLocal)
                }.padding(.top, 4)
                Text("远程 Agent 沿用你的 SSH 配置；本机可连接已安装的 Kimi 和 Codex。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state == .noMatches {
                // Nothing is wrong with the workspace; the filter is hiding everything.
                // Starting a session would not fix that and would bury the reason.
                Button("清除筛选", action: onClearSessionFilters ?? onClearAllScopes).buttonStyle(.borderedProminent)
                    .tint(WorkbenchTheme.accent).foregroundStyle(WorkbenchTheme.actionGlyph)
                    .padding(.top, 4)
            } else {
                Button("新建会话", action: onNewTask).buttonStyle(.borderedProminent)
                    .tint(WorkbenchTheme.accent).foregroundStyle(WorkbenchTheme.actionGlyph).padding(.top, 4)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 44)
    }

    /// What became of the sessions that were mid-turn when the workbench lost
    /// sight of them. Positive outcomes are listed too: "still running" is
    /// information a reconnect otherwise leaves the user to verify by hand.
    private var restoreReportSection: some View {
        DisclosureGroup("断开期间的任务结果 · \(context.restoreReport.count)") {
            VStack(alignment: .leading, spacing: 10) {
                Text("断开或离开前正在运行的任务，重新连接后的状态：")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(context.restoreReport) { entry in
                    HStack {
                        Button { onOpenRestoreEntry?(entry) } label: {
                            Label(entry.title, systemImage: entry.reference.kind.symbol).lineLimit(1)
                        }.buttonStyle(.plain).disabled(entry.outcome == .missing)
                        Text(entry.hostName).font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Label(entry.outcome.label, systemImage: entry.outcome.symbol)
                            .foregroundStyle(entry.outcome.needsAttention ? Color.orange : Color.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("知道了") { onDismissRestoreReport?() }.buttonStyle(.link)
                }
            }.padding(.top, 10)
        }.disclosureGroupStyle(WorkbenchDisclosureStyle(minHeight: 36))
            .font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private var restoration: some View {
        DisclosureGroup("等待恢复 · \(context.pendingRestoration.count) 个会话") {
            VStack(alignment: .leading, spacing: 10) {
                Text("连接后接回原会话；未找到的会话保留在这里，确认后可以移除。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(context.pendingRestoration, id: \.session.id) { saved in
                    HStack {
                        Label(saved.title, systemImage: saved.session.kind.symbol).lineLimit(1)
                        Spacer()
                        Button("不再恢复") { onForgetRestoration(saved) }
                    }
                }
            }.padding(.top, 10)
        }.disclosureGroupStyle(WorkbenchDisclosureStyle(minHeight: 36))
            .font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private func storageBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ item: WorkspaceSession, in section: WorkQueueSection) -> some View {
        var parts = [item.detail, item.hostName]
        if !item.directory.isEmpty { parts.append(URL(fileURLWithPath: item.directory).lastPathComponent) }
        let memberships = groupMemberships(item)
        let ordered = memberships.filter { $0.id == group?.id } + memberships.filter { $0.id != group?.id }
        return QueueRow(item: item,
                        time: SessionTime.label(since: item.updatedAt, waiting: section == .attention && item.online),
                        waiting: section == .attention && item.online,
                        metadata: parts.joined(separator: " · "),
                        groups: ordered,
                        onOpenGroup: onOpenGroup, onManageGroups: { onManageGroups(item) },
                        onOpen: { onOpen(item) },
                        onMarkReviewed: { onMarkReviewed(item) }, actions: rowActions(item))
    }
}

struct QueueRow<Actions: View>: View {
    @UILocalization private var L
    let item: WorkspaceSession
    let time: String?
    var waiting = false
    let metadata: String
    let groups: [SessionGroupIndex.Membership]
    let onOpenGroup: (UUID) -> Void
    let onManageGroups: () -> Void
    let onOpen: () -> Void
    let onMarkReviewed: () -> Void
    let actions: Actions
    @State private var hovered = false

    private var groupBadge: String? { SessionGroupIndex.label(groups.map(\.name)) }
    private var tooltip: String {
        var lines = [item.title]
        if !item.directory.isEmpty { lines.append(item.directory) }
        if groups.isEmpty { lines.append(L("未归组")) }
        else {
            let names = groups.map(\.name).joined(separator: "、")
            lines.append(L("任务组：\(names)"))
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SessionStatusIndicator(item: item).frame(width: 17, height: 16).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(metadata).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                    membershipControls
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let time {
                Text(time).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(waiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .fixedSize()
                    .padding(.top, 2)
                    .opacity(hovered && showsHoverAction ? 0 : 1)
            }
            if showsHoverAction {
                Button("已查看", action: onMarkReviewed).buttonStyle(.borderless)
                    .font(.system(size: 11)).padding(.top, 2).fixedSize()
                    .opacity(hovered ? 1 : 0)
            }
        }.padding(.horizontal, 10).padding(.vertical, 11)
            .opacity(item.online ? 1 : 0.55)
            .contentShape(Rectangle())
            .onTapGesture { if item.online { onOpen() } }
            .background(hovered && item.online ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) { Divider().padding(.leading, 39).opacity(0.5) }
            .onHover { hovered = $0 }
            .contextMenu { actions }
            .help(tooltip)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("打开会话")) { if item.online { onOpen() } }
    }

    private var showsHoverAction: Bool { item.canMarkReviewed && item.online }

    /// Group membership rides the metadata line instead of a full-width third row;
    /// every row still states its group, and ungrouped rows keep a visible action.
    @ViewBuilder private var membershipControls: some View {
        if let first = groups.first {
            Button { onOpenGroup(first.id) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder").font(.system(size: 9)).accessibilityHidden(true)
                    Text(first.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                }
            }.buttonStyle(QuietLinkStyle()).fixedSize().help(first.name)
                .accessibilityLabel("打开任务组：\(first.name)")
            if groups.count > 1 {
                Menu {
                    ForEach(groups.dropFirst()) { group in
                        Button(group.name) { onOpenGroup(group.id) }
                    }
                } label: { Text("另 \(groups.count - 1) 组") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Button("管理归属", action: onManageGroups).buttonStyle(QuietLinkStyle()).fixedSize()
                .opacity(hovered ? 1 : 0)
        } else {
            Text("未归组").foregroundStyle(.tertiary)
            Button("关联任务组", action: onManageGroups).buttonStyle(QuietLinkStyle()).fixedSize()
        }
    }

}

/// Inline links stay in the quiet palette; only hover asks for attention.
private struct QuietLinkStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovered || configuration.isPressed ? Color.primary : Color.secondary)
            .underline(hovered)
            .onHover { hovered = $0 }
    }
}

/// The one actionable stat is a button; the capsule only deepens on hover.
private struct SummaryStatStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovered || configuration.isPressed ? -0.04 : 0)
            .onHover { hovered = $0 }
    }
}

/// Section titles share the status palette with the row indicators.
private struct QueueSectionMark: View {
    let section: WorkQueueSection
    var body: some View {
        switch section {
        case .attention:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .review:
            Image(systemName: "circlebadge.fill").foregroundStyle(.blue)
        case .running:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .other:
            Image(systemName: "tray").foregroundStyle(.tertiary)
        }
    }
}

private extension DashboardEmptyState {
    var symbol: String {
        switch self {
        case .noEnvironment: return "server.rack"
        case .noSessions: return "plus.message"
        case .nothingPending: return "checkmark.circle"
        case .noMatches: return "line.3.horizontal.decrease.circle"
        }
    }
}

/// Rows inside the change card light up on hover instead of staying flat.
private struct ChangeRowStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.primary.opacity(configuration.isPressed ? 0.07 : hovered ? 0.04 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}
