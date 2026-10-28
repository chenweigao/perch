import SwiftUI
import WorkbenchCore

/// Title changes follow workspace selection, independently of streaming state.
struct WorkbenchHeader: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    private var item: WorkspaceSession? { model.showDashboard ? nil : model.selectedItem }
    private var title: String {
        if model.showDashboard { return model.showArchived ? L("已归档") : model.onlyAttention ? L("待处理") : model.showSessionDirectory ? L("全部会话") : model.selectedGroup?.name ?? (model.showAllTaskGroups ? L("任务组") : L("工作台")) }
        return item?.title ?? L("正在恢复会话…")
    }
    var body: some View {
        Text(title).font(.system(size: 14, weight: .semibold))
            .lineLimit(1).truncationMode(.tail)
            .frame(minWidth: 100, maxWidth: 440, alignment: .leading)
            .help(item.map { "\($0.title)\n\($0.reference.kind.label) · \($0.hostName)\n\($0.directory)" } ?? title)
    }
}

/// Conversation controls stay in one native glass group.
struct WorkbenchHeaderActions: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    let kimi: KimiConnection
    let native: NativeAgentConnection
    private var item: WorkspaceSession? { model.showDashboard ? nil : model.selectedItem }
    private var isHome: Bool { model.showDashboard && !model.onlyAttention && !model.showArchived && !model.showSessionDirectory }
    /// The scope narrows the action queue, so it is offered on the workbench and on its
    /// inbox. The archive and the session directory list everything on purpose.
    private var showsScope: Bool {
        model.showDashboard && !model.showArchived && !model.showSessionDirectory
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
            if !model.showDashboard {
                // One glass capsule holds the conversation's controls.
                HStack(spacing: 0) {
                    if model.selectedHost != nil {
                        ChangesButton(model: model)
                        Button { model.toggleFileViewer() } label: {
                            WorkbenchToolbarSymbol(name: "folder")
                                .foregroundStyle(model.taskContextWindow.isShowing(.files) ? WorkbenchTheme.accent : .secondary)
                        }.buttonStyle(.plain).help("查看文件（只读）").accessibilityLabel("查看文件")
                            .accessibilityValue(model.taskContextWindow.isShowing(.files) ? "已展开" : "已收起")
                        TaskContextButton(model: model)
                    }
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
                    } label: { WorkbenchToolbarSymbol(name: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .frame(width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize).help("会话操作").accessibilityLabel("会话操作")
                }.padding(.horizontal, 4).workbenchControlSurface()
            } else {
                // The same single glass capsule as the conversation's controls.
                // Both sidebar and toolbar enter the same scoped workbench.
                HStack(spacing: 0) {
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
                        }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .frame(width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize)
                            .help("筛选工作台").accessibilityLabel("筛选工作台")
                    }
                    if model.selectedGroup != nil {
                        Button { model.editGroup(model.selectedGroup) } label: { WorkbenchToolbarSymbol(name: "pencil") }
                            .buttonStyle(.plain).help("编辑任务组").accessibilityLabel("编辑任务组")
                    }
                    Menu {
                        Button("会话…") { model.startNewTask() }
                        Button("远端终端…") { model.showNewTerminal = true }.disabled(model.selectedConnection?.online != true)
                        Button("任务组…") { model.editGroup() }
                    } label: { WorkbenchToolbarSymbol(name: "plus") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .frame(width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize).help("新建").accessibilityLabel("新建")
                    if isHome {
                        let projection = model.dashboardProjection
                        Menu {
                            Button(L("归档已查看结果 · \(projection.archiveCount)")) { model.runBatchArchive(projection.archivePlan) }
                                .disabled(projection.archiveCount == 0 || model.isArchiving)
                            Text("仅归档本轮正常结束且已查看的会话。")
                            if let reason = projection.blockedSummary { Text(reason) }
                        } label: { WorkbenchToolbarSymbol(name: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .frame(width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize).help("工作台操作").accessibilityLabel("工作台操作")
                    }
                }.padding(.horizontal, 4).workbenchControlSurface()
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}
