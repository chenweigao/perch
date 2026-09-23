import SwiftUI
import WorkbenchCore

/// Title changes follow workspace selection, independently of streaming state.
struct WorkbenchHeader: View {
    @UILocalization private var L
    @ObservedObject var model: WorkbenchModel
    private var item: WorkspaceSession? { model.showDashboard ? nil : model.selectedItem }
    private var title: String {
        if model.showDashboard { return model.showArchived ? L("已归档") : model.onlyAttention ? L("待处理") : model.showSessionDirectory ? L("全部会话") : model.selectedGroup?.name ?? L("工作台") }
        return item?.title ?? L("正在恢复会话…")
    }
    var body: some View {
        HStack(spacing: WorkbenchChrome.labelSpacing) {
            Image(systemName: item?.reference.kind.symbol ?? (model.showArchived ? "archivebox" : model.onlyAttention ? "tray" : model.showSessionDirectory ? "list.bullet" : model.selectedGroup == nil ? "square.grid.2x2" : "folder"))
                .font(.system(size: WorkbenchChrome.symbolSize, weight: .regular)).imageScale(.medium).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                if let item {
                    HStack(spacing: 5) {
                        Text(item.reference.kind.label)
                        if !item.hostName.isEmpty {
                            Text("·")
                            HostIdentityLabel(hostID: item.reference.hostID, name: item.hostName)
                        }
                    }
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
        }.frame(minWidth: 100, maxWidth: 440, alignment: .leading)
            .help(item.map { "\($0.title)\n\($0.reference.kind.label) · \($0.hostName)\n\($0.directory)" } ?? title)
    }
}

/// Only toolbar status observes the active stream; title and sidebar do not.
struct WorkbenchHeaderActions: View {
    @UILocalization private var L
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var kimi: KimiConnection
    @ObservedObject var native: NativeAgentConnection
    private var item: WorkspaceSession? { model.showDashboard ? nil : model.selectedItem }
    private var status: String? {
        if model.showDashboard { return nil }
        if model.showKimi, let session = kimi.conversation?.snapshot.session, session.busy { return session.status }
        if model.showNative, let session = native.snapshot {
            if !session.interactions.isEmpty { return L("等你处理") }
            if session.busy { return L("运行中") }
        }
        return nil
    }
    private var isHome: Bool { model.showDashboard && !model.onlyAttention && !model.showArchived && !model.showSessionDirectory && model.selectedGroup == nil }
    /// The scope narrows the action queue, so it is offered on the workbench and on its
    /// inbox. The archive and the session directory list everything on purpose.
    private var showsScope: Bool {
        model.showDashboard && !model.showArchived && !model.showSessionDirectory && model.selectedGroup == nil
    }
    /// Bound to the resolved facet, so a group that no longer exists reads as "all"
    /// rather than as an invisible selection.
    private var groupScope: Binding<UUID?> {
        Binding(get: { model.scopeGroup?.id }, set: { model.setScope(groupID: $0) })
    }
    private var hostScope: Binding<UUID?> {
        Binding(get: { model.scopeHost?.id }, set: { model.setScope(hostID: $0) })
    }
    var body: some View {
        HStack(spacing: WorkbenchChrome.controlSpacing) {
            if let item, !item.directory.isEmpty {
                Label(URL(fileURLWithPath: item.directory).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 110).fixedSize(horizontal: true, vertical: false).help(item.directory)
            }
            if let status {
                HStack(spacing: 5) {
                    Circle().fill((model.showKimi ? kimi.conversation?.snapshot.pendingApprovals.isEmpty == false || kimi.conversation?.snapshot.pendingQuestions.isEmpty == false : native.snapshot?.interactions.isEmpty == false) ? Color.orange : Color.secondary).frame(width: 5, height: 5)
                    Text(status).font(.system(size: 11))
                }.foregroundStyle(.secondary).fixedSize()
            }
            if !model.showDashboard, model.selectedHost != nil {
                Button { model.toggleFileViewer() } label: {
                    WorkbenchToolbarSymbol(name: "doc.text.magnifyingglass").workbenchControlSurface()
                }.buttonStyle(.plain).help("查看远端文件（只读）").accessibilityLabel("查看远端文件")
            }
            if !model.showDashboard {
                Menu {
                    if model.showKimi { Button("同步会话") { kimi.reloadSelected() }.disabled(!kimi.online || kimi.loading) }
                    else if model.showNative { Button("重新连接") { native.connect() } }
                    else {
                        Button(model.selectedConnection?.wantsConnection == true ? L("断开本地连接") : L("连接终端")) {
                            if model.selectedConnection?.wantsConnection == true { model.selectedConnection?.disconnect() }
                            else { model.selectedConnection?.connect() }
                        }
                        Button("新建远端终端…") { model.showNewTerminal = true }
                    }
                    if let item { Divider(); SessionActionsMenu(model: model, item: item) }
                } label: { WorkbenchToolbarSymbol(name: "ellipsis").workbenchControlSurface() }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize).help("会话操作").accessibilityLabel("会话操作")
            } else {
                // One control owns the queue's scope. Two menus about task groups, one
                // filtering and one navigating, would not tell those apart; the sidebar
                // and each session's menu already lead to a group's own page.
                if showsScope {
                    Menu {
                        Picker("任务组", selection: groupScope) {
                            Text("全部任务组").tag(UUID?.none)
                            ForEach(model.workspace.groups) { group in Text(group.name).tag(Optional(group.id)) }
                        }
                        Picker("机器", selection: hostScope) {
                            Text("全部机器").tag(UUID?.none)
                            ForEach(model.connections) { connection in
                                Text(connection.host.name).tag(Optional(connection.id))
                            }
                        }
                        if !model.activeScope.isEmpty {
                            Divider()
                            Button("清除筛选") { model.clearScope() }
                        }
                    } label: {
                        WorkbenchToolbarSymbol(name: model.activeScope.isEmpty
                            ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                            .workbenchControlSurface()
                    }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .frame(width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize)
                        .help("筛选工作台").accessibilityLabel("筛选工作台")
                }
                if model.selectedGroup != nil {
                    Button { model.editGroup(model.selectedGroup) } label: { WorkbenchToolbarSymbol(name: "pencil").workbenchControlSurface() }
                        .buttonStyle(.plain).help("编辑任务组").accessibilityLabel("编辑任务组")
                }
                Menu {
                    Button("原生对话…") { model.startNewTask() }
                    Button("远端终端…") { model.showNewTerminal = true }.disabled(model.selectedConnection?.online != true)
                    Button("任务组…") { model.editGroup() }
                } label: { WorkbenchToolbarSymbol(name: "plus").workbenchControlSurface() }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize).help("新建").accessibilityLabel("新建")
                if isHome {
                    let projection = model.dashboardProjection
                    Menu {
                        Button(L("归档已查看结果 · \(projection.archiveCount)")) { model.runBatchArchive(projection.archivePlan) }
                            .disabled(projection.archiveCount == 0 || model.isArchiving)
                        Text("仅归档本轮正常结束且已查看的会话。")
                        if let reason = projection.blockedSummary { Text(reason) }
                    } label: { WorkbenchToolbarSymbol(name: "ellipsis").workbenchControlSurface() }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .frame(width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize).help("工作台操作").accessibilityLabel("工作台操作")
                }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}
