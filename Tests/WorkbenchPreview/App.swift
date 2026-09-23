import AppKit
import SwiftUI
import WorkbenchCore

// Group identity has to be stable across view passes, or the scope picker's tags and
// the badges would refer to a different group every time the body is evaluated.
private let demoHost = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let secondHost = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private func demoReference(_ id: String, on hostID: UUID = demoHost) -> SessionReference {
    SessionReference(hostID: hostID, terminalID: id, kind: .kimi)
}
private let demoGroups: [WorkItemGroup] = [
    WorkItemGroup(name: "Perch", goal: "", nextStep: "",
                  sessions: ["approval-1", "approval-2", "result-1", "result-2", "running"].map { demoReference($0) }),
    WorkItemGroup(name: "推理仿真", goal: "", nextStep: "",
                  sessions: [demoReference("result-2"), demoReference("recent-1"),
                             demoReference("remote-1", on: secondHost)]),
]
private let demoIndex = SessionGroupIndex(groups: demoGroups)
/// Ordered, so the preview's machine picker does not reshuffle between launches.
private let demoHosts: [(id: UUID, name: String)] = [(demoHost, "演示环境"), (secondHost, "另一台机器")]
private let hostNames = Dictionary(uniqueKeysWithValues: demoHosts.map { ($0.id, $0.name) })

@main struct WorkbenchPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Perch 工作台 · 隔离预览") { DashboardPreview().preferredColorScheme(.light) }
            .defaultSize(width: 1120, height: 820)
        Settings { Text("示例数据，不连接 Agent。").padding() }
    }
}

private struct DashboardPreview: View {
    @State private var inbox = false
    @State private var scenario = "日常"
    @State private var reviewed: Set<String> = []
    @State private var notice: String?
    @State private var scope = DashboardScope()
    private let host = demoHost
    private let now = Date().timeIntervalSince1970
    private var sessions: [WorkspaceSession] {
        if scenario == "首次使用" { return [] }
        var values: [WorkspaceSession] = []
        func add(_ id: String, _ title: String, _ section: WorkQueueSection, _ detail: String, _ age: Double,
                 on hostID: UUID = demoHost) {
            let current: WorkQueueSection = reviewed.contains(id) ? .other : section
            values.append(WorkspaceSession(reference: SessionReference(hostID: hostID, terminalID: id, kind: .kimi),
                title: title, directory: "/fixture/perch", hostName: hostNames[hostID] ?? "演示环境",
                detail: reviewed.contains(id) ? "Kimi · 结果已查看" : detail,
                online: scenario != "离线", section: current, canMarkReviewed: current == .review,
                updatedAt: now - age))
        }
        if scenario == "需要处理" {
            for index in 1...4 { add("approval-\(index)", "确认工具栏调整方案 \(index)", .attention, "Kimi · 等待确认", Double(index * 120)) }
            for index in 1...7 { add("result-\(index)", "检查侧栏交互 \(index)", .review, "Kimi · 结果待查看", Double(index * 180)) }
        }
        if scenario != "空待处理" { add("running", "验证附件发送流程", .running, "Kimi · 运行中", 120) }
        for index in 1...8 { add("recent-\(index)", "探索新的 Agent 接入 \(index)", .other, "Kimi · 就绪", Double(index * 3600)) }
        // A second machine, so the group and machine facets can be combined and can
        // contradict each other, which is what the empty filtered state is for.
        add("remote-1", "远端推理基准复跑", .review, "Kimi · 结果待查看", 900, on: secondHost)
        add("remote-2", "远端日志采样", .other, "Kimi · 就绪", 5400, on: secondHost)
        return values
    }
    private var scopeGroup: WorkItemGroup? { demoGroups.first { $0.id == scope.groupID } }
    private var activeScope: ActiveScope {
        ActiveScope(groupName: scopeGroup?.name, hostName: scope.hostID.flatMap { hostNames[$0] })
    }
    private var projection: DashboardProjection {
        let scoped = SessionCatalog.scope(sessions, starred: [], group: scopeGroup, hostFilter: scope.hostID,
                                          search: "", onlyAttention: inbox, showArchived: false)
        return DashboardProjection(sessions: scoped.sessions, subjects: [:],
                                   hasConfiguredEnvironment: scenario != "首次使用",
                                   filtered: !activeScope.isEmpty)
    }
    var body: some View {
        WorkspaceSplitView(newConversation: { notice = "新建会话" }) {
            WorkspaceSidebarShell(page: inbox ? .inbox : .home,
                                  attentionCount: SidebarProjection(sessions: sessions, starred: [], filter: .all).attentionCount,
                                  environmentSummary: "演示环境", onSearch: { notice = "搜索" }, onNew: { notice = "新建会话" },
                                  onHome: { inbox = false }, onInbox: { inbox = true }, onArchive: { notice = "已归档" }) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("任务组").font(.caption).foregroundStyle(.secondary)
                    ForEach(demoGroups) { group in
                        Label(group.name, systemImage: "folder")
                    }
                }.padding(16)
            } environments: { Text("离线示例数据").padding() }
        } header: {
            Text(inbox ? "待处理" : "工作台").font(.system(size: 13, weight: .semibold))
        } actions: {
            HStack(spacing: 10) {
                Picker("预览状态", selection: $scenario) {
                    ForEach(["日常", "需要处理", "空待处理", "离线", "首次使用", "保存错误", "归档中"], id: \.self) { Text($0) }
                }.frame(width: 130)
                Picker("任务组", selection: Binding(get: { scope.groupID }, set: { scope.groupID = $0 })) {
                    Text("全部任务组").tag(UUID?.none)
                    ForEach(demoGroups) { group in Text(group.name).tag(Optional(group.id)) }
                }.frame(width: 130)
                Picker("机器", selection: Binding(get: { scope.hostID }, set: { scope.hostID = $0 })) {
                    Text("全部机器").tag(UUID?.none)
                    ForEach(demoHosts, id: \.id) { entry in Text(entry.name).tag(Optional(entry.id)) }
                }.frame(width: 120)
            }
        } content: {
            WorkbenchDashboard(attentionOnly: inbox, projection: projection,
                context: DashboardContext(storageError: scenario == "保存错误" ? "工作台保存失败（示例）：修改尚未保存。" : nil,
                                          scope: activeScope),
                isArchiving: scenario == "归档中", archiveResult: nil, onNewTask: { notice = "新建会话" },
                onOpen: { notice = "打开：" + $0.title }, onMarkReviewed: { reviewed.insert($0.reference.terminalID) },
                rowActions: { item in Button("会话菜单") { notice = item.title } },
                groupNames: { demoIndex[$0.id] },
                onForgetRestoration: { _ in }, onUndoArchive: {}, onRetryArchive: {}, onStartLocal: { notice = "检测本机" },
                onConnectRemote: { notice = "连接环境" }, onShowInbox: { inbox = true },
                onShowAll: { notice = "全部会话，共 \(sessions.count) 条" }, onShowHome: { inbox = false },
                onClearScope: { facet in
                    if facet.kind == .group { scope.groupID = nil } else { scope.hostID = nil }
                },
                onClearAllScopes: { scope = DashboardScope() })
                .background(.white)
        }.alert("预览操作", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        } message: { Text(notice ?? "") }
    }
}

private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
