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
        let activity = DashboardProjection(sessions: items.sessions,
            subjects: Dictionary(uniqueKeysWithValues: items.sessions.map { ($0.id, model.archiveSubject($0)) }),
            hasConfiguredEnvironment: model.configuredEnvironment)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let error = model.workspaceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                }
                header(items, activity)
                notes(items.resume)
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        Text("本组会话").font(.system(size: 13, weight: .medium)).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        TextField("搜索本组会话", text: $search)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    }
                    if group.sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("从一段新会话开始，或把已有会话关联到这个目标。")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            HStack {
                                Button("新建会话") { model.showNewKimi = true }
                                Button("关联已有会话") { model.editGroup(group, sessionsOnly: true) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    } else if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && items.sessions.isEmpty && items.archived.isEmpty {
                        HStack {
                            Text("没有匹配的会话").foregroundStyle(.secondary)
                            Button("清除搜索") { search = "" }.buttonStyle(.link)
                        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(activity.sections) { section in
                        sessionSection(LocalizedStringKey(section.section.rawValue), items: section.items)
                    }
                    if !activity.other.isEmpty { sessionSection("其他会话", items: activity.other) }
                    if !activity.offline.isEmpty {
                        sessionSection("状态未同步", items: activity.offline)
                    }
                    if !items.archived.isEmpty {
                        DisclosureGroup("已归档 · \(items.archived.count)") {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("归档会话仍保留在任务组中，恢复后可继续。")
                                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
                                ForEach(items.archived) { archivedRow($0) }
                            }
                        }.disclosureGroupStyle(TaskGroupArchiveDisclosureStyle())
                    }
                    if items.missingCount > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("另有 \(items.missingCount) 个关联会话尚未同步，可在关联管理中查看。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("管理关联") { model.editGroup(group, sessionsOnly: true) }.buttonStyle(.link)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
                .frame(maxWidth: 944).frame(maxWidth: .infinity)
        }
    }

    private func header(_ items: TaskGroupProjection, _ archive: DashboardProjection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.name).font(.system(size: 25, weight: .semibold))
                        .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    Text("\(group.sessions.count) 个关联 · \(items.totalCount) 个当前 · \(items.archivedCount) 个已归档")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("新建会话") { model.showNewKimi = true }
                Menu {
                    Button("关联已有会话") { model.editGroup(group, sessionsOnly: true) }
                    Button("编辑任务组") { model.editGroup(group) }
                    Divider()
                    Button("归档已完成 \(archive.archiveCount)") { model.runBatchArchive(archive.archivePlan) }
                        .disabled(archive.archiveCount == 0 || model.isArchiving)
                    if let summary = archive.blockedSummary { Text(summary) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("任务组操作").accessibilityLabel("任务组操作")
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

    private func notes(_ session: WorkspaceSession?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            note("目标", text: group.goal, placeholder: "添加目标：做到什么程度算完成？")
            note("下一步", text: group.nextStep, placeholder: "记下回来后先做什么")
            if let session {
                Button { model.open(session) } label: {
                    Label(L("继续上次会话：\(session.title)"), systemImage: "arrow.turn.down.right")
                        .font(.system(size: 12)).lineLimit(1)
                }.buttonStyle(.link).disabled(!session.online)
                if !session.online { Text("上次会话尚未连接").font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ title: LocalizedStringKey, text: String, placeholder: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { model.editGroup(group) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("编辑任务组")
                }
            }.font(.system(size: 12))
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { model.editGroup(group) } label: { Text(placeholder) }.buttonStyle(.link)
            } else {
                Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sessionSection(_ title: LocalizedStringKey, items: [WorkspaceSession]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(title).accessibilityAddTraits(.isHeader)
                Text("\(items.count)").foregroundStyle(.tertiary)
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(items) { row($0) }
        }
    }

    private func row(_ session: WorkspaceSession) -> some View {
        var parts = [session.detail, session.hostName]
        if !session.directory.isEmpty { parts.append(URL(fileURLWithPath: session.directory).lastPathComponent) }
        return QueueRow(item: session, time: SessionTime.label(since: session.updatedAt, waiting: session.online && session.section == .attention),
                        metadata: parts.joined(separator: " · "), onOpen: { model.open(session) },
                        onMarkReviewed: { model.markReviewed(session) }, actions: SessionActionsMenu(model: model, item: session))
    }

    private func archivedRow(_ session: WorkspaceSession) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "archivebox").frame(width: 17).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title).font(.system(size: 13)).lineLimit(2)
                Text("\(session.reference.kind.label) · \(session.hostName)").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("恢复会话") { model.setArchived(session, archived: false) }
                .buttonStyle(.borderless).font(.system(size: 11)).disabled(model.managing.contains(session.id) || !model.canArchive(session))
        }.padding(.horizontal, 8).padding(.vertical, 13)
            .contextMenu { SessionActionsMenu(model: model, item: session) }
    }
}

/// The full header is a button, so both the label and its surrounding space
/// expand the archive instead of requiring a click on the disclosure triangle.
private struct TaskGroupArchiveDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).frame(width: 12).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(SidebarNavigationStyle())
                .accessibilityValue(configuration.isExpanded ? Text("已展开") : Text("已收起"))
            if configuration.isExpanded { configuration.content }
        }
    }
}
