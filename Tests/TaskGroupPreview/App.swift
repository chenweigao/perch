import AppKit
import SwiftUI
import WorkbenchCore

// Layout fixture: production group page/editor/projections; an in-memory model
// replaces remote connections and persistence. No real workspace is loaded.
@MainActor final class WorkbenchModel: ObservableObject {
    @Published var allSessions: [WorkspaceSession] = []
    @Published var workspace = LocalWorkspace()
    @Published var workspaceError: String?
    @Published var isArchiving = false
    @Published var archiveResult: BatchArchiveRun?
    @Published var showNewKimi = false
    @Published var editingGroup: WorkItemGroup?
    @Published var editingGroupSessionsOnly = false
    @Published var showGroupEditor = false
    @Published var notice: String?
    @Published var managing = Set<String>()
    let configuredEnvironment = true
    func archiveSubject(_ item: WorkspaceSession) -> ArchiveSubject {
        ArchiveSubject(reference: item.reference, fingerprint: "fixture", busy: item.section == .running,
                       pendingInteraction: item.section == .attention, starred: false,
                       reviewed: item.section != .review, hasCompletionSignal: false)
    }
    func runBatchArchive(_ plan: BatchArchivePlan) { notice = "归档预览" }
    func undoBatchArchive() {}
    func retryBatchArchive() {}
    func editGroup(_ group: WorkItemGroup, sessionsOnly: Bool = false) {
        editingGroup = group; editingGroupSessionsOnly = sessionsOnly; showGroupEditor = true
    }
    func saveGroup(_ group: WorkItemGroup) { workspace.groups = [group] }
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
        workspace.groups = [group]
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
    @StateObject private var model = WorkbenchModel()
    @State private var scenario = "尚未填写"
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务组 · 示例数据").foregroundStyle(.secondary)
                Spacer()
                Picker("预览状态", selection: $scenario) {
                    ForEach(["尚未填写", "已填写", "空任务组", "未同步"], id: \.self) { Text($0) }
                }.frame(width: 190)
            }.padding(16)
            if let group = model.workspace.groups.first { TaskGroupPage(model: model, group: group).id(group.id) }
        }.onAppear { model.seed(scenario) }.onChange(of: scenario) { _, value in model.seed(value) }
            .sheet(isPresented: $model.showGroupEditor) { WorkItemGroupEditor(model: model, sessionsOnly: model.editingGroupSessionsOnly) }
            .alert("预览操作", isPresented: Binding(get: { model.notice != nil || model.showNewKimi }, set: { if !$0 { model.notice = nil; model.showNewKimi = false } })) {
                Button("好") { model.notice = nil; model.showNewKimi = false }
            } message: { Text(model.notice ?? "新建会话将关联到当前任务组") }
    }
}
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
