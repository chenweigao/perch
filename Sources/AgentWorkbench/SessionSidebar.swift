import AppKit
import SwiftUI
import WorkbenchCore

struct WorkbenchSidebar: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    @State private var filter = SidebarRecentFilter.all
    @AppStorage("sidebar.favorites.expanded") private var favoritesExpanded = true
    @AppStorage("sidebar.recent.expanded") private var recentExpanded = true
    private var page: SidebarPage {
        guard model.showDashboard else { return .other }
        if model.showArchived { return .archive }
        if model.onlyAttention { return .inbox }
        return model.selectedGroupID == nil && !model.showSessionDirectory ? .home : .other
    }
    var body: some View {
        #if PERCH_ACCEPTANCE
        let _ = { if NativeAcceptanceProbe.shared.checkSidebarInvalidation { NativeAcceptanceProbe.shared.sidebarBodyEvaluations += 1 } }()
        #endif
        let projection = model.sidebarProjection(filter: filter)
        let index = model.groupIndex
        WorkspaceSidebarShell(page: page, attentionCount: projection.attentionCount,
                              environmentSummary: L("\(model.connections.count) 个环境"),
                              onSearch: { model.showSessionSearch = true },
                              onNew: { model.startNewTask() },
                              onHome: { model.clearScope(); model.showHome() }, onInbox: { model.clearScope(); model.showInbox() },
                              onArchive: { model.showArchive() }) {
            #if PERCH_ACCEPTANCE
            if experiment.flatSidebar { flatRows(projection, index: index) }
            else { sectionRows(projection, index: index) }
            #else
            flatRows(projection, index: index)
            #endif
        } environments: {
            ConnectionControls(model: model, kimi: model.kimi, native: model.native).frame(width: 320)
        }
        #if PERCH_ACCEPTANCE
        .background(NativeSidebarProbe(projection: projection))
        .onReceive(experiment.$sidebarFilter) { if let value = $0 { filter = value } }
        #endif
    }
    private func showsFavorites(_ projection: SidebarProjection) -> Bool {
        #if PERCH_ACCEPTANCE
        if experiment.keepSidebarHeader || experiment.showEmptySidebarHeader { return true }
        #endif
        return !projection.favorites.isEmpty
    }
    #if PERCH_ACCEPTANCE
    @ObservedObject private var experiment = NativeAcceptanceProbe.shared
    #endif
    // A session keeps one ForEach identity when moving between recent and pinned.
    // Headers are entries; section membership is not part of a session identity.
    private enum Entry: Identifiable {
        case favorites, groups, recent, footer, session(WorkspaceSession)
        var id: String {
            switch self {
            case .favorites: "header-favorites"
            case .groups: "section-groups"
            case .recent: "header-recent"
            case .footer: "footer-recent"
            case .session(let item): "session-" + item.id
            }
        }
    }
    private func entries(_ projection: SidebarProjection) -> [Entry] {
        var result: [Entry] = []
        if showsFavorites(projection) {
            result.append(.favorites)
            if favoritesExpanded { result += projection.favorites.map(Entry.session) }
        }
        result += [.groups, .recent]
        if recentExpanded { result += projection.recent.map(Entry.session); result.append(.footer) }
        return result
    }
    @ViewBuilder private func flatRows(_ projection: SidebarProjection, index: SessionGroupIndex) -> some View {
        ForEach(entries(projection)) { entry in
            switch entry {
            case .favorites: SidebarSection("置顶", id: "favorites") { EmptyView() }
            case .groups: groupSection
            case .recent:
                SidebarSection("最近会话", id: "recent") { EmptyView() } actions: {
                    recentActions
                }
            case .footer: recentFooter(projection)
            case .session(let item): sessionRow(item, groups: index[item.id])
            }
        }
    }
    private var groupSection: some View {
        SidebarSection("常用任务组", id: "groups") {
            ForEach(model.groupShortcuts) { summary in
                let group = summary.group
                Button { model.showHome(groupID: group.id) } label: {
                    HStack(spacing: WorkbenchChrome.labelSpacing) {
                        Image(systemName: group.isPinned ? "pin" : "folder").font(.system(size: WorkbenchChrome.symbolSize, weight: .regular)).imageScale(.medium)
                            .frame(width: WorkbenchChrome.sidebarSymbolWidth)
                        Text(group.name).lineLimit(1); Spacer(minLength: 4)
                        if summary.attentionCount > 0 {
                            Text("\(summary.attentionCount)").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(SidebarNavigationStyle(selected: model.showDashboard && model.selectedGroupID == group.id))
                    .help("\(summary.attentionCount) 项等你处理 · \(summary.unsyncedCount) 项状态未同步")
                    .contextMenu {
                        Button(group.isPinned ? "取消置顶" : "置顶任务组") { model.toggleGroupPin(group) }
                        Button("编辑任务组") { model.editGroup(group) }
                    }
            }
            Button("全部任务组") {
                model.clearScope(); model.showHome(); model.showAllTaskGroups = true
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.leading, 36).padding(.trailing, 10).padding(.vertical, 8)
        } actions: {
            Button { model.editGroup() } label: {
                Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help("新建任务组")
        }
    }
    @ViewBuilder private func recentFooter(_ projection: SidebarProjection) -> some View {
        if projection.recent.isEmpty {
            Text(L(key: filter == .all ? "新任务会出现在这里" : "没有符合筛选的会话"))
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 26).padding(10)
        }
        Button { model.showAllSessions() } label: {
            HStack { Text("全部会话"); Spacer(); Image(systemName: "arrow.right").font(.system(size: 10)) }
                .padding(.leading, 26).padding(10).contentShape(Rectangle())
        }.buttonStyle(SidebarNavigationStyle()).foregroundStyle(.secondary)
    }
    private var recentActions: some View {
        Menu {
            Picker("筛选最近会话", selection: $filter) {
                ForEach(SidebarRecentFilter.allCases, id: \.self) { Text(L(key: $0.rawValue)).tag($0) }
            }
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("筛选最近会话：\(L(key: filter.rawValue))")
    }
    #if PERCH_ACCEPTANCE
    // Original structural parents retained only as an experiment control.
    @ViewBuilder private func sectionRows(_ projection: SidebarProjection, index: SessionGroupIndex) -> some View {
        if showsFavorites(projection) {
            SidebarSection("置顶", id: "favorites") {
                ForEach(projection.favorites) { item in sessionRow(item, groups: index[item.id]) }
            }
        }
        groupSection
        SidebarSection("最近会话", id: "recent") {
            ForEach(projection.recent) { item in sessionRow(item, groups: index[item.id]) }
            recentFooter(projection)
        } actions: {
            recentActions
        }
    }
    #endif
    private func sessionRow(_ item: WorkspaceSession, groups: [String]) -> some View {
        SessionSidebarRow(model: model, item: item, groups: groups,
                          selected: !model.showDashboard && item.id == model.tabs.selectedID,
                          onOpen: { model.open(item) })
    }
}

struct SessionDirectoryView: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    var isSearchSheet = false
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var search = SessionDirectorySearch()
    var body: some View {
        let result = search.update(model.allSessions, query: query, locale: L.locale)
        let sessions = result.sessions
        let index = model.groupIndex
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L(key: isSearchSheet ? "搜索任务" : "全部会话")).font(.title2.weight(.semibold))
                Spacer()
                if isSearchSheet { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            TextField("标题、Agent、环境或目录", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let item = sessions.first(where: { $0.id == selection }) { open(item) } }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { move(1, key: $0) }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { move(-1, key: $0) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sessions) { item in
                            SessionSidebarRow(model: model, item: item, groups: index[item.id],
                                              selected: item.id == selection,
                                              onOpen: { open(item) }).id(item.id)
                        }
                        if sessions.isEmpty { Text("没有找到会话").foregroundStyle(.secondary).padding(24) }
                    }
                }
                .onChange(of: selection) { _, value in if let value { proxy.scrollTo(value) } }
            }
        }.padding(24).frame(maxWidth: 950, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { if isSearchSheet { focused = true }; selection = result.online.first?.id }
            .onChange(of: query) { _, _ in selection = result.online.first?.id }
            .onChange(of: result.online.map(\.id)) { _, ids in
                if selection.map({ !ids.contains($0) }) ?? true { selection = ids.first }
            }
            #if PERCH_ACCEPTANCE
            // Drives the real local @State path; no alternate search algorithm.
            // The probe does not evaluate `sessions` or add another filter pass.
            .onReceive(NativeAcceptanceProbe.shared.$query) { value in
                if let value { query = value }
            }
            .background(NativeDirectoryProbe(query: query, selection: selection))
            #endif
    }
    private func open(_ item: WorkspaceSession) {
        guard item.online else { return }
        model.open(item)
        if isSearchSheet { dismiss() }
    }
    private func move(_ delta: Int, key: KeyPress) -> KeyPress.Result {
        guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return .ignored }
        let available = search.result.online
        guard !available.isEmpty else { return .ignored }
        let index = available.firstIndex { $0.id == selection } ?? 0
        selection = available[min(max(index + delta, 0), available.count - 1)].id
        return .handled
    }
}

/// The enclosing sidebar already observes the workspace model. An `@ObservedObject`
/// here would register one observer per visible row, so a single search keystroke or
/// streamed catalog update invalidates every row body instead of just the list.
private struct SessionSidebarRow: View {
    @UILocalization private var L
    let model: WorkbenchModel
    let item: WorkspaceSession
    /// Task groups this session belongs to. The subtitle is already spoken for by
    /// attention and offline states, so membership stays in the hover preview.
    var groups: [String] = []
    let selected: Bool
    let onOpen: () -> Void
    private var subtitle: String? {
        if item.archived { return nil }
        if !item.online { return L("离线 · 状态未同步") }
        return item.section == .attention ? item.detail : nil
    }
    var body: some View {
        #if PERCH_ACCEPTANCE
        let _ = recordBody()
        #endif
        SessionRowChrome(title: item.title, subtitle: subtitle,
                         hostName: item.hostName, hostID: item.reference.hostID,
                         directory: item.directory, detail: item.detail,
                         groups: groups, updatedAt: item.updatedAt,
                         selected: selected,
                         starred: model.workspace.starred.contains(item.reference), archived: item.archived,
                         canOpen: item.online && !item.archived,
                         canQuickArchive: model.canArchive(item) && (item.archived || item.section != .running),
                         busy: model.managing.contains(item.id), onOpen: onOpen,
                         onPin: { model.toggleStar(item.reference) },
                         onArchive: { model.setArchived(item, archived: !item.archived) }) {
            SessionStatusIndicator(item: item)
        }.opacity(item.online || item.archived ? 1 : 0.65)
            .contextMenu { SessionActionsMenu(model: model, item: item) }
            #if PERCH_ACCEPTANCE
            .background {
                if NativeAcceptanceProbe.shared.checkSidebarInvalidation {
                    NativeSidebarRowProbe(item: item, groups: groups, selected: selected,
                        starred: model.workspace.starred.contains(item.reference), busy: model.managing.contains(item.id),
                        canQuickArchive: model.canArchive(item) && (item.archived || item.section != .running))
                }
            }
            #endif
    }
    #if PERCH_ACCEPTANCE
    private func recordBody() {
        let probe = NativeAcceptanceProbe.shared
        if probe.checkSidebarInvalidation { probe.sidebarRowEvaluations[item.id, default: 0] += 1 }
    }
    #endif
}

struct SessionActionsMenu: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    let item: WorkspaceSession
    private var busy: Bool { model.managing.contains(item.id) }
    var body: some View {
        Button { model.renamingSession = item } label: { Label("重命名…", systemImage: "pencil") }
        if !item.archived {
            Button { model.toggleStar(item.reference) } label: {
                Label(model.workspace.starred.contains(item.reference) ? "取消置顶" : "置顶会话", systemImage: "pin")
            }
        }
        Button { model.groupingSession = item } label: { Label("管理任务组归属…", systemImage: "folder") }
        Button { model.toggleTaskNotifications(item.id) } label: {
            Label(model.mutedTasks.contains(item.id) ? L("恢复任务通知") : L("静音任务通知"),
                  systemImage: model.mutedTasks.contains(item.id) ? "bell" : "bell.slash")
        }
        // Membership is only useful if it leads somewhere, so any list offers the jump
        // to the group's own page, where its goal and next step live.
        ForEach(model.workspace.groups.filter { $0.sessions.contains(item.reference) }) { group in
            Button { model.showHome(groupID: group.id) } label: {
                Label("打开任务组 \(group.name)", systemImage: "arrow.right")
            }
        }
        Divider()
        Button { model.setArchived(item, archived: !item.archived) } label: {
            Label(item.archived ? L("恢复归档") : item.reference.kind == .terminal ? L("归档到本机") : L("归档会话"), systemImage: "archivebox")
        }.disabled(busy || !model.canArchive(item))
        if model.tabs.ids.contains(item.id) {
            Button("关闭本地视图") { model.close(item.id) }
        }
        Divider()
        Button(role: .destructive) { model.pendingDeletion = item } label: {
            Label(item.reference.kind == .terminal ? L("结束远端终端…") : L("删除会话…"), systemImage: "trash")
        }.disabled(busy || !item.online || (item.reference.kind != .terminal && !model.canArchive(item)))
    }
}

struct ArchivedSessionsView: View {
    @Bindable var model: WorkbenchModel
    var body: some View {
        let sessions = model.scopedSessions
        let index = model.groupIndex
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("已归档").font(.title.weight(.semibold))
                Text("Kimi 归档与服务端同步；终端归档只整理本机列表，不结束远端进程。").foregroundStyle(.secondary)
                ForEach(sessions) { item in
                    SessionSidebarRow(model: model, item: item, groups: index[item.id], selected: false, onOpen: {})
                }
                if sessions.isEmpty { Text("没有归档会话").foregroundStyle(.secondary) }
            }.padding(32).frame(maxWidth: 950).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ConnectionControls: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: WorkbenchModel
    let kimi: KimiConnection
    let native: NativeAgentConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("环境与 Agent").foregroundStyle(.secondary); Spacer()
                Button { dismiss(); model.configureHost() } label: { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("添加 SSH 机器")
            }
            Button { dismiss(); model.showLocalSetup = true } label: {
                Label { Text("本机 Agent…") } icon: { HostIdentityIcon(hostID: ExecutionEnvironment.localHostID) }
            }
                .buttonStyle(.plain).padding(.vertical, 4)
            if model.connections.isEmpty { Text("添加机器后，选择要连接的 Agent。").foregroundStyle(.secondary) }
            ForEach(model.connections) { connection in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            model.activateAgentEnvironment(connection.id)
                            model.showHome(groupID: model.selectedGroupID); model.setScope(hostID: connection.id)
                        } label: {
                            HStack(spacing: 6) {
                                HostIdentityLabel(hostID: connection.id, name: connection.host.name)
                                if model.selectedHostID == connection.id {
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        Button { dismiss(); model.configureHost(connection.host) } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.plain).help("配置与检查 Agent")
                    }.contextMenu {
                        Button("配置与检查 Agent") { dismiss(); model.configureHost(connection.host) }
                        Button("移除机器…", role: .destructive) { dismiss(); model.pendingHostRemoval = connection.host }
                    }
                    if model.selectedHostID == connection.id {
                        if connection.host.enabledAgents.contains(.kimi) {
                            agentStatus("Kimi", online: kimi.online, error: kimi.error) { kimi.connect() }
                        }
                        if connection.host.hasNativeAgents {
                            agentStatus(connection.host.enabledAgents.filter { [.omp, .qoder, .dsh, .codex, .claude].contains($0) }.map(\.label).joined(separator: " · "),
                                        online: native.online, error: native.error) { native.connect() }
                        }
                        if connection.host.enabledAgents.contains(.terminal) {
                            agentStatus("Herdr", online: connection.online, error: connection.error) { connection.connect() }
                        }
                    }
                }.padding(.vertical, 6)
            }
        }.font(.system(size: 11)).padding(15).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10)).padding(10)
    }
    private func agentStatus(_ name: String, online: Bool, error: String?, reconnect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle().fill(online ? .green : .orange).frame(width: 5, height: 5)
                Text(name); Spacer()
                Text(LocalizedStringKey(online ? "已连接" : error == nil ? "未连接" : "需要处理")).foregroundStyle(.secondary)
                Button(action: reconnect) { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("重新连接")
            }
            if let error, !online { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled) }
        }.padding(.leading, 12)
    }
}

struct KimiSelectionContent: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    let connection: KimiConnection
    var body: some View {
        if connection.conversation?.snapshot.session.id == model.selectedReference?.terminalID {
            KimiWorkspaceView(connection: connection, onNew: { model.startNewTask() }, onInput: {},
                              onResultDisplayed: { model.reviewDisplayed($0, on: connection.host.id) }).id(model.selectedReference?.id)
        } else {
            VStack(spacing: 14) {
                if connection.loading { ProgressView() }
                Text(connection.loading ? L("正在读取对话…") : L("等待恢复会话")).font(.title3)
                Text(connection.actionError ?? connection.error ?? L("正在连接远端 Kimi 服务")).foregroundStyle(.secondary)
                if connection.online, !connection.loading, let reference = model.selectedReference {
                    Button("Retry") { connection.select(reference.terminalID) }
                }
                Button("返回工作台") { model.showHome(groupID: model.selectedGroupID) }
            }.padding(30)
        }
    }
}
