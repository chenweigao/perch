import SwiftUI
import WorkbenchCore

struct TaskGroupPage: View {
    @UILocalization private var L
    @ObservedObject var model: WorkbenchModel
    let group: WorkItemGroup
    @State private var search = ""

    private var projection: TaskGroupProjection {
        TaskGroupProjection(group: group, allSessions: model.allSessions,
                            lastSessionID: model.workspace.lastSessionByGroup[group.id.uuidString], search: search)
    }

    var body: some View {
        let items = projection
        let archive = DashboardProjection(sessions: items.sessions,
            subjects: Dictionary(uniqueKeysWithValues: items.sessions.map { ($0.id, model.archiveSubject($0)) }),
            hasEnvironment: !model.connections.isEmpty)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header(archive)
                if items.resume != nil || !group.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation(items.resume)
                }
                if !items.needsAttention.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("需要处理 · \(items.needsAttention.count)")
                            .font(.system(size: 13, weight: .medium)).accessibilityAddTraits(.isHeader)
                        ForEach(items.needsAttention) { row($0) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Text("本组会话 · \(items.totalCount)")
                            .font(.system(size: 13, weight: .medium)).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        TextField("搜索本组会话", text: $search)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    }
                    if items.sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(items.totalCount == 0 ? L("还没有可显示的会话") : L("没有匹配的会话"))
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            if items.totalCount == 0 {
                                Button("关联已有会话") { model.editGroup(group, sessionsOnly: true) }
                            } else {
                                Button("清除搜索") { search = "" }
                            }
                        }.padding(.vertical, 16)
                    } else {
                        ForEach(items.sessions) { row($0) }
                    }
                    if items.missingCount > 0 {
                        Text("另有 \(items.missingCount) 个关联会话尚未同步，可在关联管理中查看。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(32).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
    }

    private func header(_ archive: DashboardProjection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name).font(.system(size: 20, weight: .medium))
                        .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    if !group.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(group.goal).font(.system(size: 13)).lineLimit(1).help(group.goal)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("新建任务") { model.showNewKimi = true }
                Menu {
                    Button("关联已有会话") { model.editGroup(group, sessionsOnly: true) }
                    Button("编辑任务组") { model.editGroup(group) }
                    Divider()
                    Button("归档已完成 \(archive.archiveCount)") { model.runBatchArchive(archive.archivePlan) }
                        .disabled(archive.archiveCount == 0 || model.isArchiving)
                    if let summary = archive.blockedSummary { Text(summary) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 20).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).fixedSize().help("任务组操作").accessibilityLabel("任务组操作")
            }
            if model.isArchiving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在归档…").font(.caption)
                }
            }
            if let result = model.archiveResult, result.isFinished {
                BatchArchiveControls(showsArchiveAction: false, count: archive.archiveCount,
                    blockedSummary: archive.blockedSummary, isRunning: model.isArchiving, result: result,
                    onArchive: { model.runBatchArchive(archive.archivePlan) },
                    onUndo: { model.undoBatchArchive() }, onRetry: { model.retryBatchArchive() })
            }
        }
    }

    private func continuation(_ session: WorkspaceSession?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session {
                Text("继续上次会话").font(.system(size: 12)).foregroundStyle(.secondary)
                row(session)
            }
            if !group.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("下一步").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(group.nextStep).font(.system(size: 13)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ session: WorkspaceSession) -> some View {
        Button { model.open(session) } label: {
            HStack(spacing: 12) {
                Image(systemName: session.reference.kind.symbol).frame(width: 20).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 13)).lineLimit(1)
                    Text("\(session.hostName) · \(session.detail) · \(session.directory)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !session.online {
                    Text("状态未同步").font(.caption).foregroundStyle(.secondary)
                } else if session.section == .attention {
                    Text("需要处理").font(.caption).foregroundStyle(.orange)
                } else if session.section == .review {
                    Text("有新结果").font(.caption).foregroundStyle(.blue)
                } else if session.section == .running {
                    Text("运行中").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(SidebarNavigationStyle()).disabled(!session.online)
            .help("\(session.title)\n\(session.directory)")
    }
}
