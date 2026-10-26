import GhosttyTerminal
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
            .sheet(isPresented: $model.showRenderReport) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("终端显示信息").font(.headline)
                    Text(model.renderReport).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("关闭") { model.showRenderReport = false }.keyboardShortcut(.cancelAction)
                    }
                }.padding(WorkbenchTheme.Dialog.padding).frame(minWidth: 550)
            }
            .sheet(item: $model.inspectingSession, onDismiss: model.endInspection) { item in
                WorkspaceActionDetail(model: model, item: item).id(item.id)
            }
            .sheet(item: $model.projectOverview) { location in ProjectWorkbenchSheet(model: model, location: location) }
            .sheet(isPresented: $model.showFollowUps) { FollowUpManager(model: model) }
            .sheet(isPresented: $model.showGroupSuggestions) { GroupSuggestionsSheet(model: model) }
            .sheet(isPresented: $model.showGroupEditor) { WorkItemGroupEditor(model: model, sessionsOnly: model.editingGroupSessionsOnly) }
            .sheet(isPresented: $model.showAddHost, onDismiss: model.setupDismissed) { AddHostSheet(model: model, host: model.setupHost) }
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
            .sheet(isPresented: $model.showNewTerminal) {
                if let connection = model.selectedConnection { NewTerminalSheet(connection: connection, model: model) }
            }
            .sheet(item: $model.renamingSession) { item in RenameSessionSheet(model: model, item: item) }
            .sheet(item: $model.groupingSession) { item in SessionGroupsSheet(model: model, item: item) }
            .alert(model.pendingDeletion?.reference.kind == .terminal ? L("结束远端终端？") : L("删除会话？"), isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }), presenting: model.pendingDeletion) { item in
                Button("取消", role: .cancel) { model.pendingDeletion = nil }
                Button(item.reference.kind == .terminal ? L("结束终端") : L("删除会话"), role: .destructive) { model.pendingDeletion = nil; model.deleteConfirmed(item) }
            } message: { item in
                Text(item.reference.kind == .kimi ? L("将从 Kimi 服务删除「\(item.title)」及其历史，无法撤销。只想收起时，请使用归档。") : item.reference.kind != .terminal ? L("将删除工作台中的「\(item.title)」及对话记录。Agent 自身保存的历史仍保留。") : L("将关闭「\(item.title)」的远端进程，运行中的任务会中断。只想整理列表时，请使用本机归档。"))
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
        WorkspaceSplitView(
            newConversation: { model.startNewTask() },
            canNavigate: { model.canNavigate($0) },
            navigate: { model.navigate($0) },
            inspectorVisible: inspectorVisible,
            sidebar: { WorkbenchSidebar(model: model) },
            header: { WorkbenchHeader(model: model) },
            actions: { WorkbenchHeaderActions(model: model, kimi: model.kimi, native: model.native) },
            inspector: {
                TaskContextView(model: model,
                    detach: { model.taskContextWindow.show(model: model) },
                    close: { model.taskContextWindow.embeddedVisible = false })
            },
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
                        Label("\(notice.message) · \(notice.title)", systemImage: notice.kind == .completed ? "checkmark.circle" : "exclamationmark.circle").lineLimit(1)
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
            ZStack {
                if model.draftingNewTask {
                    NewTaskView(model: model, native: model.native, kimi: model.kimi)
                } else if model.showDashboard {
                    if model.showArchived { ArchivedSessionsView(model: model) }
                    else if model.showSessionDirectory { SessionDirectoryView(model: model) }
                    else {
                        WorkbenchDashboard(
                            attentionOnly: model.onlyAttention, changes: model.dashboardChanges,
                            onAcknowledgeChanges: { model.acknowledgeDashboardChanges() },
                            onSuggestGroups: { model.showGroupSuggestions = true },
                            projection: model.dashboardProjection,
                            context: model.dashboardContext, group: model.selectedGroup, hasSessionSearch: !model.search.isEmpty,
                            onClearSessionFilters: { model.clearSessionFilters() },
                            groupHeader: AnyView(GroupWorkbenchHeader(model: model)),
                            groupOverview: AnyView(VStack(alignment: .leading, spacing: 24) { ProjectWorkbenchOverview(model: model); TaskGroupOverview(model: model) }),
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
                else if model.selectedTerminal == nil { unavailableSession }
                ForEach(model.terminals) { terminal in
                    VStack(spacing: 0) {
                        TerminalPane(terminal: terminal, model: model)
                        StatusBar(connection: model.connections.first { $0.id == terminal.hostID }!)
                    }.id(terminal.incarnation)
                        .opacity(!model.showDashboard && !model.draftingNewTask && model.selectedTerminalID == terminal.id ? 1 : 0)
                        .allowsHitTesting(!model.showDashboard && !model.draftingNewTask && model.selectedTerminalID == terminal.id)
                        .accessibilityHidden(model.showDashboard || model.draftingNewTask || model.selectedTerminalID != terminal.id)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchTheme.contentBackground)
    }

    private var unavailableSession: some View {
        VStack(spacing: 14) {
            Image(systemName: model.showKimi ? "bubble.left" : "terminal").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(model.kimi.loading && model.showKimi ? L("正在读取对话…") : L("等待恢复会话")).font(.title3)
            Text(model.showKimi ? (model.kimi.actionError ?? model.kimi.error ?? L("连接后读取原会话；已不可用的会话不会自动新建。")) : L("连接后接回原终端；已结束的会话不会自动新建。"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("返回工作台") { model.showHome(groupID: model.selectedGroupID) }
        }.padding(30)
    }
}

private struct TerminalPane: View {
    @ObservedObject var terminal: AttachedTerminal
    @Bindable var model: WorkbenchModel
    var body: some View {
        VStack(spacing: 0) {
            TerminalSurfaceView(context: terminal.context)
            if terminal.ended {
                HStack {
                    Text("终端连接已结束；可重新接入仍在运行的会话。").font(.system(size: 12))
                    Spacer()
                    Button("重新接入") { model.reconnectTerminal(terminal) }
                }.padding(14).background(Color.primary.opacity(0.035))
            }
        }.background(WorkbenchTheme.contentBackground)
    }
}

private struct StatusBar: View {
    @UILocalization private var L
    @ObservedObject var connection: HostConnection
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(connection.online ? Color.green : quiet).frame(width: 5, height: 5)
            Text(connection.state(locale: L.locale))
            if let version = connection.snapshot?.version { Text("·"); Text("Herdr \(version)") }
            Spacer()
            if let date = connection.updatedAt { Text("状态更新于 \(date.formatted(date: .omitted, time: .standard))") }
            Text("·"); Text("原生终端")
        }.font(.system(size: 11)).foregroundStyle(quiet).padding(.horizontal, 18).padding(.vertical, 9)
            .help(connection.error ?? L("会话状态每 3 秒同步一次；终端内容实时传输"))
    }
}

/// Destination changes start at the goal heading; live catalog updates keep scroll position.
private struct DashboardDestination: Hashable {
    let groupID: UUID?
    let hostID: UUID?
    let inbox: Bool
}
