import SwiftUI
import WorkbenchCore

private let ink = WorkbenchTheme.ink
private let accent = WorkbenchTheme.accent
private let quiet = WorkbenchTheme.quiet

struct WorkbenchView: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    var body: some View {
        WorkbenchWorkspace(model: model).equatable()
            .ignoresSafeArea(.container, edges: .top).foregroundStyle(ink).tint(accent)
            .sheet(item: $model.inspectingSession, onDismiss: model.endInspection) { item in
                WorkspaceActionDetail(model: model, item: item).id(item.id)
            }
            .sheet(item: $model.projectOverview) { location in ProjectWorkbenchSheet(model: model, location: location) }
            .sheet(isPresented: $model.showFollowUps) { FollowUpManager(model: model) }
            .sheet(isPresented: $model.showGroupSuggestions) { GroupSuggestionsSheet(model: model) }
            .sheet(isPresented: $model.showGroupEditor) { WorkItemGroupEditor(model: model, sessionsOnly: model.editingGroupSessionsOnly) }
            .sheet(isPresented: $model.showAddHost, onDismiss: model.setupDismissed) {
                AddHostSheet(model: model, host: model.setupHost, initialProvider: model.setupProvider)
            }
            .sheet(isPresented: $model.showSessionSearch) {
                UnifiedSearchView(model: model)
            }
            .sheet(isPresented: $model.showLocalSetup) { LocalAgentSetupSheet(model: model) }
            .onAppear {
                let actions = SelectionActionsController.shared
                actions.quoteAvailable = { [weak model] in model?.canQuoteSelection ?? false }
                actions.quoteHandler = { [weak model] text in model?.quoteSelection(text) }
                actions.start()
            }
            .onChange(of: model.showFileViewer, initial: true) { _, visible in
                if visible { model.fileWindow.show(model: model) }
                else { model.fileWindow.close() }
            }
            .onChange(of: model.selectedReference) { _, _ in SelectionActionsController.shared.hide() }
            .onChange(of: model.showDashboard) { _, _ in SelectionActionsController.shared.hide() }
            .sheet(item: $model.renamingSession) { item in RenameSessionSheet(model: model, item: item) }
            .sheet(item: $model.groupingSession) { item in SessionGroupsSheet(model: model, item: item) }
            .alert(L("删除会话？"), isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }), presenting: model.pendingDeletion) { item in
                Button("取消", role: .cancel) { model.pendingDeletion = nil }
                Button(L("删除会话"), role: .destructive) { model.pendingDeletion = nil; model.deleteConfirmed(item) }
            } message: { item in
                Text(model.usesLegacyKimiConnection(item.reference) ? L("将从 Kimi 服务删除「\(item.title)」及其历史，无法撤销。只想收起时，请使用归档。") : L("将删除工作台中的「\(item.title)」及对话记录。Agent 自身保存的历史仍保留。"))
            }
            .alert("移除机器？", isPresented: Binding(get: { model.pendingHostRemoval != nil }, set: { if !$0 { model.pendingHostRemoval = nil } }), presenting: model.pendingHostRemoval) { host in
                Button("取消", role: .cancel) { model.pendingHostRemoval = nil }
                Button("移除机器", role: .destructive) { model.pendingHostRemoval = nil; model.removeHost(host) }
            } message: { host in
                Text("将断开「\(host.name)」并从这台 Mac 的列表中移除。远端的 Agent 与终端继续运行，你的 SSH 配置不变；该机器上的会话会从列表消失，重新添加后可再出现。")
            }
            .alert("操作未完成", isPresented: Binding(get: { model.managementError != nil }, set: { if !$0 { model.managementError = nil } })) {
                Button("知道了") { model.managementError = nil }
            } message: { Text(model.managementError ?? "") }
    }
}

/// Sheet state and sidebar selection must not replace all four AppKit hosting roots.
/// Each hosted view observes the model directly; the container changes only when
/// the workspace model itself changes.
private struct WorkbenchWorkspace: View, Equatable {
    let model: WorkbenchModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model }

    var body: some View {
        let inspectorVisible = model.taskContextWindow.embeddedVisible &&
            !model.showDashboard && !model.draftingNewTask
        let island = model.commandLineIsland
        let commandLine: (() -> AnyView)? = island.target == nil ? nil : {
            AnyView(CommandLineIslandView(
                state: island,
                connection: model.connections.first { $0.id == island.target?.hostID },
                currentTarget: model.commandLineTarget,
                onRetarget: { model.retargetCommandLineIsland() },
                onRestart: { model.restartCommandLineIsland() }))
        }
        WorkspaceSplitView(
            newConversation: { model.startNewTask() },
            canNavigate: { model.canNavigate($0) },
            navigate: { model.navigate($0) },
            inspectorVisible: inspectorVisible,
            commandLineVisible: island.visible && model.commandLineTarget != nil,
            commandLine: commandLine,
            sidebar: { WorkbenchSidebar(model: model) },
            header: { WorkbenchHeader(model: model, kimi: model.kimi, native: model.native) },
            actions: { WorkbenchHeaderActions(model: model, kimi: model.kimi, native: model.native) },
            inspector: { WorkspaceInspector(model: model) },
            content: { WorkbenchDetail(model: model) }
        )
    }
}

private struct WorkbenchDetail: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel

    var body: some View {
        conversation.environment(\.conversationPresentations, model.conversationPresentations)
    }

    @ViewBuilder private var conversation: some View {
        let index = model.groupIndex
        VStack(spacing: 0) {
            if let notice = model.taskNotice {
                HStack {
                    Button { model.openNotifiedTask(notice.sessionID) } label: {
                        Label("\(notice.message) · \(notice.title)", systemImage: notice.kind == .completed ? "checkmark.circle" : notice.kind == .stalled ? "clock" : "exclamationmark.circle").lineLimit(1)
                    }.buttonStyle(.plain)
                    Spacer()
                    // Natural size: a 28 pt target would make the notice bar taller.
                    Button { model.taskNotice = nil } label: { Image(systemName: "xmark") }
                        .help("关闭提示").accessibilityLabel("关闭提示")
                }.font(.system(size: 12)).padding(10).background(.orange.opacity(0.06))
            }
            if !model.draftingNewTask && model.showConversationFind && (model.showKimi || model.showNative) {
                ConversationFindBar(model: model, kimi: model.kimi, native: model.native)
            }
            detailContent(index: index)
        }.frame(minWidth: WorkspaceLayoutMetrics.inspectorReadingMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchTheme.contentBackground)
    }

    // Kept as a separate expression: the branch set is heavy enough that the
    // compiler's expression timer trips when it is inlined into `conversation`.
    @ViewBuilder private func detailContent(index: SessionGroupIndex) -> some View {
        ZStack {
                if model.draftingNewTask {
                    NewTaskView(model: model, native: model.native, kimi: model.kimi)
                } else if model.showDashboard {
                    if model.showArchived { ArchivedSessionsView(model: model) }
                    else if model.showSessionDirectory { SessionDirectoryView(model: model) }
                    else {
                        WorkbenchDashboard(
                            homeSection: $model.homeSection,
                            attentionOnly: model.onlyAttention, changes: model.dashboardChanges,
                            onAcknowledgeChanges: { model.acknowledgeDashboardChanges() },
                            onSuggestGroups: { model.showGroupSuggestions = true },
                            projection: model.dashboardProjection,
                            context: model.dashboardContext, group: model.selectedGroup, hasSessionSearch: !model.search.isEmpty,
                            onClearSessionFilters: { model.clearSessionFilters() },
                            groupHeader: AnyView(GroupWorkbenchHeader(model: model)),
                            projectOverview: AnyView(ProjectWorkbenchOverview(model: model)),
                            groupOverview: AnyView(TaskGroupOverview(model: model)),
                            groupProgress: AnyView(GroupWorkbenchProgress(model: model)),
                            groupHistory: AnyView(GroupWorkbenchHistory(model: model)),
                            isArchiving: model.isArchiving,
                            archiveResult: model.archiveResult,
                            onNewTask: { model.startNewTask() },
                            onOpen: { item in
                                if item.section == .attention || item.section == .review { model.inspect(item) }
                                else { model.open(item) }
                            },
                            onMarkReviewed: { model.markReviewed($0) },
                            rowActions: { SessionActionsMenu(model: model, item: $0) },
                            groupMemberships: { index.memberships[$0.id] ?? [] },
                            onOpenGroup: { model.showHome(groupID: $0) },
                            onManageGroups: { model.groupingSession = $0 },
                            onForgetRestoration: { model.forgetRestoration($0) },
                            onDismissRestoreReport: { model.dismissRestoreReport() },
                            onOpenRestoreEntry: { model.openRestoreEntry($0) },
                            onUndoArchive: { model.undoBatchArchive() },
                            onRetryArchive: { model.retryBatchArchive() },
                            onStartLocal: { model.showLocalSetup = true },
                            onConnectRemote: { model.configureHost() },
                            onShowInbox: { model.showInbox(groupID: model.selectedGroupID) },
                            onShowAll: { model.showAllSessions() },
                            onShowHome: { model.showHome(groupID: model.selectedGroupID) },
                            onClearScope: { model.clearScope($0) },
                            onClearAllScopes: { model.clearScope() })
                            .id(DashboardDestination(groupID: model.selectedGroupID,
                                                     hostID: model.scopeHost?.id, inbox: model.onlyAttention))
                    }
                }
                else if model.showKimi {
                    KimiSelectionContent(model: model, connection: model.kimi)
                } else if model.showNative {
                    let connection = model.native
                    NativeAgentView(connection: connection, onResultDisplayed: { model.reviewDisplayed($0, on: connection.host.id) })
                        .id(ObjectIdentifier(connection))
                }
                else { unavailableSession }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableSession: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(model.kimi.loading && model.showKimi ? L("正在读取对话…") : L("等待恢复会话")).font(.title3)
            Text(L("连接后读取原会话；已不可用的会话不会自动新建。"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("返回工作台") { model.showHome(groupID: model.selectedGroupID) }
        }.padding(30)
    }
}

/// Destination changes start at the goal heading; live catalog updates keep scroll position.
private struct DashboardDestination: Hashable {
    let groupID: UUID?
    let hostID: UUID?
    let inbox: Bool
}
