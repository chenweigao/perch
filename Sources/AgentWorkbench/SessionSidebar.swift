import AppKit
import SwiftUI
import WorkbenchCore

struct WorkbenchSidebar: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    @Environment(\.locale) private var locale
    @State private var filter = SidebarRecentFilter.all
    @AppStorage("sidebar.favorites.expanded") private var favoritesExpanded = true
    @AppStorage("sidebar.recent.expanded") private var recentExpanded = true
    @AppStorage("sidebar.projects.collapsed") private var collapsedProjectsJSON = "[]"
    @AppStorage("sidebar.projects.grouped") private var groupedByProject = true
    @State private var projectLimit = 8
    @State private var sessionLimit = 40
    @State private var showPinPicker = false
    @State private var expandedProjects = Set<String>()
    private var collapsedProjects: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(collapsedProjectsJSON.utf8))) ?? [])
    }
    private var page: SidebarPage {
        guard model.showDashboard else { return .other }
        if model.showArchived { return .archive }
        if model.onlyAttention { return .inbox }
        if model.showSessionDirectory { return .sessions }
        if model.showAllTaskGroups || model.selectedGroupID != nil { return .groups }
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
                              environmentNeedsAttention: environmentNeedsAttention,
                              onSearch: { model.showSessionSearch = true },
                              onNew: { model.startNewTask() },
                              onHome: { model.clearScope(); model.showHome() }, onInbox: { model.clearScope(); model.showInbox() },
                              onArchive: { model.showArchive() },
                              onAllSessions: { model.showAllSessions() },
                              onGroups: { model.clearScope(); model.showHome(); model.showAllTaskGroups = true },
                              scrollRows: !usesTable, scrollTargetID: scrollTarget(in: projection)) {
            #if PERCH_ACCEPTANCE
            if experiment.sidebarVariant == "projects" { projectRows(projection, index: index) }
            else if usesTable { tableRows(projection, index: index) }
            else if experiment.flatSidebar { flatRows(projection, index: index) }
            else { sectionRows(projection, index: index) }
            #else
            projectRows(projection, index: index)
            #endif
        } environments: {
            ConnectionControls(model: model, kimi: model.kimi, native: model.native).frame(width: 320)
        }
        .onChange(of: model.tabs.selectedID) { _, _ in revealSelectedProject() }
        .onChange(of: groupedByProject) { _, _ in revealSelectedProject() }
        .onChange(of: model.workspace.starred) { old, new in
            if new.count > old.count { favoritesExpanded = true }
        }
        .onChange(of: model.workspace.sidebarProjectLocations) { _, _ in revealSelectedProject() }
        .onChange(of: model.sidebarRepositories.revision) { _, _ in revealSelectedProject() }
        #if !PERCH_ACCEPTANCE
        .task(id: SidebarRepositoryLoad(requests: model.sidebarRepositoryRequests, retry: model.sidebarRepositories.retryRevision)) {
            await model.sidebarRepositories.resolve(model.sidebarRepositoryRequests) { reference in
                try await model.sidebarProjectMessages(reference)
            }
        }
        #endif
        #if PERCH_ACCEPTANCE
        .background(NativeSidebarProbe(projection: projection))
        .onReceive(experiment.$sidebarFilter) { if let value = $0 { filter = value } }
        #endif
    }
    private func revealSelectedProject() {
        if let selected = model.selectedItem, model.workspace.starred.contains(selected.reference) {
            favoritesExpanded = true
        }
        guard let project = model.sidebarProjection(filter: .all).projects.first(where: {
            $0.sessions.contains { $0.id == model.tabs.selectedID }
        }) else { return }
        var collapsed = collapsedProjects
        if collapsed.remove(project.id) != nil {
            collapsedProjectsJSON = String(decoding: try! JSONEncoder().encode(collapsed.sorted()), as: UTF8.self)
        }
    }
    private func scrollTarget(in projection: SidebarProjection) -> String? {
        #if PERCH_ACCEPTANCE
        guard experiment.sidebarVariant == "projects" else { return nil }
        #endif
        guard !model.showDashboard, let selected = model.tabs.selectedID else { return nil }
        if projection.favorites.contains(where: { $0.id == selected }) {
            return favoritesExpanded ? "session-" + selected : nil
        }
        if !groupedByProject {
            return projection.ungrouped.contains(where: { $0.id == selected }) ? "session-" + selected : nil
        }
        guard let project = projection.projects.first(where: { $0.sessions.contains { $0.id == selected } }),
              !collapsedProjects.contains(project.id) else { return nil }
        return "session-" + selected
    }
    private var environmentNeedsAttention: Bool {
        if model.connections.contains(where: { !$0.online && $0.error != nil }) { return true }
        guard let host = model.selectedHost else { return false }
        return (host.enabledAgents.contains(.kimi) && !model.kimi.online && model.kimi.error != nil)
            || (host.hasNativeAgents && !model.native.online && model.native.error != nil)
    }
    private var usesTable: Bool {
        #if PERCH_ACCEPTANCE
        return experiment.sidebarVariant == "table"
        #else
        return false
        #endif
    }
    #if PERCH_ACCEPTANCE
    @AppStorage("sidebar.groups.expanded") private var groupsExpanded = true
    private func tableRows(_ projection: SidebarProjection, index: SessionGroupIndex) -> some View {
        let _ = model.tabs.selectedID
        let _ = model.managing
        let items = entries(projection).map { entry -> AcceptanceSidebarTable.Item in
            let height: CGFloat
            let view: AnyView
            var session: WorkspaceSession?
            switch entry {
            case .favorites:
                height = 47; view = AnyView(SidebarSection("置顶", id: "favorites") { EmptyView() })
            case .recent:
                height = 47; view = AnyView(SidebarSection("最近会话", id: "recent") { EmptyView() } actions: { recentActions })
            case .groups:
                height = groupsExpanded ? CGFloat(82 + model.groupShortcuts.count * 37) : 47
                view = AnyView(groupSection)
            case .footer:
                height = projection.recent.isEmpty ? 72 : 36; view = AnyView(recentFooter(projection))
            case .session(let item):
                session = item
                height = experiment.fixedSidebarHeight || (!item.archived && (!item.online || item.section == .attention)) ? 48 : 34
                view = AnyView(sessionRow(item, groups: index[item.id]))
            }
            return .init(id: entry.id, session: session, height: height,
                         content: AnyView(view.id(entry.id).font(.system(size: 13)).environment(\.locale, locale)))
        }
        return AcceptanceSidebarTable(items: items)
    }
    #endif
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
    private enum ProjectEntry: Identifiable {
        case favorites, emptyFavorites, projects, project(SidebarProject), session(WorkspaceSession, Bool), more(SidebarProject), moreProjects, moreSessions(Int)
        var id: String {
            switch self {
            case .favorites: "header-favorites"
            case .emptyFavorites: "empty-favorites"
            case .projects: "header-projects"
            case .project(let project): "project-" + project.id
            case .session(let item, _): "session-" + item.id
            case .more(let project): "more-" + project.id
            case .moreProjects: "more-projects"
            case .moreSessions: "more-sessions"
            }
        }
    }
    private func projectEntries(_ projection: SidebarProjection) -> [ProjectEntry] {
        var result: [ProjectEntry] = []
        result.append(.favorites)
        if favoritesExpanded {
            result += projection.favorites.map { .session($0, false) }
            if projection.favorites.isEmpty { result.append(.emptyFavorites) }
        }
        result.append(.projects)
        let collapsed = collapsedProjects
        let selectedID = model.showDashboard ? nil : model.tabs.selectedID
        if !groupedByProject {
            var sessions = Array(projection.ungrouped.prefix(sessionLimit))
            if let selected = projection.ungrouped.first(where: { $0.id == selectedID }),
               !sessions.contains(where: { $0.id == selected.id }) { sessions.append(selected) }
            result += sessions.map { .session($0, false) }
            if sessions.count < projection.ungrouped.count { result.append(.moreSessions(projection.ungrouped.count)) }
            return result
        }
        var visible = Array(projection.projects.prefix(projectLimit))
        if let selectedProject = projection.projects.first(where: { $0.sessions.contains { $0.id == selectedID } }),
           !visible.contains(where: { $0.id == selectedProject.id }) { visible.append(selectedProject) }
        for project in visible {
            result.append(.project(project))
            guard !collapsed.contains(project.id) else { continue }
            var sessions = expandedProjects.contains(project.id) ? project.sessions : Array(project.sessions.prefix(5))
            if let selected = project.sessions.first(where: { $0.id == selectedID }), !sessions.contains(where: { $0.id == selected.id }) {
                sessions.append(selected)
            }
            result += sessions.map { .session($0, true) }
            if sessions.count < project.sessions.count { result.append(.more(project)) }
        }
        if visible.count < projection.projects.count { result.append(.moreProjects) }
        return result
    }
    @ViewBuilder private func projectRows(_ projection: SidebarProjection, index: SessionGroupIndex) -> some View {
        ForEach(projectEntries(projection)) { entry in
            switch entry {
            case .favorites: pinnedHeader(count: projection.favorites.count)
            case .emptyFavorites:
                Button { showPinPicker = true } label: {
                    Text("置顶常用会话，随时继续")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
                }.buttonStyle(SidebarNavigationStyle()).accessibilityIdentifier("sidebar.pin.empty")
            case .projects:
                HStack {
                    Menu {
                        Picker("会话视图", selection: $groupedByProject) {
                            Label("按项目", systemImage: "folder").tag(true)
                            Label("平铺会话", systemImage: "list.bullet").tag(false)
                        }.pickerStyle(.inline)
                        Divider()
                        Button("重新识别项目") { model.sidebarRepositories.retry() }
                    } label: {
                        HStack(spacing: 5) {
                            Text(groupedByProject ? L("项目") : L("最近会话"))
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }.foregroundStyle(.secondary).frame(height: 26)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("切换会话视图").accessibilityIdentifier("sidebar.layout")
                    Spacer()
                    if groupedByProject && model.sidebarRepositories.isResolving {
                        ProgressView().controlSize(.mini).help("正在识别项目…")
                    }
                    if groupedByProject && model.sidebarRepositories.failed {
                        Button { model.sidebarRepositories.retry() } label: {
                            Image(systemName: model.sidebarRepositories.failed ? "exclamationmark.arrow.circlepath" : "arrow.clockwise")
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(model.sidebarRepositories.failed ? "项目识别失败，点击重试" : "重新识别项目")
                            .accessibilityLabel("重新识别项目")
                    }
                    recentActions
                }.padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 3)
            case .project(let project):
                SidebarProjectHeader(project: project, expanded: !collapsedProjects.contains(project.id),
                    canCreate: project.location.map { location in model.connections.contains { $0.id == location.hostID } } ?? true,
                    onToggle: {
                        var collapsed = collapsedProjects
                        if !collapsed.insert(project.id).inserted { collapsed.remove(project.id) }
                        collapsedProjectsJSON = String(decoding: try! JSONEncoder().encode(collapsed.sorted()), as: UTF8.self)
                    }, onNew: { model.startNewTask(in: project.location) })
            case .session(let item, let indented):
                SessionSidebarRow(model: model, item: item, groups: index[item.id], compact: true,
                    selected: !model.showDashboard && item.id == model.tabs.selectedID,
                    onOpen: { model.open(item) }).padding(.leading, indented ? 22 : 0).id(entry.id)
            case .more(let project):
                Button { expandedProjects.insert(project.id) } label: {
                    Text("显示全部 \(project.sessions.count) 个会话").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(SidebarNavigationStyle()).padding(.leading, 32).padding(.vertical, 4)
            case .moreProjects:
                Button("更多项目") { projectLimit += 8 }
                    .buttonStyle(SidebarNavigationStyle()).padding(.horizontal, 10).padding(.vertical, 6)
            case .moreSessions(let count):
                Button("更多会话（共 \(count) 个）") { sessionLimit += 40 }
                    .buttonStyle(SidebarNavigationStyle()).padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        if projection.projects.isEmpty && projection.favorites.isEmpty {
            Text("新任务会出现在这里").font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }
    }

    private func pinnedHeader(count: Int) -> some View {
        HStack(spacing: 4) {
            Button { favoritesExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill").font(.system(size: 10))
                    Text("置顶").font(.system(size: 12, weight: .semibold))
                    if count > 0 { Text("\(count)").font(.system(size: 11)).monospacedDigit() }
                    Image(systemName: favoritesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                    Spacer(minLength: 0)
                }.frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(SidebarNavigationStyle()).accessibilityLabel("置顶")
                .accessibilityValue(favoritesExpanded ? Text("已展开") : Text("已收起"))
                .accessibilityIdentifier("sidebar.section.favorites")
            Button { showPinPicker = true } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }
                .buttonStyle(SidebarNavigationStyle()).help("置顶会话")
                .accessibilityLabel("置顶会话").accessibilityIdentifier("sidebar.pin.add")
                .popover(isPresented: $showPinPicker, arrowEdge: .trailing) {
                    SidebarPinPicker(model: model).foregroundStyle(Color.primary)
                }
        }.foregroundStyle(Color.primary).padding(.horizontal, 10).padding(.top, 8)
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

private struct SidebarPinPicker: View {
    let model: WorkbenchModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sessions = model.allSessions.filter {
            !$0.archived && !model.workspace.starred.contains($0.reference) &&
                (query.isEmpty || [$0.title, $0.directory, $0.hostName].contains { $0.localizedStandardContains(query) })
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("置顶会话").font(.headline)
            TextField("搜索会话", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(sessions) { item in
                        Button {
                            model.toggleStar(item.reference)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                SidebarAgentIndicator(item: item)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.system(size: 12)).lineLimit(1)
                                    Text(item.hostName + " · " + item.directory).font(.system(size: 10))
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "pin").foregroundStyle(.secondary)
                            }.padding(6).contentShape(Rectangle())
                        }.buttonStyle(SidebarNavigationStyle()).accessibilityLabel(item.title)
                    }
                    if sessions.isEmpty { Text("没有可置顶的会话").font(.caption).foregroundStyle(.secondary).padding(8) }
                }
            }.frame(height: 280)
        }.padding(14).frame(width: 320).onAppear { searchFocused = true }
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
        let result = search.update(model.allSessions, query: query, locale: L.locale,
                                   projectLocations: model.sidebarProjectLocations)
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
    var compact = false
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
        SessionRowChrome(title: item.title, subtitle: compact ? nil : subtitle,
                         hostName: item.hostName, hostID: item.reference.hostID,
                         directory: item.directory, detail: item.detail,
                         groups: groups, updatedAt: item.updatedAt, compact: compact,
                         running: item.online && !item.archived && item.section == .running,
                         selected: selected,
                         starred: model.workspace.starred.contains(item.reference), archived: item.archived,
                         canOpen: item.online && !item.archived,
                         canQuickArchive: model.canArchive(item) && (item.archived || item.section != .running),
                         busy: model.managing.contains(item.id), onOpen: onOpen,
                         onPin: { model.toggleStar(item.reference) },
                         onArchive: { model.setArchived(item, archived: !item.archived) }) {
            if compact {
                SidebarAgentIndicator(item: item)
            } else { SessionStatusIndicator(item: item) }
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
        Menu("移动到项目") {
            ForEach(model.sidebarProjection(filter: .all).projects) { project in
                if let location = project.location {
                    Button(project.disambiguate ? "\(project.title) · \(project.detail ?? "")" : project.title) {
                        model.moveSidebarSession(item, to: location)
                    }
                }
            }
            Divider()
            Button("按所属仓库归组") { model.moveSidebarSession(item, to: nil) }
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
                            agentStatus(connection.host.enabledAgents.filter { [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains($0) }.map(\.label).joined(separator: " · "),
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
                              onResultDisplayed: { model.reviewDisplayed($0, on: connection.host.id) }).id(ObjectIdentifier(connection))
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
