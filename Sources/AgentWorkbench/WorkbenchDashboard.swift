import SwiftUI
import WorkbenchCore

/// The workbench as a place to pick work up: scope, new task, batch archive, then
/// only the sections that need an action. Rendering is driven entirely by
/// DashboardProjection so the same data can be checked without a running app.
struct WorkbenchDashboard: View {
    var attentionOnly = false
    let projection: DashboardProjection
    let groups: [WorkItemGroup]
    let selectedGroupID: UUID?
    let isArchiving: Bool
    let archiveResult: BatchArchiveRun?
    let onSelectScope: (UUID?) -> Void
    let onNewTask: () -> Void
    let onOpen: (WorkspaceSession) -> Void
    let onMarkReviewed: (WorkspaceSession) -> Void
    let onArchive: () -> Void
    let onUndoArchive: () -> Void
    let onRetryArchive: () -> Void
    let onStartLocal: () -> Void
    let onConnectRemote: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !attentionOnly { header }
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

    private func row(_ item: WorkspaceSession, in section: WorkQueueSection) -> some View {
        HStack(spacing: 0) {
            Button { onOpen(item) } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.reference.kind.symbol).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        // Detail text comes from existing metadata; no model request writes it.
                        Text("\(item.hostName) · \(item.detail) · \(item.directory)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if section == .attention { Text("处理").font(.caption).foregroundStyle(.orange) }
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!item.online)
                .accessibilityLabel("\(item.title)，\(item.detail)")
            if item.canMarkReviewed && item.online {
                Button("已查看") { onMarkReviewed(item) }.font(.caption).padding(.trailing, 14)
            }
        }.background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .opacity(item.online ? 1 : 0.5)
    }
}
