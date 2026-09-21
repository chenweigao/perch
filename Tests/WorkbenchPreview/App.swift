import AppKit
import SwiftUI
import WorkbenchCore

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
    private let host = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let now = Date().timeIntervalSince1970
    private var sessions: [WorkspaceSession] {
        if scenario == "首次使用" { return [] }
        var values: [WorkspaceSession] = []
        func add(_ id: String, _ title: String, _ section: WorkQueueSection, _ detail: String, _ age: Double) {
            let current: WorkQueueSection = reviewed.contains(id) ? .other : section
            values.append(WorkspaceSession(reference: SessionReference(hostID: host, terminalID: id, kind: .kimi),
                title: title, directory: "/fixture/perch", hostName: "演示环境", detail: reviewed.contains(id) ? "Kimi · 结果已查看" : detail,
                online: scenario != "离线", section: current, canMarkReviewed: current == .review,
                updatedAt: now - age))
        }
        if scenario == "需要处理" {
            for index in 1...4 { add("approval-\(index)", "确认工具栏调整方案 \(index)", .attention, "Kimi · 等待确认", Double(index * 120)) }
            for index in 1...7 { add("result-\(index)", "检查侧栏交互 \(index)", .review, "Kimi · 结果待查看", Double(index * 180)) }
        }
        if scenario != "空待处理" { add("running", "验证附件发送流程", .running, "Kimi · 运行中", 120) }
        for index in 1...8 { add("recent-\(index)", "探索新的 Agent 接入 \(index)", .other, "Kimi · 就绪", Double(index * 3600)) }
        return values
    }
    private var projection: DashboardProjection {
        let scoped = SessionCatalog.scope(sessions, starred: [], group: nil, hostFilter: nil, search: "", onlyAttention: inbox, showArchived: false)
        return DashboardProjection(sessions: scoped.sessions, subjects: [:], hasConfiguredEnvironment: scenario != "首次使用")
    }
    var body: some View {
        WorkspaceSplitView(newConversation: { notice = "新建会话" }) {
            WorkspaceSidebarShell(page: inbox ? .inbox : .home,
                                  attentionCount: SidebarProjection(sessions: sessions, starred: [], filter: .all).attentionCount,
                                  environmentSummary: "演示环境", onSearch: { notice = "搜索" }, onNew: { notice = "新建会话" },
                                  onHome: { inbox = false }, onInbox: { inbox = true }, onArchive: { notice = "已归档" }) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("任务组").font(.caption).foregroundStyle(.secondary)
                    Label("Perch", systemImage: "folder")
                    Label("推理仿真", systemImage: "folder")
                }.padding(16)
            } environments: { Text("离线示例数据").padding() }
        } header: {
            Text(inbox ? "待处理" : "工作台").font(.system(size: 13, weight: .semibold))
        } actions: {
            Picker("预览状态", selection: $scenario) {
                ForEach(["日常", "需要处理", "空待处理", "离线", "首次使用", "保存错误", "归档中"], id: \.self) { Text($0) }
            }.frame(width: 150)
        } content: {
            WorkbenchDashboard(attentionOnly: inbox, projection: projection,
                context: DashboardContext(storageError: scenario == "保存错误" ? "工作台保存失败（示例）：修改尚未保存。" : nil),
                isArchiving: scenario == "归档中", archiveResult: nil, onNewTask: { notice = "新建会话" },
                onOpen: { notice = "打开：" + $0.title }, onMarkReviewed: { reviewed.insert($0.reference.terminalID) },
                rowActions: { item in Button("会话菜单") { notice = item.title } },
                onForgetRestoration: { _ in }, onUndoArchive: {}, onRetryArchive: {}, onStartLocal: { notice = "检测本机" },
                onConnectRemote: { notice = "连接环境" }, onShowInbox: { inbox = true },
                onShowAll: { notice = "全部会话，共 \(sessions.count) 条" }, onShowHome: { inbox = false })
                .background(.white)
        }.alert("预览操作", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        } message: { Text(notice ?? "") }
    }
}

private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
