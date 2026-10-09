import AppKit
import SwiftUI
import Observation
import WorkbenchCore

// Layout fixture: production group page/editor/projections; an in-memory model
// replaces remote connections and persistence. No real workspace is loaded.
@MainActor @Observable final class WorkbenchModel {
    var allSessions: [WorkspaceSession] = []
    var workspace = LocalWorkspace()
    var workspaceError: String?
    var isArchiving = false
    var archiveResult: BatchArchiveRun?
    var showNewKimi = false
    var editingGroup: WorkItemGroup?
    var editingGroupSessionsOnly = false
    var showGroupEditor = false
    var notice: String?
    var managing = Set<String>()
    var groupingSession: WorkspaceSession?
    var selectedGroupID: UUID?
    var showAllTaskGroups = false
    var search = ""
    var onlyAttention = false
    var scopeHost: SSHHost? { nil }
    var selectedGroup: WorkItemGroup? { workspace.groups.first { $0.id == selectedGroupID } }
    var groupResumeSession: WorkspaceSession? { allSessions.first { $0.id == workspace.lastSessionByGroup[selectedGroupID?.uuidString ?? ""] } }
    var groupSummaries: [TaskGroupSummary] { TaskGroupSummary.ordered(groups: workspace.groups, sessions: allSessions) }
    var activeScope: ActiveScope { ActiveScope(groupName: selectedGroup?.name) }
    var projection: DashboardProjection {
        let scoped = SessionCatalog.scope(allSessions, starred: [], group: selectedGroup, hostFilter: nil,
            search: search, onlyAttention: onlyAttention, showArchived: false).sessions
        return DashboardProjection(sessions: scoped, subjects: [:], hasConfiguredEnvironment: true,
            filtered: selectedGroup != nil || !search.isEmpty)
    }
    func setGroups(_ ids: Set<UUID>, for reference: SessionReference, newGroupName: String = "") {
        for i in workspace.groups.indices {
            workspace.groups[i].sessions.removeAll { $0 == reference }
            if ids.contains(workspace.groups[i].id) { workspace.groups[i].sessions.append(reference) }
        }
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { workspace.groups.append(WorkItemGroup(name: name, goal: "", nextStep: "", sessions: [reference])) }
    }
    func startNewTask() { showNewKimi = true }
    func showHome(groupID: UUID? = nil) { selectedGroupID = groupID; search = ""; onlyAttention = false }
    func toggleGroupPin(_ group: WorkItemGroup) { var changed = group; changed.isPinned.toggle(); updateGroup(changed) }
    func updateGroup(_ group: WorkItemGroup) {
        if let i = workspace.groups.firstIndex(where: { $0.id == group.id }) { workspace.groups[i] = group }
    }
    func addOutcome(_ outcome: GroupOutcome, to id: UUID) {
        if let i = workspace.groups.firstIndex(where: { $0.id == id }) { workspace.groups[i].outcomes.append(outcome) }
    }
    let configuredEnvironment = true
    func archiveSubject(_ item: WorkspaceSession) -> ArchiveSubject {
        ArchiveSubject(reference: item.reference, fingerprint: "fixture", busy: item.section == .running,
                       pendingInteraction: item.section == .attention, starred: false,
                       reviewed: item.section != .review, hasCompletionSignal: false)
    }
    func runBatchArchive(_ plan: BatchArchivePlan) { notice = "归档预览" }
    func undoBatchArchive() {}
    func retryBatchArchive() {}
    func editGroup(_ group: WorkItemGroup? = nil, sessionsOnly: Bool = false) {
        editingGroup = group; editingGroupSessionsOnly = sessionsOnly; showGroupEditor = true
    }
    func saveGroup(_ group: WorkItemGroup) {
        if workspace.groups.contains(where: { $0.id == group.id }) { updateGroup(group) }
        else { workspace.groups.append(group) }
        showHome(groupID: group.id)
    }
    func open(_ item: WorkspaceSession) { notice = "打开：" + item.title }
    func markReviewed(_ item: WorkspaceSession) { notice = "标记已查看：" + item.title }
    func canArchive(_ item: WorkspaceSession) -> Bool { item.online && item.section != .running }
    func setArchived(_ item: WorkspaceSession, archived: Bool) {
        allSessions = allSessions.map { old in
            guard old.id == item.id else { return old }
            return WorkspaceSession(reference: old.reference, title: old.title, directory: old.directory, hostName: old.hostName,
                                    detail: old.detail, online: old.online, section: old.section,
                                    canMarkReviewed: old.canMarkReviewed, archived: archived, updatedAt: old.updatedAt)
        }
    }
    func seed(_ scenario: String) {
        let host = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        allSessions = (1...5).map { i -> WorkspaceSession in
            let reference = SessionReference(hostID: host, terminalID: "demo-\(i)", kind: .kimi)
            let title: String = i == 1 ? "探索新的 Agent 接入" : "检查界面交互 \(i)"
            let updated = Date().timeIntervalSince1970 - Double(i * 300)
            return WorkspaceSession(reference: reference,
                             title: title, directory: "/fixture/perch",
                             hostName: "演示环境", detail: "Kimi · 就绪", online: true, section: .other,
                             canMarkReviewed: false, archived: i > 1, updatedAt: updated)
        }
        var group = WorkItemGroup(name: "Perch", goal: "", nextStep: "", sessions: allSessions.map(\.reference))
        if scenario == "已填写" {
            group.goal = "让任务组织和阅读体验更清楚。\n保留原生导航，减少重复信息，并让所有已关联会话都有去处。"
            group.nextStep = "检查任务组的归档与恢复，再验证搜索和关联管理。"
            workspace.lastSessionByGroup[group.id.uuidString] = allSessions[0].id
        }
        if scenario == "空任务组" { group.sessions = [] }
        if scenario == "未同步" { allSessions = [] }
        group.criteria = [GroupCriterion(title: "恢复后归属保持一致"), GroupCriterion(title: "结果来源可追溯", completed: true)]
        group.outcomes = [GroupOutcome(title: "恢复验证记录", detail: "保存跨机器验证结论", link: "https://example.com/report", source: allSessions.first?.reference)]
        workspace.groups = [group]
        selectedGroupID = group.id
        if scenario == "归属检查" || scenario == "多组与离线" {
            workspace.groups = []
            selectedGroupID = nil
            allSessions = (1...3).map { i in
                WorkspaceSession(reference: SessionReference(hostID: host, terminalID: "worker-\(i)", kind: .kimi),
                    title: "请阅读 WORKER.md，领取并执行当前假期队列。先做最小闭环，保存 CHECKPOINT 和完整复算证据。",
                    directory: "/fixture/night-tasks", hostName: "dev-env", detail: "Kimi · 运行中",
                    online: scenario != "多组与离线" || i != 3, section: .running, canMarkReviewed: false, updatedAt: Date().timeIntervalSince1970 - Double(i * 60))
            }
            if scenario == "多组与离线" {
                workspace.groups = [
                    WorkItemGroup(name: "假期队列", goal: "", nextStep: "", sessions: [allSessions[0].reference]),
                    WorkItemGroup(name: "验收与复盘", goal: "", nextStep: "", sessions: [allSessions[0].reference])
                ]
            }
        }
    }
}

struct SessionActionsMenu: View {
    let model: WorkbenchModel
    let item: WorkspaceSession
    var body: some View { Button("演示会话操作") { model.notice = item.title } }
}

@main struct TaskGroupPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Perch 任务组 · 隔离预览") { GroupPreview().preferredColorScheme(.light) }
            .defaultSize(width: 1120, height: 820)
    }
}
private struct GroupPreview: View {
    @State private var model = WorkbenchModel()
    @State private var scenario: String = {
        guard let index = CommandLine.arguments.firstIndex(of: "-scenario"), index + 1 < CommandLine.arguments.count else { return "归属检查" }
        return CommandLine.arguments[index + 1]
    }()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务组 · 示例数据").foregroundStyle(.secondary)
                Spacer()
                Picker("预览状态", selection: $scenario) {
                    ForEach(["归属检查", "多组与离线", "尚未填写", "已填写", "空任务组", "未同步"], id: \.self) { Text($0) }
                }.frame(width: 190)
            }.padding(16)
            WorkbenchDashboard(attentionOnly: model.onlyAttention, projection: model.projection,
                context: DashboardContext(scope: model.activeScope), group: model.selectedGroup, hasSessionSearch: !model.search.isEmpty,
                onClearSessionFilters: { model.search = "" },
                groupHeader: AnyView(GroupWorkbenchHeader(model: model)),
                groupOverview: AnyView(TaskGroupOverview(model: model)),
                groupProgress: AnyView(GroupWorkbenchProgress(model: model)),
                groupHistory: AnyView(GroupWorkbenchHistory(model: model)),
                isArchiving: false, archiveResult: nil, onNewTask: { model.startNewTask() },
                onOpen: { model.open($0) }, onMarkReviewed: { model.markReviewed($0) },
                rowActions: { SessionActionsMenu(model: model, item: $0) },
                groupMemberships: { SessionGroupIndex(groups: model.workspace.groups).memberships[$0.id] ?? [] },
                onOpenGroup: { model.showHome(groupID: $0) }, onManageGroups: { model.groupingSession = $0 },
                onForgetRestoration: { _ in }, onUndoArchive: {}, onRetryArchive: {}, onStartLocal: {}, onConnectRemote: {},
                onShowInbox: { model.onlyAttention = true }, onShowAll: { model.showHome() },
                onShowHome: { model.onlyAttention = false }, onClearScope: { _ in model.showHome() },
                onClearAllScopes: { model.showHome(); model.search = "" })
        }.onAppear { model.seed(scenario) }.onChange(of: scenario) { _, value in model.seed(value) }
            .tint(WorkbenchTheme.accent)
            .sheet(item: $model.groupingSession) { SessionGroupsSheet(model: model, item: $0) }
            .sheet(isPresented: $model.showGroupEditor) { WorkItemGroupEditor(model: model, sessionsOnly: model.editingGroupSessionsOnly) }
            .alert("预览操作", isPresented: Binding(get: { model.notice != nil || model.showNewKimi }, set: { if !$0 { model.notice = nil; model.showNewKimi = false } })) {
                Button("好") { model.notice = nil; model.showNewKimi = false }
            } message: { Text(model.notice ?? "新建会话将关联到当前任务组") }
    }
}
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
