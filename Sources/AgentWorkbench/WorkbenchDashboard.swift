import SwiftUI
import WorkbenchCore

/// Home offers a bounded overview; the inbox shows every actionable session.
/// Both use the same projection and rows, without maintaining a second inbox state.
struct WorkbenchDashboard<RowActions: View>: View {
    var attentionOnly = false
    let projection: DashboardProjection
    var context = DashboardContext()
    let isArchiving: Bool
    let archiveResult: BatchArchiveRun?
    let onNewTask: () -> Void
    let onOpen: (WorkspaceSession) -> Void
    let onMarkReviewed: (WorkspaceSession) -> Void
    let rowActions: (WorkspaceSession) -> RowActions
    let onForgetRestoration: (SavedTerminal) -> Void
    let onUndoArchive: () -> Void
    let onRetryArchive: () -> Void
    let onStartLocal: () -> Void
    let onConnectRemote: () -> Void
    let onShowInbox: () -> Void
    let onShowAll: () -> Void
    let onShowHome: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let error = context.storageError { storageBanner(error) }
                introduction
                if attentionOnly {
                    if projection.attention.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("暂时没有需要你处理的事项", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                            Button("返回工作台", action: onShowHome).buttonStyle(.link)
                        }.padding(.vertical, 12)
                    } else { section(projection.attention, limit: projection.attention.items.count) }
                } else {
                    if let empty = projection.emptyState, empty != .nothingPending { emptyState(empty) }
                    ForEach(projection.sections) { value in
                        section(value, limit: value.section == .attention ? 3 : 5)
                    }
                    if !projection.recent.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("最近会话").accessibilityAddTraits(.isHeader)
                                Spacer()
                                Button("查看全部", action: onShowAll).buttonStyle(.link)
                            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
                            ForEach(projection.recent) { row($0, in: .other) }
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
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !attentionOnly && !context.pendingRestoration.isEmpty { restoration }
            }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
                .frame(maxWidth: 944).frame(maxWidth: .infinity)
        }
    }

    private var title: LocalizedStringKey {
        if attentionOnly { return "等你处理" }
        if projection.emptyState == .noEnvironment || projection.emptyState == .noSessions { return "开始第一段会话" }
        return "接着做"
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 25, weight: .semibold))
            if attentionOnly {
                Text("确认、回答或处理错误；查看结果请到工作台。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if projection.emptyState != .noEnvironment && projection.emptyState != .noSessions {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { summary }
                    VStack(alignment: .leading, spacing: 5) { summary }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        if projection.sections.isEmpty && projection.other.isEmpty && !projection.offline.isEmpty {
            Text("连接后查看最新进展")
        } else if projection.attention.isEmpty {
            Text("当前没有待处理事项")
        } else {
            Button(action: onShowInbox) { Text("\(projection.attention.items.count) 项等你处理") }
                .buttonStyle(.plain).foregroundStyle(.orange)
        }
        if !projection.review.isEmpty { Text("\(projection.review.items.count) 项结果待查看") }
        if !projection.running.isEmpty { Text("\(projection.running.items.count) 项运行中") }
    }

    private func section(_ value: DashboardSection, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(LocalizedStringKey(value.section.rawValue)).accessibilityAddTraits(.isHeader)
                Text("\(value.items.count)").foregroundStyle(.tertiary)
                Spacer()
                if value.section == .attention && !attentionOnly {
                    Button("进入待处理", action: onShowInbox).buttonStyle(.link)
                }
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
            ForEach(value.items.prefix(limit)) { row($0, in: value.section) }
            if value.items.count > limit && value.section != .attention {
                DisclosureGroup("展开其余 \(value.items.count - limit) 个会话") {
                    VStack(spacing: 0) { ForEach(value.items.dropFirst(limit)) { row($0, in: value.section) } }
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
            }
        }
    }

    private func emptyState(_ state: DashboardEmptyState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(state.title)).font(.system(size: 15, weight: .medium))
            if state == .noEnvironment {
                HStack(spacing: 10) {
                    Button("连接远程机器…", action: onConnectRemote).buttonStyle(.borderedProminent)
                    Button("检测本机 Agent…", action: onStartLocal)
                }
                Text("远程 Agent 沿用你的 SSH 配置。本机环境目前仅支持安装检测。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("新建会话", action: onNewTask).buttonStyle(.borderedProminent)
            }
        }.padding(.vertical, 12)
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
        }.font(.system(size: 12)).foregroundStyle(.secondary)
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
        return QueueRow(item: item,
                        time: SessionTime.label(since: item.updatedAt, waiting: section == .attention && item.online),
                        metadata: parts.joined(separator: " · "), onOpen: { onOpen(item) },
                        onMarkReviewed: { onMarkReviewed(item) }, actions: rowActions(item))
    }
}

private struct QueueRow<Actions: View>: View {
    let item: WorkspaceSession
    let time: String?
    let metadata: String
    let onOpen: () -> Void
    let onMarkReviewed: () -> Void
    let actions: Actions
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    SessionStatusIndicator(item: item).frame(width: 17, height: 16).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(metadata).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let time {
                        Text(time).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }
                }.padding(.horizontal, 8).padding(.vertical, 13).frame(minHeight: 64).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!item.online)
                .accessibilityLabel([item.title, metadata, time].compactMap { $0 }.joined(separator: "，"))
            if item.canMarkReviewed && item.online {
                Button("已查看", action: onMarkReviewed).buttonStyle(.borderless)
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
        }.background(hovered && item.online ? Color.black.opacity(0.025) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottom) { Divider().padding(.leading, 39).opacity(0.5) }
            .opacity(item.online ? 1 : 0.55).onHover { hovered = $0 }
            .contextMenu { actions }
            .help(item.directory.isEmpty ? item.title : "\(item.title)\n\(item.directory)")
    }
}
