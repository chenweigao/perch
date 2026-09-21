import SwiftUI
import WorkbenchCore

/// The workbench as a place to pick work up: scope, new task, batch archive, then
/// only the sections that need an action. Rendering is driven entirely by
/// DashboardProjection so the same data can be checked without a running app.
struct WorkbenchDashboard: View {
    var attentionOnly = false
    let projection: DashboardProjection
    var context = DashboardContext()
    let groups: [WorkItemGroup]
    let selectedGroupID: UUID?
    let isArchiving: Bool
    let archiveResult: BatchArchiveRun?
    let onSelectScope: (UUID?) -> Void
    let onNewTask: () -> Void
    let onOpen: (WorkspaceSession) -> Void
    let onMarkReviewed: (WorkspaceSession) -> Void
    let onEditGroup: () -> Void
    let onResume: (WorkspaceSession) -> Void
    let onForgetRestoration: (SavedTerminal) -> Void
    let onArchive: () -> Void
    let onUndoArchive: () -> Void
    let onRetryArchive: () -> Void
    let onStartLocal: () -> Void
    let onConnectRemote: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let error = context.storageError { storageBanner(error) }
                if !attentionOnly {
                    header
                    if let group = context.group { groupCard(group) }
                    if !context.pendingRestoration.isEmpty { restoration }
                }
                if attentionOnly && projection.sections.isEmpty {
                    Label("暂时没有需要你处理的事项", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary).padding(.vertical, 24)
                } else if let empty = projection.emptyState { emptyState(empty) }
                ForEach(projection.sections) { section in
                    Text(section.section.rawValue).font(.system(size: 13, weight: .semibold)).padding(.top, 10)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.items) { item in row(item, in: section.section) }
                }
                if !projection.other.isEmpty {
                    DisclosureGroup("已查看、就绪和其他会话 · \(projection.other.count)") {
                        VStack(spacing: 10) { ForEach(projection.other) { row($0, in: .other) } }.padding(.top, 10)
                    }
                }
                if !projection.offline.isEmpty {
                    DisclosureGroup("状态未同步 · \(projection.offline.count)") {
                        VStack(spacing: 10) { ForEach(projection.offline) { row($0, in: .other) } }.padding(.top, 10)
                    }
                    Text("离线会话不计入上方数量，也不会被批量归档。").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(32).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("范围", selection: Binding(get: { selectedGroupID }, set: onSelectScope)) {
                    Text("全部").tag(UUID?.none)
                    ForEach(groups) { group in Text(group.name).tag(UUID?.some(group.id)) }
                }.labelsHidden().fixedSize()
                Button(action: onNewTask) { Label("新建任务", systemImage: "plus") }
                Spacer()
            }
            BatchArchiveControls(count: projection.archiveCount, blockedSummary: projection.blockedSummary,
                                 isRunning: isArchiving, result: archiveResult,
                                 onArchive: onArchive, onUndo: onUndoArchive, onRetry: onRetryArchive)
        }
    }

    private func emptyState(_ state: DashboardEmptyState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.title).font(.system(size: 15, weight: .medium))
            if state == .noEnvironment {
                HStack(spacing: 10) {
                    Button("本机开始") { onStartLocal() }.buttonStyle(.borderedProminent)
                    Button("连接远程") { onConnectRemote() }
                }
                Text("本机使用这台 Mac 上已安装的 Agent，工具在你选择的目录执行；远程仍在 SSH 主机上运行。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state == .noSessions {
                Button("选择 Agent 和工作目录") { onNewTask() }.buttonStyle(.borderedProminent)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The task group loop: the goal being pursued, the next step written at the end of
    /// the last round, and a way back into the session it was written about. Without it
    /// the group's own notes are only reachable through the editor sheet.
    private func groupCard(_ group: WorkItemGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(group.name).font(.system(size: 15, weight: .medium))
                Spacer()
                Button("编辑任务组") { onEditGroup() }.font(.caption)
            }
            if !group.goal.isEmpty {
                Text(group.goal).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Label("下一步", systemImage: "arrow.turn.down.right").font(.system(size: 12, weight: .semibold))
            Text(group.nextStep.isEmpty ? "还没有下一步。结束这一轮时，写下回来后要做的第一件事。" : group.nextStep)
                .font(.system(size: 13)).foregroundStyle(group.nextStep.isEmpty ? Color.secondary : Color.primary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("关联 \(group.sessions.count) 个会话 · 名称与笔记只保存在本机")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let resume = context.resume {
                    Button("继续上次会话") { onResume(resume) }.font(.caption).disabled(!resume.online)
                }
            }
            ForEach(context.missing) { reference in
                Label("关联\(reference.kind.label)尚未出现在当前列表：\(reference.terminalID)",
                      systemImage: "questionmark.folder").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Restore only reattaches the same remote session, so a reference that is missing
    /// or not yet connected stays a visible waiting list instead of disappearing.
    private var restoration: some View {
        DisclosureGroup("等待恢复 · \(context.pendingRestoration.count) 个会话") {
            VStack(alignment: .leading, spacing: 10) {
                Text("连接后接回原会话；未找到的会话保留在这里，确认后可以移除。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(context.pendingRestoration, id: \.session.id) { saved in
                    HStack {
                        Label(saved.title, systemImage: saved.session.kind.symbol).font(.callout).lineLimit(1)
                        Spacer()
                        Button("不再恢复") { onForgetRestoration(saved) }.font(.caption)
                    }
                }
            }.padding(.top, 10)
        }.padding(18).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    /// A failed read or write of the local workspace was recorded and never shown, so
    /// pins, groups and reviewed versions could stop persisting while the UI looked fine.
    private func storageBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ item: WorkspaceSession, in section: WorkQueueSection) -> some View {
        let time = SessionTime.label(since: item.updatedAt, waiting: section == .attention)
        let spoken = time.map { "\(item.title)，\(item.detail)，\($0)" } ?? "\(item.title)，\(item.detail)"
        return HStack(spacing: 0) {
            Button { onOpen(item) } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.reference.kind.symbol).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        // Detail text comes from existing metadata; no model request writes it.
                        Text(metadata(item)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    // How long something has waited is the reason to open it next, so the
                    // time keeps its own space rather than sharing the truncated line.
                    if let time {
                        Text(time).font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(section == .attention ? Color.orange : Color.secondary)
                            .fixedSize()
                    }
                    if section == .attention { Text("处理").font(.caption).foregroundStyle(.orange) }
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!item.online)
                .accessibilityLabel(spoken)
            if item.canMarkReviewed && item.online {
                Button("已查看") { onMarkReviewed(item) }.font(.caption).padding(.trailing, 14)
            }
        }.background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .opacity(item.online ? 1 : 0.5)
            .help(item.directory.isEmpty ? item.title : "\(item.title)\n\(item.directory)")
    }

    /// The directory tail identifies the work; the full path stays in the row help so a
    /// long path cannot push the host and status out of the line.
    private func metadata(_ item: WorkspaceSession) -> String {
        var parts = [item.hostName, item.detail]
        if !item.directory.isEmpty { parts.append(URL(fileURLWithPath: item.directory).lastPathComponent) }
        return parts.joined(separator: " · ")
    }
}
