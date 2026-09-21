import GhosttyTerminal
import SwiftUI
import WorkbenchCore

private let ink = Color(red: 0.16, green: 0.18, blue: 0.23)
private let accent = Color(red: 0.16, green: 0.16, blue: 0.17)
private let quiet = Color(red: 0.48, green: 0.51, blue: 0.58)
private let paper = Color(red: 0.965, green: 0.965, blue: 0.96)

struct WorkbenchView: View {
    @UILocalization private var L
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        WorkbenchWorkspace(model: model).equatable()
            .ignoresSafeArea(.container, edges: .top).foregroundStyle(ink).tint(accent)
            .sheet(isPresented: $model.showRenderReport) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("终端显示信息").font(.headline)
                    Text(model.renderReport).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button("关闭") { model.showRenderReport = false }.keyboardShortcut(.cancelAction)
                }.padding(26).frame(minWidth: 550)
            }
            .sheet(isPresented: $model.showGroupEditor) { WorkItemGroupEditor(model: model, sessionsOnly: model.editingGroupSessionsOnly) }
            .sheet(isPresented: $model.showAddHost) { AddHostSheet(model: model) }
            .sheet(isPresented: $model.showLocalSetup) { LocalAgentSetupSheet(model: model) }
            .onAppear {
                let actions = SelectionActionsController.shared
                actions.quoteAvailable = { [weak model] in model?.canQuoteSelection ?? false }
                actions.quoteHandler = { [weak model] text in model?.quoteSelection(text) }
                actions.start()
            }
            .sheet(isPresented: $model.showNewTerminal) { NewTerminalSheet(connection: model.selectedConnection, model: model) }
            .sheet(isPresented: $model.showNewKimi) { NewConversationSheet(model: model, native: model.native, kimi: model.kimi) }
            .sheet(item: $model.renamingSession) { item in RenameSessionSheet(model: model, item: item) }
            .sheet(item: $model.groupingSession) { item in SessionGroupsSheet(model: model, item: item) }
            .alert(model.pendingDeletion?.reference.kind == .terminal ? L("结束远端终端？") : L("删除会话？"), isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }), presenting: model.pendingDeletion) { item in
                Button("取消", role: .cancel) { model.pendingDeletion = nil }
                Button(item.reference.kind == .terminal ? L("结束终端") : L("删除会话"), role: .destructive) { model.pendingDeletion = nil; model.deleteConfirmed(item) }
            } message: { item in
                Text(item.reference.kind == .kimi ? L("将从 Kimi 服务删除「\(item.title)」及其历史，无法撤销。只想收起时，请使用归档。") : item.reference.kind != .terminal ? L("将删除工作台中的「\(item.title)」及对话记录。Agent 自身保存的历史仍保留。") : L("将关闭「\(item.title)」的远端进程，运行中的任务会中断。只想整理列表时，请使用本机归档。"))
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
        WorkspaceSplitView(
            newConversation: { model.showNewKimi = true },
            sidebar: { WorkbenchSidebar(model: model) },
            header: { WorkbenchHeader(model: model) },
            actions: { WorkbenchHeaderActions(model: model, kimi: model.kimi, native: model.native) },
            content: { WorkbenchDetail(model: model) }
        )
    }
}

private struct WorkbenchDetail: View {
    @UILocalization private var L
    @ObservedObject var model: WorkbenchModel

    var body: some View {
        HStack(spacing: 0) {
            conversation
            if model.showFileViewer && !model.showDashboard {
                Divider()
                RemoteFilePanel(browser: model.fileBrowser) { model.toggleFileViewer() }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if let notice = model.taskNotice {
                HStack {
                    Button { model.openNotifiedTask(notice.sessionID) } label: {
                        Label("\(notice.message) · \(notice.title)", systemImage: notice.kind == .completed ? "checkmark.circle" : "exclamationmark.circle").lineLimit(1)
                    }.buttonStyle(.plain)
                    Spacer()
                    Button { model.taskNotice = nil } label: { Image(systemName: "xmark") }
                }.font(.system(size: 12)).padding(10).background(.orange.opacity(0.06))
            }
            if model.showConversationFind && (model.showKimi || model.showNative) {
                ConversationFindBar(model: model, kimi: model.kimi, native: model.native)
            }
            ZStack {
                if model.showDashboard {
                    if model.showArchived { ArchivedSessionsView(model: model) }
                    else if model.showSessionDirectory { SessionDirectoryView(model: model) }
                    else if let group = model.selectedGroup { TaskGroupPage(model: model, group: group).id(group.id) }
                    else {
                        WorkbenchDashboard(
                            attentionOnly: model.onlyAttention, projection: model.dashboardProjection,
                            context: model.dashboardContext, groups: model.workspace.groups,
                            selectedGroupID: model.selectedGroupID, isArchiving: model.isArchiving,
                            archiveResult: model.archiveResult,
                            onSelectScope: { model.showHome(groupID: $0) },
                            onNewTask: { model.showNewKimi = true },
                            onOpen: { model.open($0) },
                            onMarkReviewed: { model.markReviewed($0) },
                            onEditGroup: { model.editGroup(model.selectedGroup) },
                            onResume: { model.open($0, pinned: true) },
                            onForgetRestoration: { model.forgetRestoration($0) },
                            onArchive: { model.runBatchArchive(model.dashboardProjection.archivePlan) },
                            onUndoArchive: { model.undoBatchArchive() },
                            onRetryArchive: { model.retryBatchArchive() },
                            onStartLocal: { model.showLocalSetup = true },
                            onConnectRemote: { model.showAddHost = true })
                    }
                }
                else if model.showKimi {
                    KimiSelectionContent(model: model, connection: model.kimi)
                } else if model.showNative {
                    NativeAgentView(connection: model.native, onResultDisplayed: { model.reviewDisplayed($0, on: model.native.host.id) })
                }
                else if model.selectedTerminal == nil { unavailableSession }
                ForEach(model.terminals) { terminal in
                    VStack(spacing: 0) {
                        TerminalPane(terminal: terminal, model: model)
                        StatusBar(connection: model.connections.first { $0.id == terminal.hostID }!)
                    }.id(terminal.incarnation)
                        .opacity(!model.showDashboard && model.selectedTerminalID == terminal.id ? 1 : 0)
                        .allowsHitTesting(!model.showDashboard && model.selectedTerminalID == terminal.id)
                        .accessibilityHidden(model.showDashboard || model.selectedTerminalID != terminal.id)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
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
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        VStack(spacing: 0) {
            TerminalSurfaceView(context: terminal.context)
            if terminal.ended {
                HStack {
                    Text("终端连接已结束；可重新接入仍在运行的会话。").font(.system(size: 12))
                    Spacer()
                    Button("重新接入") { model.reconnectTerminal(terminal) }
                }.padding(14).background(paper)
            }
        }.background(.white)
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
        }.font(.system(size: 10)).foregroundStyle(quiet).padding(.horizontal, 18).padding(.vertical, 9)
            .help(connection.error ?? L("会话状态每 3 秒同步一次；终端内容实时传输"))
    }
}
