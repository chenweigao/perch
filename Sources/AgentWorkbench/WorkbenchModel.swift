import AppKit
import Combine
import Observation
import GhosttyTerminal
import os
import SwiftUI
import WorkbenchCore

/// Naming failures were invisible, which made "it did not fire" undiagnosable.
/// Log attempt/success/failure only; the skip guards run per snapshot and are
/// too hot to log. No excerpts or credentials go into the log.
let namingLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.agentworkbench.mac", category: "session-naming")

@MainActor
@Observable
final class WorkbenchModel {
    let navigationState = WorkbenchNavigationState()
    let catalog = SessionCatalogState()
    let conversationPresentations = ConversationPresentationCache()
    var kimi: KimiConnection
    var native: NativeAgentConnection
    @ObservationIgnored private var kimiEnvironments: [UUID: KimiConnection] = [:]
    @ObservationIgnored private var nativeEnvironments: [UUID: NativeAgentConnection] = [:]
    var connections: [HostConnection]
    /// Whether the user has configured a machine list. Persisting the built-in
    /// machine's identity alone does not dismiss first-run setup.
    private(set) var configuredEnvironment: Bool
    var pendingHostRemoval: SSHHost?
    var selectedHostID: UUID
    private(set) var tabs: TerminalTabs {
        get { navigationState.tabs }
        set { navigationState.tabs = newValue }
    }
    private(set) var openedSessions: [SavedTerminal] = []
    private(set) var terminals: [AttachedTerminal] = []
    var showDashboard: Bool {
        get { navigationState.showDashboard }
        set { navigationState.showDashboard = newValue }
    }
    var showAllTaskGroups: Bool {
        get { navigationState.showAllTaskGroups }
        set { navigationState.showAllTaskGroups = newValue }
    }
    var selectedGroupID: UUID? {
        get { navigationState.selectedGroupID }
        set { navigationState.selectedGroupID = newValue }
    }
    /// Narrows the workbench queue without leaving it. Deliberately not persisted:
    /// a filter is a question about right now, and restoring one would hide sessions
    /// on the first screen after launch.
    var scopeHostID: UUID? {
        get { navigationState.scopeHostID }
        set { navigationState.scopeHostID = newValue }
    }
    var workspace = LocalWorkspace() {
        didSet {
            if workspace.groups != oldValue.groups {
                cachedGroupIndex = nil; cachedGroupShortcuts = nil
            }
            if workspace.starred != oldValue.starred { cachedSidebar = nil }
        }
    }
    @ObservationIgnored private var cachedGroupIndex: SessionGroupIndex?
    @ObservationIgnored private var cachedGroupShortcuts: (catalogRevision: Int, selectedID: UUID?, summaries: [TaskGroupSummary])?
    @ObservationIgnored private var cachedSidebar: (catalogRevision: Int, filter: SidebarRecentFilter, projection: SidebarProjection)?
    var workspaceError: String?
    private(set) var allSessions: [WorkspaceSession] {
        get { catalog.sessions }
        set { catalog.replace(newValue) }
    }
    var showArchived: Bool {
        get { navigationState.showArchived }
        set { navigationState.showArchived = newValue }
    }
    var showSessionDirectory: Bool {
        get { navigationState.showSessionDirectory }
        set { navigationState.showSessionDirectory = newValue }
    }
    var pendingDeletion: WorkspaceSession?
    var renamingSession: WorkspaceSession?
    var managementError: String?
    var managing = Set<String>()
    /// Optimistic archive state applied before the server confirms, so the row
    /// leaves or returns in the same animation as the click. Cleared once the
    /// refreshed remote list agrees, or reverted on failure.
    @ObservationIgnored private var archiveOverrides: [String: Bool] = [:]
    var isArchiving = false
    var archiveResult: BatchArchiveRun?
    var showLocalSetup = false
    var localAgents: [SessionKind: DiscoveryState] = [:]
    var localAgentPaths: [String: String] = [:]
    var probingLocal = false
    var groupingSession: WorkspaceSession?
    var inspectingSession: WorkspaceSession?
    var showGroupSuggestions = false
    var groupingUndo: GroupingUndo?
    @ObservationIgnored private var inspectionOrder = ActionQueueOrder()
    var search: String {
        get { navigationState.search }
        set { navigationState.search = newValue }
    }
    var onlyAttention: Bool {
        get { navigationState.onlyAttention }
        set { navigationState.onlyAttention = newValue }
    }
    var showAddHost = false
    var setupHost: SSHHost?
    var launchAfterSetup: TaskLaunchDefaults?
    var pendingSetupLaunch = false
    var showNewTerminal = false
    /// Inline new-task draft covering the detail area; selection underneath is kept.
    var draftingNewTask = false {
        didSet { updateVisibility() }
    }
    var showRenderReport = false
    var renderReport = ""
    var showGroupEditor = false
    var editingGroup: WorkItemGroup?
    var editingGroupSessionsOnly = false
    var taskNotice: TaskNotice?
    var notificationError: String?
    var notificationsEnabled = UserDefaults.standard.bool(forKey: "task.notifications") {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "task.notifications")
            notifications.cancelPendingCompletions()
            if notificationsEnabled { notifications.requestPermission { [weak self] error in self?.notificationError = error } }
        }
    }
    var notifyAttentionOnly = UserDefaults.standard.bool(forKey: "task.notifications.attentionOnly") {
        didSet {
            UserDefaults.standard.set(notifyAttentionOnly, forKey: "task.notifications.attentionOnly")
            notifications.cancelPendingCompletions()
        }
    }
    private(set) var mutedTasks = Set(UserDefaults.standard.stringArray(forKey: "task.notifications.muted") ?? [])
    func toggleTaskNotifications(_ id: String) {
        if mutedTasks.contains(id) { mutedTasks.remove(id) } else { mutedTasks.insert(id) }
        UserDefaults.standard.set(Array(mutedTasks), forKey: "task.notifications.muted")
        notifications.cancelPendingCompletions(for: id)
    }
    private let notifications = TaskNotifications()
    @ObservationIgnored private var taskEvents = TaskEventTracker()
    @ObservationIgnored private var pendingNotificationID: String?
    var showConversationFind = false
    var showSessionSearch = false
    private(set) var navigation: SessionNavigation {
        get { navigationState.navigation }
        set { navigationState.navigation = newValue }
    }
    @ObservationIgnored private var navigatingHistory = false
    var showFileViewer = false
    let fileBrowser = RemoteFileBrowser()
    private static let workspaceFileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.agentworkbench.mac")
        .appendingPathComponent("workspace.json")
    private let workspaceURL = WorkbenchModel.workspaceFileURL
    @ObservationIgnored private lazy var workspaceWriter = WorkspaceWriter(url: workspaceURL)
    @ObservationIgnored private var canSaveWorkspace = true
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    /// Session id → settings revision of the one naming attempt. A saved
    /// configuration change allows exactly one retry per session.
    @ObservationIgnored private var namingAttempts: [String: Int] = [:]
    private(set) var namingInProgress: Set<String> = []
    private(set) var namingErrors: [String: String] = [:]
    /// The request boundary is replaceable by isolated lifecycle checks.
    @ObservationIgnored var sessionNamer: (ActivitySummaryConfiguration, String, String) async throws -> String = { configuration, excerpt, language in
        let settings = ActivitySummarySettings.shared
        let key = try await settings.apiKey()
        try Task.checkCancellation()
        guard settings.configuration == configuration else { throw CancellationError() }
        return try await SessionNamingClient().name(configuration: configuration, apiKey: key,
                                                     excerpt: excerpt, language: language)
    }

    init() {
        let hosts: [SSHHost]
        if let data = UserDefaults.standard.data(forKey: "hosts"),
           let saved = try? JSONDecoder().decode([SSHHost].self, from: data) {
            hosts = saved
        } else if let id = UserDefaults.standard.string(forKey: "defaultHostID").flatMap(UUID.init(uuidString:)),
                  let saved = try? WorkspaceFile.load(from: Self.workspaceFileURL),
                  saved.pinned.contains(where: { $0.session.hostID == id }) {
            // Preserve real sessions from releases that used the implicit host.
            hosts = [SSHHost(id: id, name: "dev-env", destination: "dev-env")]
        } else { hosts = [] }
        configuredEnvironment = !hosts.isEmpty
        let initialHost = hosts.first ?? .unconfigured
        kimi = KimiConnection(host: initialHost)
        native = NativeAgentConnection(host: initialHost)
        connections = hosts.map(HostConnection.init)
        selectedHostID = initialHost.id
        do {
            workspace = try WorkspaceFile.load(from: workspaceURL)
            openedSessions = workspace.pinned
            for saved in openedSessions { tabs.open(saved.session.id, pinned: true) }
            selectedGroupID = workspace.selectedGroupID
            if workspace.destination == .session, let selected = workspace.selectedTerminalID { tabs.select(selected); showDashboard = false }
            else { tabs.showOverview(); showDashboard = true }
            if let selectedReference { selectedHostID = selectedReference.hostID }
        } catch {
            canSaveWorkspace = false
            workspaceError = "本地工作台读取失败，原文件已保留：\(error.localizedDescription)"
        }
        if let reference = selectedReference { navigation.visit(reference.id) }
        notifications.start()
        notifications.onOpen = { [weak self] id in self?.openNotifiedTask(id) }
        notifications.onOpenDashboard = { [weak self] in self?.showHome() }
        for connection in connections { observe(connection) }
        if !hosts.isEmpty { registerEnvironment(kimi: kimi, native: native) }
        for host in hosts where host.id != kimi.host.id {
            registerEnvironment(kimi: KimiConnection(host: host), native: NativeAgentConnection(host: host))
        }
        ActivitySummarySettings.shared.$revision.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reconsiderNaming() }
        }.store(in: &subscriptions)
        observers.append(NotificationCenter.default.addObserver(forName: .init("PerchOpenConversationFile"), object: nil, queue: .main) { [weak self] notice in
            guard let url = notice.object as? URL, let reference = ConversationFileReference(url: url) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if let item = self.inspectingSession { self.inspectingSession = nil; self.open(item) }
                guard !self.showDashboard, self.selectedHost != nil else { return }
                self.showFileViewer = true; self.syncFileViewer()
                self.fileBrowser.open(reference.path, line: reference.line, fromConversation: true)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.resumeConnectionsAfterWake()
            }
        })
    }

    #if PERCH_ACCEPTANCE
    /// Full production views with an in-memory native transport. No restoration,
    /// persistence, connection startup, notifications or user workspace observers.
    init(acceptanceHost host: SSHHost, sessions: [WorkspaceSession], native: NativeAgentConnection, kimi: KimiConnection? = nil) {
        self.kimi = kimi ?? KimiConnection(setupHost: host)
        self.native = native
        connections = []
        configuredEnvironment = true
        selectedHostID = host.id
        canSaveWorkspace = false
        allSessions = sessions
        kimiEnvironments[host.id] = self.kimi; nativeEnvironments[host.id] = native
        workspace.starred = Array(sessions.prefix(4).map(\.reference))
        workspace.groups = [WorkItemGroup(name: "性能验收", goal: "固定离线数据", nextStep: "",
                                          sessions: Array(sessions.prefix(12).map(\.reference)))]
    }
    func acceptanceUpdateCatalog(_ sessions: [WorkspaceSession]) { allSessions = sessions }
    #endif

    func registerEnvironment(kimi: KimiConnection, native: NativeAgentConnection) {
        kimiEnvironments[kimi.host.id] = kimi; nativeEnvironments[native.host.id] = native
        native.onSessionsChanged = { [weak self] in self?.catalogChanged() }
        kimi.onSessionsChanged = { [weak self] in self?.catalogChanged() }
        native.onOnlineChanged = { [weak self] in Task { @MainActor in self?.catalogChanged() } }
        native.onOnlineChanged?()
        kimi.onOnlineChanged = { [weak self] in Task { @MainActor in self?.catalogChanged() } }
        kimi.onOnlineChanged?()
        kimi.onConversationChanged = { [weak self, weak kimi] conversation in
            Task { @MainActor in
                guard let self, let kimi, let conversation else { return }
                let session = conversation.snapshot.session
                self.considerNaming(reference: SessionReference(hostID: kimi.host.id, terminalID: session.id, kind: .kimi),
                                    remoteTitle: session.title, messages: conversation.messages,
                                    busy: session.isTurnRunning, turnCompleted: session.lastTurnReason == "completed", hasOlder: conversation.hasOlder)
            }
        }
        kimi.onConversationChanged?(kimi.conversation)
        native.onSnapshotChanged = { [weak self, weak native] snapshot in
            Task { @MainActor in
                guard let self, let native, let snapshot else { return }
                self.considerNaming(reference: SessionReference(hostID: native.host.id, terminalID: snapshot.id, kind: snapshot.provider),
                                    remoteTitle: snapshot.title, messages: snapshot.messages,
                                    busy: snapshot.busy, turnCompleted: false, hasOlder: snapshot.hasOlder)
            }
        }
        native.onSnapshotChanged?(native.snapshot)
    }
    func activateAgentEnvironment(_ hostID: UUID) {
        guard let nextKimi = kimiEnvironments[hostID], let nextNative = nativeEnvironments[hostID] else { return }
        kimi = nextKimi; native = nextNative; selectedHostID = hostID
    }
    func resumeConnectionsAfterWake() {
        connections.filter { $0.wantsConnection }.forEach { $0.connect() }
        kimiEnvironments.values.filter { $0.connecting }.forEach { $0.connect() }
        nativeEnvironments.values.filter { $0.wantsConnection }.forEach { $0.connect() }
    }
    func agentConnections(for hostID: UUID) -> (kimi: KimiConnection, native: NativeAgentConnection)? {
        guard let kimi = kimiEnvironments[hostID], let native = nativeEnvironments[hostID] else { return nil }
        return (kimi, native)
    }
    func connectSSH(_ hostID: UUID) {
        guard let agents = agentConnections(for: hostID) else { return }
        if agents.kimi.host.enabledAgents.contains(.kimi), !agents.kimi.connecting { agents.kimi.connect() }
        if agents.native.host.hasNativeAgents, !agents.native.wantsConnection { agents.native.connect() }
    }
    func disconnectSSH(_ hostID: UUID) {
        kimiEnvironments[hostID]?.disconnect()
        nativeEnvironments[hostID]?.disconnect()
    }
    func disconnectHerdr(_ hostID: UUID) {
        connections.first { $0.id == hostID }?.disconnect()
        terminals.removeAll { $0.hostID == hostID }
    }
    func setAutoConnect(_ enabled: Bool, for hostID: UUID, herdr: Bool) {
        guard let index = connections.firstIndex(where: { $0.id == hostID }) else { return }
        let connection = connections[index]
        var host = connection.host
        if herdr { host.autoConnectHerdr = enabled } else { host.autoConnectSSH = enabled }
        var saved = connections.map(\.host)
        saved[index] = host
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: "hosts")
            connection.updateHost(host)
            kimiEnvironments[hostID]?.updateHost(host)
            nativeEnvironments[hostID]?.updateHost(host)
            if herdr {
                if enabled {
                    if started, host.enabledAgents.contains(.terminal) { connection.connect() }
                }
                else { disconnectHerdr(hostID) }
            } else {
                if enabled {
                    if started { connectSSH(hostID) }
                }
                else { disconnectSSH(hostID) }
            }
        } catch { workspaceError = error.localizedDescription }
    }
    func startNewTask() { if connections.isEmpty { configureHost() } else { draftingNewTask = true } }
    func configureHost(_ host: SSHHost? = nil) {
        if host?.isLocal == true { showLocalSetup = true; return }
        setupHost = host; showAddHost = true
    }
    func finishSetup(_ host: SSHHost, launch: TaskLaunchDefaults?, startTask: Bool) throws {
        try RemoteSetup.validate(host)
        guard !connections.contains(where: { $0.id != host.id && $0.host.destination == host.destination }) else {
            throw WorkbenchError(L("此 SSH 地址已添加。请从环境入口配置已有机器。"))
        }
        var saved = connections.map(\.host)
        if let index = saved.firstIndex(where: { $0.id == host.id }) { saved[index] = host }
        else { saved.append(host) }
        let data = try JSONEncoder().encode(saved)
        if let connection = connections.first(where: { $0.id == host.id }) {
            connection.updateHost(host)
            kimiEnvironments[host.id]?.updateHost(host); nativeEnvironments[host.id]?.updateHost(host)
            if !host.enabledAgents.contains(.terminal) { disconnectHerdr(host.id) }
            if !host.enabledAgents.contains(.kimi) { kimiEnvironments[host.id]?.disconnect() }
            if !host.hasNativeAgents { nativeEnvironments[host.id]?.disconnect() }
        } else {
            let connection = HostConnection(host: host); observe(connection); connections.append(connection)
            registerEnvironment(kimi: KimiConnection(host: host), native: NativeAgentConnection(host: host))
        }
        UserDefaults.standard.set(data, forKey: "hosts")
        configuredEnvironment = true
        activateAgentEnvironment(host.id)
        showHome(groupID: selectedGroupID)
        if started {
            if host.autoConnectSSH { connectSSH(host.id) }
            if host.autoConnectHerdr, host.enabledAgents.contains(.terminal) { selectedConnection?.connect() }
        }
        if let launch {
            let key = "new.task.defaults." + (selectedGroupID?.uuidString ?? "global")
            UserDefaults.standard.set(try JSONEncoder().encode(launch), forKey: key)
        }
        launchAfterSetup = startTask ? launch : nil
        pendingSetupLaunch = startTask
    }
    func setupDismissed() {
        setupHost = nil
        guard pendingSetupLaunch else { return }
        pendingSetupLaunch = false
        if launchAfterSetup?.provider == .terminal { showNewTerminal = true }
        else { draftingNewTask = true }
    }
    func reconnectSelectedEnvironment() {
        if showKimi { kimi.connect() }
        else if showNative { native.connect() }
        else { selectedConnection?.connect() }
    }
    var selectedReference: SessionReference? { openedSessions.first { $0.session.id == tabs.selectedID }?.session }
    var showNative: Bool { !showDashboard && [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(selectedReference?.kind) }
    var showKimi: Bool { !showDashboard && selectedReference?.kind == .kimi }
    var selectedTerminalID: String? { selectedReference?.kind == .terminal ? tabs.selectedID : nil }
    var previewTerminalID: String? { tabs.previewID }
    var selectedConnection: HostConnection? { connections.first { $0.id == selectedHostID } }
    var selectedTerminal: AttachedTerminal? { terminals.first { $0.id == selectedTerminalID } }
    var selectedGroup: WorkItemGroup? { workspace.groups.first { $0.id == selectedGroupID } }
    /// The scope resolved against what still exists. A group that was removed or a
    /// machine that was disconnected leaves nothing to narrow by and nothing to show,
    /// so the queue and the chips on screen can never disagree.
    var scopeGroup: WorkItemGroup? { selectedGroup }
    var scopeHost: SSHHost? { connections.first { $0.id == scopeHostID }?.host }
    var activeScope: ActiveScope { ActiveScope(groupName: scopeGroup?.name, hostName: scopeHost?.name) }
    /// Navigation/selection changes do not change membership. Rebuild only when
    /// saved groups change, not once per view pass or streamed catalog update.
    var groupIndex: SessionGroupIndex {
        // Read observable inputs even on cache hits; the cache itself is not UI state.
        let groups = workspace.groups
        if let cachedGroupIndex { return cachedGroupIndex }
        let index = SessionGroupIndex(groups: groups)
        cachedGroupIndex = index
        return index
    }
    func sidebarProjection(filter: SidebarRecentFilter) -> SidebarProjection {
        let revision = catalog.revision
        let starred = workspace.starred
        if let cachedSidebar, cachedSidebar.catalogRevision == revision, cachedSidebar.filter == filter { return cachedSidebar.projection }
        let projection = SidebarProjection(sessions: allSessions, starred: starred, filter: filter)
        cachedSidebar = (revision, filter, projection)
        return projection
    }
    func setScope(groupID: UUID?) {
        let inbox = onlyAttention
        showHome(groupID: groupID)
        onlyAttention = inbox
    }
    func setScope(hostID: UUID?) { scopeHostID = hostID }
    /// Clears one facet, or both. A group filter and a machine filter answer
    /// different questions, so dropping one keeps the other.
    func clearScope(_ facet: ActiveScope.Facet? = nil) {
        switch facet?.kind {
        case .group: selectedGroupID = nil; search = ""
        case .host: scopeHostID = nil
        case nil: selectedGroupID = nil; scopeHostID = nil; search = ""
        }
        saveWorkspace()
    }
    func clearSessionFilters() { scopeHostID = nil; search = "" }
    var pendingRestoration: [SavedTerminal] {
        openedSessions.filter { saved in
            !allSessions.contains { $0.id == saved.session.id && $0.online }
        }
    }
    private let sessionDateParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    func refreshLocalizedCatalog() { rebuildCatalog() }

    private func rebuildCatalog() {
        let terminalSessions = connections.flatMap { connection in
            (connection.snapshot?.panes ?? []).map { pane in
                let reference = SessionReference(hostID: connection.id, terminalID: pane.id)
                let review = workspace.needsReview(pane, on: connection.id)
                let section: WorkQueueSection = pane.status == "blocked" ? .attention : pane.status == "working" ? .running : review ? .review : .other
                let detail: String
                switch pane.status {
                case "blocked": detail = L("等待处理")
                case "working": detail = L("运行中")
                case "done": detail = review ? L("结果待查看") : L("结果已查看")
                case "idle": detail = L("空闲")
                default: detail = L("状态未知")
                }
                return WorkspaceSession(reference: reference,
                    title: workspace.displayTitle(pane.displayTitle, for: reference), directory: pane.directory, hostName: connection.host.name,
                    detail: "\(pane.agent ?? L("终端")) · \(detail)", online: connection.online, section: section,
                    canMarkReviewed: review && pane.revision != nil,
                    archived: workspace.archivedTerminals.contains(SessionReference(hostID: connection.id, terminalID: pane.id)))
            }
        }
        let conversations = kimiEnvironments.values.flatMap { kimi in kimi.sessions.map { session in
            let reference = SessionReference(hostID: kimi.host.id, terminalID: session.id, kind: .kimi)
            let section = workspace.kimiSection(session, on: kimi.host.id)
            return WorkspaceSession(reference: reference,
                title: workspace.displayTitle(session.displayTitle, for: reference), directory: session.cwd, hostName: kimi.host.name,
                detail: section == .review ? L("Kimi · 结果待查看") : "Kimi · \(session.status)", online: kimi.online,
                section: section, canMarkReviewed: section == .review, archived: archiveOverrides[reference.id] ?? (session.archived == true), updatedAt: sessionDateParser.date(from: session.updatedAt)?.timeIntervalSince1970 ?? 0)
        }
        }
        let agents = nativeEnvironments.values.flatMap { native in native.sessions.map { session in
            let reference = SessionReference(hostID: native.host.id, terminalID: session.id, kind: session.provider)
            let review = session.completed > 0 && workspace.reviewedKimiUpdates[reference.id] != String(session.completed)
            let section: WorkQueueSection = session.pending > 0 ? .attention : session.busy ? .running : session.error != nil ? .attention : review ? .review : .other
            return WorkspaceSession(reference: reference, title: workspace.displayTitle(session.title, for: reference), directory: session.cwd, hostName: native.host.name,
                detail: "\(session.provider.label) · \(section == .review ? L("结果待查看") : session.status)", online: native.online, section: section,
                canMarkReviewed: section == .review, archived: archiveOverrides[reference.id] ?? session.archived, updatedAt: session.updated)
        }
        }
        let next = ((conversations + agents) + terminalSessions).sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        allSessions = next
    }
    /// User-triggered list mutations (pin, archive) animate the row move;
    /// streamed catalog updates stay instant. Honors system Reduce Motion.
    private func animateCatalogChange(_ changes: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { changes() }
        else { withAnimation(.easeInOut(duration: 0.24), changes) }
    }
    /// Home, group workbench and inbox share one resolved group/machine scope.
    var sessionScope: SessionScope {
        SessionCatalog.scope(allSessions, starred: workspace.starred, group: scopeGroup,
                             hostFilter: scopeHost?.id, search: search,
                             onlyAttention: onlyAttention, showArchived: showArchived)
    }
    var scopedSessions: [WorkspaceSession] { sessionScope.sessions }

    private func observe(_ connection: HostConnection) {
        connection.onSnapshot = { [weak self] in self?.snapshotUpdated() }
        connection.$online.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.catalogChanged() } }.store(in: &subscriptions)
    }
    func removeHost(_ host: SSHHost) {
        guard let index = connections.firstIndex(where: { $0.id == host.id }) else { return }
        conversationPresentations.remove(prefix: host.id.uuidString + ":")
        connections[index].disconnect()
        kimiEnvironments[host.id]?.disconnect(); nativeEnvironments[host.id]?.disconnect()
        kimiEnvironments.removeValue(forKey: host.id); nativeEnvironments.removeValue(forKey: host.id)
        connections.remove(at: index)
        for saved in openedSessions where saved.session.hostID == host.id { close(saved.session.id) }
        terminals.removeAll { $0.hostID == host.id }
        let fallback = connections.first?.host.id ?? SSHHost.unconfigured.id
        if selectedHostID == host.id { selectedHostID = fallback }
        // A terminal on a surviving machine remains the target of host actions.
        if kimi.host.id == host.id || native.host.id == host.id { activateAgentEnvironment(selectedHostID) }
        if connections.isEmpty {
            kimi = KimiConnection(host: .unconfigured); native = NativeAgentConnection(host: .unconfigured)
            showDashboard = true; tabs.showOverview()
        }
        configuredEnvironment = !connections.isEmpty
        if scopeHostID == host.id { scopeHostID = nil }
        do { UserDefaults.standard.set(try JSONEncoder().encode(connections.map(\.host)), forKey: "hosts") }
        catch { managementError = L("机器已移除，但保存机器列表失败：\(error.localizedDescription)") }
        rebuildCatalog(); syncFileViewer(); saveWorkspace()
    }
    func open(_ pane: Pane, on connection: HostConnection, pinned: Bool = false) {
        openReference(SessionReference(hostID: connection.id, terminalID: pane.id), title: pane.displayTitle, pinned: pinned)
    }
    func open(_ item: WorkspaceSession, pinned: Bool = false) {
        guard item.online, !item.archived else { return }
        openReference(item.reference, title: item.title, pinned: pinned)
    }
    private func openReference(_ reference: SessionReference, title: String, pinned: Bool) {
        tabs.open(reference.id, pinned: true)
        openedSessions.removeAll { !tabs.ids.contains($0.session.id) }
        terminals.removeAll { !tabs.ids.contains($0.id) }
        if !openedSessions.contains(where: { $0.session == reference }) {
            openedSessions.append(SavedTerminal(session: reference, title: title))
        }
        select(reference.id)
        restoreAvailableSessions()
    }
    func pin(_ identity: String) {
        guard tabs.previewID == identity else { return }
        tabs.pin(identity); saveWorkspace()
    }
    func select(_ identity: String) {
        if !navigatingHistory { navigation.visit(identity) }
        tabs.select(identity); showDashboard = false; draftingNewTask = false
        if let reference = selectedReference {
            if reference.kind != .terminal { activateAgentEnvironment(reference.hostID) }
            selectedHostID = reference.hostID
            if let group = selectedGroup, !group.sessions.contains(reference) { selectedGroupID = nil }
            if let group = selectedGroup { workspace.lastSessionByGroup[group.id.uuidString] = reference.id }
            if [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(reference.kind) { native.select(reference.terminalID) }
            if reference.kind == .kimi, kimi.online { kimi.select(reference.terminalID) }
        }
        updateVisibility(focus: true); saveWorkspace(); syncFileViewer()
    }
    private var navigableSessionIDs: Set<String> {
        Set(openedSessions.map { $0.session.id }).union(allSessions.filter { $0.online && !$0.archived }.map(\.id))
    }
    func canNavigate(_ delta: Int) -> Bool {
        let available = navigableSessionIDs
        return navigation.canStep(delta, isAvailable: available.contains)
    }
    func navigate(_ delta: Int) {
        let available = navigableSessionIDs
        guard let id = navigation.step(delta, isAvailable: available.contains) else { return }
        navigatingHistory = true
        defer { navigatingHistory = false }
        if openedSessions.contains(where: { $0.session.id == id }) { select(id); return }
        if let item = allSessions.first(where: { $0.id == id && $0.online && !$0.archived }) { open(item) }
    }
    func nextAttentionTask() {
        let items = allSessions.filter { $0.online && !$0.archived && ($0.section == .attention || $0.section == .review) }
        guard !items.isEmpty else { return }
        let index = items.firstIndex(where: { $0.id == selectedReference?.id }) ?? -1
        open(items[(index + 1) % items.count])
    }
    private func updateVisibility(focus: Bool = false) {
        for terminal in terminals { terminal.context.isSurfaceVisible = !showDashboard && !draftingNewTask && terminal.id == selectedTerminalID }
        if focus && !showDashboard && !showKimi && !draftingNewTask { selectedTerminal?.context.requestFocus() }
    }
    func close(_ identity: String) {
        tabs.close(identity); openedSessions.removeAll { $0.session.id == identity }; terminals.removeAll { $0.id == identity }
        if let selected = tabs.selectedID, !showDashboard { select(selected) }
        else { showDashboard = true; updateVisibility(); saveWorkspace() }
    }
    func reconnectTerminal(_ terminal: AttachedTerminal) {
        terminals.removeAll { $0.id == terminal.id }
        restoreAvailableSessions()
    }
    func start() {
        guard !started else { return }
        if let reference = selectedReference, reference.kind != .terminal { activateAgentEnvironment(reference.hostID) }
        started = true
        for connection in connections {
            if connection.host.autoConnectSSH { connectSSH(connection.id) }
            if connection.host.autoConnectHerdr, connection.host.enabledAgents.contains(.terminal) { connection.connect() }
        }
    }
    func showHome(groupID: UUID? = nil) {
        onlyAttention = false; search = ""; showSessionDirectory = false
        showArchived = false; draftingNewTask = false
        selectedGroupID = groupID
        if let index = workspace.groups.firstIndex(where: { $0.id == groupID }) {
            workspace.groups[index].lastOpenedAt = Date().timeIntervalSince1970
        }
        showDashboard = true
        tabs.showOverview(); updateVisibility(); saveWorkspace()
    }
    func showInbox(groupID: UUID? = nil) { showHome(groupID: groupID); onlyAttention = true }
    func showAllSessions() { showHome(); showSessionDirectory = true }
    func newKimiCreated(_ session: KimiSession) {
        search = ""; onlyAttention = false; showArchived = false
        let reference = SessionReference(hostID: kimi.host.id, terminalID: session.id, kind: .kimi)
        associateWithCurrentGroup(reference)
        openReference(reference, title: session.displayTitle, pinned: true)
    }
    func newNativeCreated(_ session: NativeAgentSession) {
        search = ""; onlyAttention = false; showArchived = false
        let ref = SessionReference(hostID: native.host.id, terminalID: session.id, kind: session.provider)
        associateWithCurrentGroup(ref); openReference(ref, title: session.title, pinned: true)
    }
    func associateWithCurrentGroup(_ reference: SessionReference) {
        if let index = workspace.groups.firstIndex(where: { $0.id == selectedGroupID }), !workspace.groups[index].sessions.contains(reference) {
            workspace.groups[index].sessions.append(reference)
        }
    }
    var groupResumeSession: WorkspaceSession? {
        guard let group = selectedGroup, let id = workspace.lastSessionByGroup[group.id.uuidString] else { return nil }
        return allSessions.first { $0.id == id && !$0.archived && group.sessions.contains($0.reference) }
    }
    func editGroup(_ group: WorkItemGroup? = nil, sessionsOnly: Bool = false) {
        editingGroup = group; editingGroupSessionsOnly = sessionsOnly; showGroupEditor = true
    }
    func saveGroup(_ group: WorkItemGroup) {
        if let index = workspace.groups.firstIndex(where: { $0.id == group.id }) { workspace.groups[index] = group }
        else { workspace.groups.append(group) }
        showHome(groupID: group.id)
    }
    func updateGroup(_ group: WorkItemGroup) {
        guard let index = workspace.groups.firstIndex(where: { $0.id == group.id }) else { return }
        workspace.groups[index] = group; saveWorkspace()
    }
    func toggleGroupPin(_ group: WorkItemGroup) {
        var updated = group; updated.isPinned.toggle(); updateGroup(updated)
    }
    func addOutcome(_ outcome: GroupOutcome, to groupID: UUID) {
        guard let index = workspace.groups.firstIndex(where: { $0.id == groupID }) else { return }
        workspace.groups[index].outcomes.append(outcome); saveWorkspace()
    }
    @discardableResult func applyGroupSuggestions(_ suggestions: [GroupSuggestion]) -> Int {
        let undo = workspace.applyGrouping(suggestions, sessions: allSessions)
        let count = undo.after.reduce(0) { $0 + $1.value.count - (undo.before[$1.key]?.count ?? 0) }
        if count > 0 { groupingUndo = undo; saveWorkspace() }
        return count
    }
    func undoGroupSuggestions() -> Bool {
        guard let undo = groupingUndo, workspace.undoGrouping(undo) else { return false }
        groupingUndo = nil; saveWorkspace(); return true
    }
    func inspect(_ item: WorkspaceSession) {
        guard item.online, !item.archived else { return }
        inspectionOrder.update(dashboardProjection.attention.items.map(\.id))
        inspectingSession = item
        if let agents = agentConnections(for: item.reference.hostID) {
            if item.reference.kind == .kimi { agents.kimi.select(item.reference.terminalID) }
            else if item.reference.kind != .terminal { agents.native.select(item.reference.terminalID) }
        }
    }
    func inspectNext(after item: WorkspaceSession) {
        let previousNext = inspectionOrder.next(after: item.id)
        let remaining = dashboardProjection.attention.items.filter { $0.id != item.id }
        inspectionOrder.update(remaining.map(\.id))
        if let next = remaining.first(where: { $0.id == previousNext }) ?? remaining.first {
            inspect(next)
        } else { inspectingSession = nil }
    }
    func endInspection() {
        guard let ref = selectedReference, let agents = agentConnections(for: ref.hostID) else { return }
        if ref.kind == .kimi { agents.kimi.select(ref.terminalID) }
        else if ref.kind != .terminal { agents.native.select(ref.terminalID) }
    }
    func dashboardObservation(_ item: WorkspaceSession) -> DashboardObservation {
        let ref = item.reference
        var revision = ""
        var state = "other"
        switch item.section {
        case .attention: state = "attention"
        case .review: state = "review"
        case .running: state = "running"
        case .other: break
        }
        if ref.kind == .kimi, let c = kimiEnvironments[ref.hostID], let session = c.sessions.first(where: { $0.id == ref.terminalID }) {
            revision = item.section == .review ? session.updatedAt : session.pendingInteraction ?? session.lastTurnReason ?? ""
        } else if ref.kind == .terminal {
            let pane = connections.first { $0.id == ref.hostID }?.snapshot?.panes.first { $0.id == ref.terminalID }
            revision = pane?.revision.map(String.init) ?? ""
        } else if let session = nativeEnvironments[ref.hostID]?.sessions.first(where: { $0.id == ref.terminalID }) {
            revision = item.section == .review ? String(session.completed) : "\(session.completed):\(session.pending):\(session.error ?? "")"
        }
        return DashboardObservation(state: state, revision: revision)
    }
    var dashboardChanges: [WorkspaceSession] {
        scopedSessions.filter { $0.online && !$0.archived && dashboardObservation($0).isNew(since: workspace.dashboardSeen[$0.id]) }
    }
    func acknowledgeDashboardChanges() {
        for item in scopedSessions where item.online && !item.archived {
            workspace.dashboardSeen[item.id] = dashboardObservation(item)
        }
        saveWorkspace()
    }
    func reviewInspected(_ snapshot: NativeAgentSnapshot, on hostID: UUID) {
        let ref = SessionReference(hostID: hostID, terminalID: snapshot.id, kind: snapshot.provider)
        guard inspectingSession?.reference == ref else { return }
        workspace.markReviewed(snapshot, on: hostID)
        rebuildCatalog(); saveWorkspace()
    }
    func reviewInspected(_ session: KimiSession, on hostID: UUID) {
        let ref = SessionReference(hostID: hostID, terminalID: session.id, kind: .kimi)
        guard inspectingSession?.reference == ref,
              kimiEnvironments[hostID]?.sessions.first(where: { $0.id == session.id })?.updatedAt == session.updatedAt else { return }
        workspace.markReviewed(session, on: hostID)
        rebuildCatalog(); saveWorkspace()
    }
    var groupSummaries: [TaskGroupSummary] {
        TaskGroupSummary.ordered(groups: workspace.groups, sessions: allSessions, hostID: scopeHost?.id)
    }
    var groupShortcuts: [TaskGroupSummary] {
        let revision = catalog.revision
        let groups = workspace.groups
        let selected = selectedGroupID
        if let cachedGroupShortcuts, cachedGroupShortcuts.catalogRevision == revision, cachedGroupShortcuts.selectedID == selected { return cachedGroupShortcuts.summaries }
        let summaries = TaskGroupSummary.shortcuts(groups: groups, sessions: allSessions, selectedID: selected)
        cachedGroupShortcuts = (revision, selected, summaries)
        return summaries
    }
    func markReviewed(_ item: WorkspaceSession) {
        guard let kimi = kimiEnvironments[item.reference.hostID], let native = nativeEnvironments[item.reference.hostID] else { return }
        guard item.online else { return }
        if [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(item.reference.kind), let session = native.sessions.first(where: { $0.id == item.reference.terminalID }) {
            workspace.reviewedKimiUpdates[item.id] = String(session.completed)
        } else if item.reference.kind == .kimi, let session = kimi.sessions.first(where: { $0.id == item.reference.terminalID }) {
            workspace.markReviewed(session, on: kimi.host.id)
        } else if let connection = connections.first(where: { $0.id == item.reference.hostID }),
                  let pane = connection.snapshot?.panes.first(where: { $0.id == item.reference.terminalID }) {
            workspace.markReviewed(pane, on: connection.id)
        }
        rebuildCatalog(); saveWorkspace()
    }
    func reviewDisplayed(_ session: KimiSession, on hostID: UUID) {
        let reference = SessionReference(hostID: hostID, terminalID: session.id, kind: .kimi)
        guard !showDashboard, selectedReference == reference else { return }
        let previous = workspace.reviewedKimiUpdates[reference.id]
        workspace.markReviewed(session, on: hostID)
        if workspace.reviewedKimiUpdates[reference.id] != previous { rebuildCatalog(); saveWorkspace() }
    }
    func reviewDisplayed(_ snapshot: NativeAgentSnapshot, on hostID: UUID) {
        let reference = SessionReference(hostID: hostID, terminalID: snapshot.id, kind: snapshot.provider)
        guard !showDashboard, selectedReference == reference else { return }
        let previous = workspace.reviewedKimiUpdates[reference.id]
        workspace.markReviewed(snapshot, on: hostID)
        if workspace.reviewedKimiUpdates[reference.id] != previous { rebuildCatalog(); saveWorkspace() }
    }
    func showArchive() {
        showSessionDirectory = false; search = ""
        showArchived = true; onlyAttention = false
        selectedGroupID = nil; clearScope(); showDashboard = true
        tabs.showOverview(); updateVisibility(); saveWorkspace()
    }
    func toggleStar(_ reference: SessionReference) {
        animateCatalogChange { workspace.toggleStar(reference) }
        saveWorkspace()
    }
    func setGroups(_ groupIDs: Set<UUID>, for reference: SessionReference, newGroupName: String = "") {
        for index in workspace.groups.indices {
            workspace.groups[index].sessions.removeAll { $0 == reference }
            if groupIDs.contains(workspace.groups[index].id) { workspace.groups[index].sessions.append(reference) }
        }
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            workspace.groups.append(WorkItemGroup(name: name, goal: "", nextStep: "", sessions: [reference]))
        }
        saveWorkspace()
    }
    /// The batch decision state for one session, built from the same runtime
    /// metadata the sections already use. `fingerprint` carries the per-source
    /// revision so output arriving mid-batch is detected before committing.
    func archiveSubject(_ item: WorkspaceSession) -> ArchiveSubject {
        guard let kimi = kimiEnvironments[item.reference.hostID], let native = nativeEnvironments[item.reference.hostID] else { return ArchiveSubject(reference: item.reference, fingerprint: "missing", online: false) }
        let starred = workspace.starred.contains(item.reference)
        let queued = native.queue.items(for: item.reference).filter { $0.state != .delivered }.count
        if [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(item.reference.kind) {
            guard let session = native.sessions.first(where: { $0.id == item.reference.terminalID }) else {
                return ArchiveSubject(reference: item.reference, fingerprint: "missing", online: false)
            }
            return ArchiveSubject(reference: item.reference,
                                  fingerprint: "\(session.completed):\(session.updated)",
                                  archived: session.archived, online: native.online, busy: session.busy,
                                  pendingInteraction: session.pending > 0, failed: session.error != nil,
                                  stopped: session.cancelled == true, starred: starred,
                                  completedTurns: session.completed, reviewed: item.section != .review,
                                  queuedMessages: queued, hasCompletionSignal: true)
        }
        if item.reference.kind == .kimi {
            guard let session = kimi.sessions.first(where: { $0.id == item.reference.terminalID }) else {
                return ArchiveSubject(reference: item.reference, fingerprint: "missing", online: false)
            }
            return ArchiveSubject(reference: item.reference, fingerprint: session.updatedAt,
                                  archived: session.archived == true, online: kimi.online, busy: session.isTurnRunning,
                                  pendingInteraction: session.pendingInteraction != nil,
                                  failed: session.lastTurnReason == "failed", stopped: false, starred: starred,
                                  completedTurns: session.lastTurnReason == "completed" ? 1 : 0,
                                  reviewed: item.section != .review, queuedMessages: queued,
                                  hasCompletionSignal: session.lastTurnReason != nil)
        }
        let pane = connections.first { $0.id == item.reference.hostID }?
            .snapshot?.panes.first { $0.id == item.reference.terminalID }
        // A shell reporting idle has finished no turn, so only an explicit done
        // status carries completion for a terminal.
        return ArchiveSubject(reference: item.reference,
                              fingerprint: pane?.revision.map(String.init) ?? "unknown",
                              archived: item.archived, online: item.online, busy: pane?.status == "working",
                              pendingInteraction: pane?.status == "blocked", failed: false, stopped: false,
                              starred: starred, completedTurns: pane?.status == "done" ? 1 : 0,
                              reviewed: item.section != .review, queuedMessages: 0,
                              hasCompletionSignal: pane?.status == "done")
    }
    /// The inbox narrowing lives in `SessionCatalog.scope`, so the dashboard never
    /// filters the same sections a second time with different rules.
    var dashboardProjection: DashboardProjection {
        let scoped = scopedSessions
        let subjects = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, archiveSubject($0)) })
        return DashboardProjection(sessions: scoped, subjects: subjects,
                                   hasConfiguredEnvironment: configuredEnvironment, concurrencyLimit: 4,
                                   filtered: !activeScope.isEmpty || !search.isEmpty)
    }
    /// What could not be restored, any local-storage failure, and the filters currently
    /// narrowing the queue. A save or read failure used to be recorded and never shown,
    /// and an invisible filter reads as missing sessions.
    var dashboardContext: DashboardContext {
        DashboardContext(pendingRestoration: pendingRestoration.filter { saved in
            (selectedGroup.map { $0.sessions.contains(saved.session) } ?? true) &&
            (scopeHost.map { saved.session.hostID == $0.id } ?? true)
        }, restoreReport: restoreReport.filter { entry in
            (selectedGroup.map { $0.sessions.contains(entry.reference) } ?? true) &&
            (scopeHost.map { entry.reference.hostID == $0.id } ?? true)
        }, storageError: workspaceError,
                         scope: activeScope)
    }
    /// Runs one batch to completion. Each item is re-validated immediately before
    /// its request, and the catalog is refreshed once at the end rather than per
    /// item so navigation stays responsive.
    func runBatchArchive(_ plan: BatchArchivePlan) {
        guard !isArchiving, !plan.isEmpty else { return }
        executeBatchArchive(BatchArchiveRun(plan: plan))
    }
    private func executeBatchArchive(_ initial: BatchArchiveRun) {
        isArchiving = true; archiveResult = nil; managementError = nil
        kimi.beginArchiveBatch()
        Task {
            var run = initial
            while !run.isFinished {
                let batch = run.nextBatch()
                if batch.isEmpty { break }
                for candidate in batch {
                    let live = allSessions.first { $0.id == candidate.id }.map(archiveSubject)
                    if let skip = run.revalidate(candidate, against: live) { run.skip(candidate, skip); continue }
                    do { try await archiveRequest(candidate.reference); run.succeed(candidate) }
                    catch { run.fail(candidate, error.localizedDescription) }
                }
            }
            for candidate in run.archived {
                workspace.starred.removeAll { $0 == candidate.reference }
                if tabs.ids.contains(candidate.id) { close(candidate.id) }
            }
            archiveResult = run
            await syncArchivedSessions()
            kimi.endArchiveBatch()
            isArchiving = false
            rebuildCatalog(); saveWorkspace()
        }
    }
    func undoBatchArchive() {
        guard !isArchiving, let result = archiveResult, !result.archived.isEmpty else { return }
        let targets = result.undoTargets
        isArchiving = true
        kimi.beginArchiveBatch()
        Task {
            var result = result; result.beginUndo()
            for reference in targets {
                do { try await archiveRequest(reference, archived: false); result.restored(reference) }
                catch { result.undoFailed(reference, error.localizedDescription) }
            }
            archiveResult = result
            await syncArchivedSessions()
            kimi.endArchiveBatch()
            isArchiving = false
            rebuildCatalog(); saveWorkspace()
        }
    }
    func retryBatchArchive() {
        guard !isArchiving, var result = archiveResult, result.retryPlan != nil else { return }
        result.retryFailures(); executeBatchArchive(result)
    }
    private func archiveRequest(_ reference: SessionReference, archived: Bool = true) async throws {
        guard let kimi = kimiEnvironments[reference.hostID], let native = nativeEnvironments[reference.hostID] else { throw WorkbenchError("The task environment is unavailable") }
        if reference.kind == .kimi { try await kimi.setArchived(reference.terminalID, archived: archived, refresh: false) }
        else if [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(reference.kind) {
            try await native.setArchived(reference.terminalID, archived: archived)
        } else if archived { workspace.archivedTerminals.insert(reference) }
        else { workspace.archivedTerminals.remove(reference) }
    }
    private func syncArchivedSessions() async {
        do { for native in nativeEnvironments.values where native.online { try await native.refresh() } }
        catch { managementError = L("归档操作已记录，列表同步失败：\(error.localizedDescription)") }
        do { for kimi in kimiEnvironments.values where kimi.online { try await kimi.refreshSessions() } }
        catch { managementError = L("归档操作已记录，列表同步失败：\(error.localizedDescription)") }
    }
    /// Whether selected transcript text can become a quote right now. A terminal
    /// session has no draft to receive it, so the action is hidden rather than
    /// offered as a no-op.
    var canQuoteSelection: Bool {
        guard !showDashboard, let reference = selectedReference else { return false }
        return reference.kind == .kimi ? kimi.online : [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(reference.kind) && native.online
    }
    /// Appends the selection to the current session's draft as a Markdown quote.
    /// Existing draft text is kept: quoting is an addition, not a replacement.
    func quoteSelection(_ text: String) {
        guard canQuoteSelection, let reference = selectedReference else { return }
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n")
        let id = reference.terminalID
        if reference.kind == .kimi {
            let existing = kimi.drafts[id] ?? ""
            kimi.drafts[id] = existing.isEmpty ? quoted + "\n\n" : existing + "\n\n" + quoted + "\n\n"
        } else if [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(reference.kind) {
            let existing = native.drafts[id] ?? ""
            native.drafts[id] = existing.isEmpty ? quoted + "\n\n" : existing + "\n\n" + quoted + "\n\n"
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil) }
    }
    /// Review feedback is staged in the same task; it never sends automatically.
    func appendReviewContext(_ text: String, to reference: SessionReference) {
        guard selectedReference == reference, canQuoteSelection else { return }
        let id = reference.terminalID
        if reference.kind == .kimi {
            let existing = kimi.drafts[id] ?? ""
            kimi.drafts[id] = existing + (existing.isEmpty ? "" : "\n\n") + text + "\n\n"
        } else {
            let existing = native.drafts[id] ?? ""
            native.drafts[id] = existing + (existing.isEmpty ? "" : "\n\n") + text + "\n\n"
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil) }
    }
    func discoverLocalAgents() {
        guard !probingLocal else { return }
        probingLocal = true
        if let host = connections.first(where: { $0.host.isLocal })?.host {
            localAgentPaths.merge(host.localAgentPaths) { current, _ in current }
        }
        Task {
            defer { probingLocal = false }
            for kind in LocalAgentDiscovery.agents {
                localAgents[kind] = await LocalAgentDiscovery.discover(kind, override: localAgentPaths[kind.rawValue])
            }
        }
    }
    func connectLocalAgents(_ kinds: [SessionKind]) throws {
        let enabled = kinds.filter { LocalAgentDiscovery.supported.contains($0) && localAgents[$0]?.executablePath != nil }
        guard !enabled.isEmpty else { throw WorkbenchError(L("请选择已检测到的本机 Agent")) }
        var host = SSHHost(id: ExecutionEnvironment.localHostID, name: L("本机"), destination: "",
                           enabledAgents: enabled, autoConnectHerdr: false)
        host.localAgentPaths = Dictionary(uniqueKeysWithValues: enabled.compactMap { kind in
            localAgents[kind]?.executablePath.map { (kind.rawValue, $0) }
        })
        var saved = connections.map(\.host)
        if let index = saved.firstIndex(where: { $0.isLocal }) { saved[index] = host }
        else { saved.append(host) }
        let data = try JSONEncoder().encode(saved)
        if let connection = connections.first(where: { $0.id == host.id }) {
            disconnectSSH(host.id)
            connection.updateHost(host)
            kimiEnvironments[host.id]?.updateHost(host); nativeEnvironments[host.id]?.updateHost(host)
        } else {
            let connection = HostConnection(host: host); observe(connection); connections.append(connection)
            registerEnvironment(kimi: KimiConnection(host: host), native: NativeAgentConnection(host: host))
        }
        UserDefaults.standard.set(data, forKey: "hosts")
        configuredEnvironment = true
        activateAgentEnvironment(host.id)
        connectSSH(host.id)
        draftingNewTask = true
    }
    /// Local display names survive provider catalog refreshes.
    func rename(_ item: WorkspaceSession, title: String) {
        workspace.rename(item.reference, title: title)
        if let index = openedSessions.firstIndex(where: { $0.session == item.reference }) {
            openedSessions[index] = SavedTerminal(session: item.reference,
                title: workspace.displayTitle(item.title, for: item.reference))
        }
        rebuildCatalog(); saveWorkspace()
    }
    /// Excerpt for a user-triggered name suggestion, from messages already
    /// loaded locally; a session never opened this launch offers nothing.
    func namingExcerpt(for reference: SessionReference) -> String? {
        let messages: [KimiMessage]?
        switch reference.kind {
        case .kimi: messages = kimiEnvironments[reference.hostID]?.loadedMessages(for: reference.terminalID)
        case .terminal: messages = nil
        default: messages = nativeEnvironments[reference.hostID]?.loadedMessages(for: reference.terminalID)
        }
        return messages.flatMap { SessionNaming.excerpt(from: $0) }
    }
    func automaticNamingStatus(for reference: SessionReference) -> String {
        if workspace.autoNamedSessions.contains(reference.id) { return L("已自动命名，名称保存在本机。") }
        if workspace.sessionTitles[reference.id] != nil { return L("已设置本机名称，自动命名不会覆盖。") }
        let configuration = ActivitySummarySettings.shared.configuration
        guard configuration.enabled && configuration.nameSessions else { return L("自动命名未开启。") }
        guard configuration.isValid else { return L("请先配置有效的摘要服务。") }
        if namingInProgress.contains(reference.id) { return L("正在自动命名…") }
        if let error = namingErrors[reference.id] { return L("自动命名失败：\(error)") }
        guard namingExcerpt(for: reference) != nil else { return L("首条消息尚未加载；打开会话后会自动加载历史并命名。") }
        return L("仅为占位标题自动命名；已有标题保持不变，Kimi 会等待本轮完成。")
    }
    private func reconsiderNaming() {
        for kimi in kimiEnvironments.values {
            guard let conversation = kimi.conversation else { continue }
            let session = conversation.snapshot.session
            considerNaming(reference: SessionReference(hostID: kimi.host.id, terminalID: session.id, kind: .kimi),
                           remoteTitle: session.title, messages: conversation.messages, busy: session.isTurnRunning,
                           turnCompleted: session.lastTurnReason == "completed", hasOlder: conversation.hasOlder)
        }
        for native in nativeEnvironments.values {
            guard let snapshot = native.snapshot else { continue }
            considerNaming(reference: SessionReference(hostID: native.host.id, terminalID: snapshot.id, kind: snapshot.provider),
                           remoteTitle: snapshot.title, messages: snapshot.messages, busy: snapshot.busy,
                           turnCompleted: false, hasOlder: snapshot.hasOlder)
        }
    }
    /// One automatic naming attempt per session, only while its remote title
    /// is still a placeholder. Kimi waits for the first completed turn so a
    /// server-side title wins the race; native bridge titles never improve.
    private func considerNaming(reference: SessionReference, remoteTitle: String, messages: [KimiMessage],
                                busy: Bool, turnCompleted: Bool, hasOlder: Bool) {
        let settings = ActivitySummarySettings.shared
        let configuration = settings.configuration
        guard configuration.enabled, configuration.nameSessions, configuration.isValid else { return }
        guard workspace.sessionTitles[reference.id] == nil, !workspace.autoNamedSessions.contains(reference.id),
              namingAttempts[reference.id] != settings.revision else { return }
        if reference.kind == .kimi { guard !busy, turnCompleted else { return } }
        if hasOlder { loadHistoryForNaming(reference, remoteTitle: remoteTitle); return }
        guard let excerpt = SessionNaming.excerpt(from: messages, hasOlder: hasOlder),
              SessionNaming.isPlaceholder(remoteTitle, kind: reference.kind, firstUserText: excerpt) else { return }
        let revision = settings.revision
        namingAttempts[reference.id] = revision
        namingInProgress.insert(reference.id)
        namingErrors.removeValue(forKey: reference.id)
        namingLog.info("attempt \(reference.id, privacy: .public)")
        Task {
            defer { if namingAttempts[reference.id] == revision { namingInProgress.remove(reference.id) } }
            do {
                guard settings.revision == revision else { return }
                let name = try await sessionNamer(configuration, excerpt, AppLanguage.current.localization)
                guard settings.revision == revision, workspace.sessionTitles[reference.id] == nil,
                      !workspace.autoNamedSessions.contains(reference.id),
                      let latestTitle = namingRemoteTitle(for: reference),
                      SessionNaming.isPlaceholder(latestTitle, kind: reference.kind, firstUserText: excerpt) else { return }
                applyGeneratedName(name, for: reference)
                namingLog.info("named \(reference.id, privacy: .public)")
            } catch {
                if settings.revision == revision { namingErrors[reference.id] = error.localizedDescription }
                namingLog.error("failed \(reference.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    /// Naming needs the first user message, which a partially loaded history
    /// does not contain. Pull the remaining pages in the background instead of
    /// waiting for the user to scroll to the top; each page re-enters
    /// `considerNaming` through the conversation publishers. Only titles that
    /// could still be placeholders fetch, so named sessions never pay for it.
    private func loadHistoryForNaming(_ reference: SessionReference, remoteTitle: String) {
        guard SessionNaming.couldBePlaceholder(remoteTitle, kind: reference.kind) else { return }
        if reference.kind == .kimi { kimiEnvironments[reference.hostID]?.loadAllHistoryForSearch() }
        else { nativeEnvironments[reference.hostID]?.loadAllHistoryForSearch() }
    }
    private func namingRemoteTitle(for reference: SessionReference) -> String? {
        if reference.kind == .kimi {
            guard let connection = kimiEnvironments[reference.hostID] else { return nil }
            if connection.conversation?.snapshot.session.id == reference.terminalID { return connection.conversation?.snapshot.session.title }
            return connection.sessions.first { $0.id == reference.terminalID }?.title
        }
        guard let connection = nativeEnvironments[reference.hostID] else { return nil }
        if connection.snapshot?.id == reference.terminalID { return connection.snapshot?.title }
        return connection.sessions.first { $0.id == reference.terminalID }?.title
    }
    private func applyGeneratedName(_ name: String, for reference: SessionReference) {
        workspace.rename(reference, title: name)
        workspace.autoNamedSessions.insert(reference.id)
        if let index = openedSessions.firstIndex(where: { $0.session == reference }) {
            openedSessions[index] = SavedTerminal(session: reference, title: name)
        }
        rebuildCatalog(); saveWorkspace()
    }
    func canArchive(_ item: WorkspaceSession) -> Bool {
        guard let kimi = kimiEnvironments[item.reference.hostID], let native = nativeEnvironments[item.reference.hostID] else { return false }
        if item.reference.kind == .terminal { return true }
        if [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(item.reference.kind) { return native.online && native.sessions.first(where: { $0.id == item.reference.terminalID })?.busy == false }
        return kimi.online && kimi.sessions.first(where: { $0.id == item.reference.terminalID })?.busy == false
    }
    func setArchived(_ item: WorkspaceSession, archived: Bool) {
        guard let kimi = kimiEnvironments[item.reference.hostID], let native = nativeEnvironments[item.reference.hostID] else { return }
        guard canArchive(item), !managing.contains(item.id) else { return }
        managementError = nil
        if item.reference.kind == .terminal {
            animateCatalogChange {
                if archived { workspace.archivedTerminals.insert(item.reference) }
                else { workspace.archivedTerminals.remove(item.reference) }
                if archived { workspace.starred.removeAll { $0 == item.reference } }
                rebuildCatalog()
            }
            if archived, tabs.ids.contains(item.id) { close(item.id) }
            saveWorkspace()
            return
        }
        managing.insert(item.id)
        // Optimistic: the row moves with the click; a failure animates it back.
        archiveOverrides[item.id] = archived
        animateCatalogChange { rebuildCatalog() }
        if archived, tabs.ids.contains(item.id) { close(item.id) }
        Task {
            defer { managing.remove(item.id) }
            do {
                if item.reference.kind == .kimi { try await kimi.setArchived(item.reference.terminalID, archived: archived) }
                else { try await native.action(item.reference.terminalID, "archive", ["archived": .bool(archived)]) }
                archiveOverrides.removeValue(forKey: item.id)
                if archived { workspace.starred.removeAll { $0 == item.reference } }
                rebuildCatalog(); saveWorkspace()
            } catch {
                archiveOverrides.removeValue(forKey: item.id)
                animateCatalogChange { rebuildCatalog() }
                managementError = error.localizedDescription
            }
        }
    }
    func deleteConfirmed(_ item: WorkspaceSession) {
        guard let kimi = kimiEnvironments[item.reference.hostID], let native = nativeEnvironments[item.reference.hostID] else { return }
        guard item.online, !managing.contains(item.id) else { return }
        managing.insert(item.id); managementError = nil
        Task {
            defer { managing.remove(item.id) }
            do {
                if item.reference.kind == .kimi { try await kimi.deleteSession(item.reference.terminalID) }
                else if [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(item.reference.kind) { try await native.action(item.reference.terminalID, "delete") }
                else if let connection = connections.first(where: { $0.id == item.reference.hostID }) { try await connection.closeTerminal(item.reference.terminalID) }
                if tabs.ids.contains(item.id) { close(item.id) }
                workspace.removeSession(item.reference)
                let kind = item.reference.kind == .kimi ? "kimi" : "native"
                conversationPresentations.remove("\(item.reference.hostID):\(kind):\(item.reference.terminalID)")
                ConversationReadingMemory.shared.remove("\(item.reference.hostID):\(kind):\(item.reference.terminalID)")
                rebuildCatalog(); saveWorkspace()
            } catch { managementError = error.localizedDescription }
        }
    }
    var selectedItem: WorkspaceSession? { allSessions.first { $0.id == tabs.selectedID } }
    /// Kimi and the native agents each own their own SSH host; terminals use their
    /// own connection. The file viewer must read from that same host, not a default.
    var selectedHost: SSHHost? {
        guard let reference = selectedReference else { return nil }
        return connections.first { $0.id == reference.hostID }?.host
    }
    func toggleFileViewer() {
        showFileViewer.toggle()
        if showFileViewer { syncFileViewer() } else { fileBrowser.cancel() }
    }
    private func syncFileViewer() {
        guard showFileViewer else { return }
        let directory = selectedItem?.directory ?? ""
        var messages: [KimiMessage] = []
        var liveTools: [KimiLiveTool] = []
        if let reference = selectedReference, reference.kind == .kimi,
           let conversation = kimiEnvironments[reference.hostID]?.conversation,
           conversation.snapshot.session.id == reference.terminalID {
            messages = conversation.messages
            liveTools = conversation.live?.runningTools ?? []
        } else if let reference = selectedReference,
                  [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(reference.kind),
                  let snapshot = nativeEnvironments[reference.hostID]?.snapshot,
                  snapshot.id == reference.terminalID {
            messages = snapshot.messages
        }
        let hints = RemoteGitDirectoryHints.candidates(messages: messages, liveTools: liveTools,
                                                       sessionDirectory: directory)
        fileBrowser.configure(host: selectedHost, cwd: directory, directoryHints: hints)
    }
    func forgetRestoration(_ saved: SavedTerminal) { close(saved.session.id) }
    private func saveWorkspace() {
        guard canSaveWorkspace else { return }
        var saved = workspace
        saved.pinned = tabs.ids.filter { $0 != tabs.previewID }.compactMap { id in openedSessions.first { $0.session.id == id } }
        saved.selectedTerminalID = tabs.selectedID == tabs.previewID ? nil : tabs.selectedID
        saved.selectedGroupID = selectedGroupID
        saved.destination = showDashboard || saved.selectedTerminalID == nil ? .home : .session
        if saved != workspace { workspace = saved }
        workspaceWriter.save(saved) { [weak self] error in
            if let error { Task { @MainActor in self?.workspaceError = "工作台保存失败：\(error)" } }
        }
    }
    private func catalogChanged() {
        rebuildCatalog()
        updateTaskEvents()
        resolveRestoreReports()
        var baselineChanged = false
        for item in allSessions where item.online && !item.archived && (item.section == .running || item.section == .other) {
            let observation = dashboardObservation(item)
            if workspace.dashboardSeen[item.id] != observation { workspace.dashboardSeen[item.id] = observation; baselineChanged = true }
        }
        if baselineChanged { saveWorkspace() }
        if let id = pendingNotificationID, let item = allSessions.first(where: { $0.id == id && $0.online && !$0.archived }) {
            pendingNotificationID = nil; open(item)
        }
        for item in allSessions where item.archived && tabs.ids.contains(item.id) { close(item.id) }
        restoreAvailableSessions()
    }
    /// The resolved outcomes of sessions that were mid-turn the last time each
    /// source was seen. Reported once per reconnect, dismissed explicitly.
    private(set) var restoreReport: [RestoredSession] = []
    /// Sources currently offline (or never connected this launch), keyed
    /// "kind:hostID". An armed source resolves its report on its first fresh
    /// catalog after reconnecting.
    @ObservationIgnored private var restoreArmed: Set<String> = []
    func dismissRestoreReport() { restoreReport = [] }
    func openRestoreEntry(_ entry: RestoredSession) {
        guard let item = allSessions.first(where: { $0.id == entry.id && $0.online && !$0.archived }) else { return }
        open(item)
    }
    /// Runs before the dashboardSeen baseline is updated below, so the comparison
    /// still sees the state the session had when the connection was lost.
    private func resolveRestoreReports() {
        for (hostID, connection) in kimiEnvironments {
            let key = "kimi:\(hostID)"
            guard connection.online else { restoreArmed.insert(key); continue }
            guard restoreArmed.remove(key) != nil else { continue }
            collectKimiRestoreEntries(connection)
        }
        for (hostID, connection) in nativeEnvironments {
            let key = "native:\(hostID)"
            guard connection.online else { restoreArmed.insert(key); continue }
            guard connection.catalogSynced, restoreArmed.remove(key) != nil else { continue }
            collectNativeRestoreEntries(connection)
        }
    }
    private func collectKimiRestoreEntries(_ connection: KimiConnection) {
        let hostID = connection.host.id
        var entries: [RestoredSession] = []
        for (id, observation) in workspace.dashboardSeen {
            guard observation.state == "running", let reference = SessionReference(restoreID: id),
                  reference.hostID == hostID, reference.kind == .kimi else { continue }
            let session = connection.sessions.first { $0.id == reference.terminalID }
            let probe = SessionRestoreProbe(exists: session != nil, archived: session?.archived == true,
                                            busy: session?.busy ?? false,
                                            pendingInteraction: ["approval", "question"].contains(session?.pendingInteraction ?? ""),
                                            failed: session?.lastTurnReason == "failed",
                                            completed: session?.lastTurnReason == "completed")
            guard let outcome = RestoreResolution.outcome(probe) else { continue }
            entries.append(RestoredSession(reference: reference, title: restoreTitle(reference, fallback: session?.title ?? ""),
                                           hostName: connection.host.name, outcome: outcome))
        }
        mergeRestoreEntries(entries)
    }
    private func collectNativeRestoreEntries(_ connection: NativeAgentConnection) {
        let hostID = connection.host.id
        var entries: [RestoredSession] = []
        for (id, observation) in workspace.dashboardSeen {
            guard observation.state == "running", let reference = SessionReference(restoreID: id),
                  reference.hostID == hostID, reference.kind != .kimi else { continue }
            let session = connection.sessions.first { $0.id == reference.terminalID && $0.provider == reference.kind }
            // Running baselines record "completed:pending:error" (see dashboardObservation),
            // so a completion is only claimed when the count provably advanced.
            let baselineCompleted = observation.revision.split(separator: ":").first.flatMap { Int($0) }
            let probe = SessionRestoreProbe(exists: session != nil, archived: session?.archived ?? false,
                                            busy: session?.busy ?? false,
                                            pendingInteraction: (session?.pending ?? 0) > 0,
                                            failed: session?.error != nil,
                                            completed: baselineCompleted.map { (session?.completed ?? 0) > $0 } ?? false)
            guard let outcome = RestoreResolution.outcome(probe) else { continue }
            entries.append(RestoredSession(reference: reference, title: restoreTitle(reference, fallback: session?.title ?? ""),
                                           hostName: connection.host.name, outcome: outcome))
        }
        mergeRestoreEntries(entries)
    }
    private func restoreTitle(_ reference: SessionReference, fallback: String) -> String {
        let named = workspace.displayTitle(fallback, for: reference)
        return named.isEmpty ? (allSessions.first { $0.id == reference.id }?.title ?? reference.terminalID) : named
    }
    /// A session re-reported by a later reconnect replaces its earlier entry; the
    /// report describes the latest known outcome, not a history.
    private func mergeRestoreEntries(_ entries: [RestoredSession]) {
        guard !entries.isEmpty else { return }
        let ids = Set(entries.map(\.id))
        restoreReport.removeAll { ids.contains($0.id) }
        restoreReport.append(contentsOf: entries)
    }
    private func updateTaskEvents() {
        for item in allSessions where !item.archived {
            guard let kimi = kimiEnvironments[item.reference.hostID], let native = nativeEnvironments[item.reference.hostID] else { continue }
            let subject = archiveSubject(item)
            let completion: String?
            if item.reference.kind == .kimi {
                let session = kimi.sessions.first { $0.id == item.reference.terminalID }
                completion = session?.lastTurnReason == "completed" ? session?.updatedAt : nil
            } else if item.reference.kind == .terminal {
                let pane = connections.first { $0.id == item.reference.hostID }?.snapshot?.panes.first { $0.id == item.reference.terminalID }
                completion = pane?.status == "done" ? pane?.revision.map(String.init) : nil
            } else {
                let count = native.sessions.first { $0.id == item.reference.terminalID }?.completed ?? 0
                completion = count > 0 ? String(count) : nil
            }
            let state = TaskEventState(running: subject.busy, pending: subject.pendingInteraction, failed: subject.failed, completion: completion)
            guard let event = taskEvents.observe(state, id: item.id, online: item.online) else { continue }
            guard !mutedTasks.contains(item.id), !notifyAttentionOnly || event != .completed else { continue }
            if NSApp.isActive && !showDashboard && selectedReference?.id == item.id { continue }
            let notice = TaskNotice(sessionID: item.id, title: item.title, kind: event)
            taskNotice = notice
            if notificationsEnabled && !NSApp.isActive { notifications.post(id: item.id, title: item.title, event: event) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?.taskNotice?.id == notice.id { self?.taskNotice = nil }
            }
        }
    }
    func openNotifiedTask(_ id: String) {
        taskNotice = nil
        if let item = allSessions.first(where: { $0.id == id && $0.online && !$0.archived }) { open(item) }
        else if openedSessions.contains(where: { $0.session.id == id }) { select(id) }
        else {
            pendingNotificationID = id
            if let host = id.split(separator: ":").first.flatMap({ UUID(uuidString: String($0)) }) { activateAgentEnvironment(host) }
        }
    }
    private func snapshotUpdated() {
        var reviewed = workspace.reviewedRevisions
        var changed = false
        for connection in connections where connection.online {
            for pane in connection.snapshot?.panes ?? [] where pane.status != "done" {
                let id = SessionReference(hostID: connection.id, terminalID: pane.id).id
                if reviewed.removeValue(forKey: id) != nil { changed = true }
            }
        }
        if changed { workspace.reviewedRevisions = reviewed }
        catalogChanged()
        if changed { saveWorkspace() }
    }
    private func restoreAvailableSessions() {
        var attachedSelection = false
        for saved in openedSessions where saved.session.kind == .terminal {
            guard !terminals.contains(where: { $0.id == saved.session.id }),
                  let connection = connections.first(where: { $0.id == saved.session.hostID }), connection.online,
                  let pane = connection.snapshot?.panes.first(where: { $0.id == saved.session.terminalID }) else { continue }
            let terminal = AttachedTerminal(id: saved.session.id, pane: pane, connection: connection)
            terminal.onInput = { [weak self] in self?.pin(saved.session.id) }
            terminals.append(terminal)
            if terminal.id == selectedTerminalID { attachedSelection = true }
        }
        if showNative, let reference = selectedReference, let connection = nativeEnvironments[reference.hostID], connection.sessions.contains(where: { $0.id == reference.terminalID }) { connection.select(reference.terminalID) }
        if showKimi, let reference = selectedReference, let connection = kimiEnvironments[reference.hostID], connection.online, connection.sessions.contains(where: { $0.id == reference.terminalID }) { connection.select(reference.terminalID) }
        updateVisibility(focus: attachedSelection)
    }
    func flushDrafts() throws { for connection in kimiEnvironments.values { try connection.flushDrafts() }; for connection in nativeEnvironments.values { try connection.flushDrafts() } }
    func shutdown() {
        conversationPresentations.removeAll()
        try? flushDrafts()
        saveWorkspace()
        if canSaveWorkspace { do { try workspaceWriter.flush(workspace) } catch { workspaceError = error.localizedDescription } }
        kimiEnvironments.values.forEach { $0.disconnect() }; nativeEnvironments.values.forEach { $0.disconnect() }; terminals.removeAll(); connections.forEach { $0.disconnect() }
    }
    func inspectRendering() {
        guard let terminal = selectedTerminal, let view = terminal.context.attachedPlatformView,
              let grid = terminal.context.surfaceSize else { return }
        let backing = view.convertToBacking(view.bounds)
        let scale = view.window?.backingScaleFactor ?? 0
        let matches = abs(backing.width - Double(grid.widthPixels)) < 1 && abs(backing.height - Double(grid.heightPixels)) < 1
        renderReport = "Menlo 14 pt\n窗口 backingScaleFactor: \(scale)\n视图逻辑尺寸: \(view.bounds.width) × \(view.bounds.height) pt\n视图 backing 尺寸: \(backing.width) × \(backing.height) px\nGhostty surface: \(grid.widthPixels) × \(grid.heightPixels) px\n终端网格: \(grid.columns) × \(grid.rows)\n像素尺寸一致: \(matches ? "是" : "否")"
        renderReport += "\n\nGhostty 资源: \(GhosttyRuntimeResources.directoryURL?.path ?? "未找到")"
        if let layer = view.layer {
            renderReport += "\n\n图层: \(type(of: layer))\ncontentsScale: \(layer.contentsScale)\nshouldRasterize: \(layer.shouldRasterize)"
            for child in layer.sublayers ?? [] {
                renderReport += "\n子图层: \(type(of: child)), scale=\(child.contentsScale), frame=\(child.frame)"
            }
        }
        showRenderReport = true
    }

}

@MainActor
final class AttachedTerminal: ObservableObject, Identifiable {
    let id: String
    let incarnation = UUID()
    let hostID: UUID
    let hostName: String
    let pane: Pane
    let context: TerminalViewState
    @Published var ended = false
    var onInput: (() -> Void)?

    init(id: String, pane: Pane, connection: HostConnection) {
        self.id = id
        self.pane = pane
        hostID = connection.id
        hostName = connection.host.name
        let palette = TerminalConfiguration()
            .background("ffffff").foreground("272b36")
            .selectionBackground("dce5fa").selectionForeground("202535")
            .cursorColor("6062c9").cursorText("ffffff")
            .palette(0, color: "343943").palette(1, color: "bc4050")
            .palette(2, color: "26785d").palette(3, color: "967018")
            .palette(4, color: "3767bc").palette(5, color: "8155a1")
            .palette(6, color: "207d8a").palette(7, color: "b6bbc7")
            .palette(8, color: "747b8c").palette(9, color: "ca4f5e")
            .palette(10, color: "308767").palette(11, color: "a97e23")
            .palette(12, color: "4b78cf").palette(13, color: "9267b1")
            .palette(14, color: "2d8a96").palette(15, color: "e1e4ed")
        // Same hues as the light palette, lifted for the dark content surface.
        let darkPalette = TerminalConfiguration()
            .background("1e1e1e").foreground("d0d4de")
            .selectionBackground("35415c").selectionForeground("e8ebf2")
            .cursorColor("7a7ce0").cursorText("1e1e1e")
            .palette(0, color: "3f4550").palette(1, color: "d96372")
            .palette(2, color: "4cae8c").palette(3, color: "cfa04a")
            .palette(4, color: "6f97dd").palette(5, color: "a884c4")
            .palette(6, color: "4aa8b5").palette(7, color: "c9cdd8")
            .palette(8, color: "7d8493").palette(9, color: "e07a88")
            .palette(10, color: "5cbd9c").palette(11, color: "dcb05e")
            .palette(12, color: "82a5e4").palette(13, color: "b794d1")
            .palette(14, color: "5cb5c1").palette(15, color: "eef0f5")
        context = TerminalViewState(theme: TerminalTheme(light: palette, dark: darkPalette),
            terminalConfiguration: TerminalConfiguration().fontFamily("Menlo").fontSize(14)
                .windowPaddingX(14).windowPaddingY(12)
                .custom("clipboard-read", "deny").custom("clipboard-write", "allow")
                .custom("shell-integration", "none"))
        context.configuration = TerminalSurfaceOptions(
            command: SSHCommand.attach(host: connection.host, binary: connection.binary,
                                       terminalID: pane.terminalID, controlPath: connection.controlPath),
            waitAfterCommand: true)
        context.makePlatformView = { [weak self] in
            let view = WorkbenchTerminalView(frame: .zero)
            view.onInput = { [weak self] in self?.onInput?() }
            return view
        }
        context.onClose = { [weak self] _ in self?.ended = true }
    }
}

/// User-initiated clipboard actions belong to the native responder chain.
/// Reading remote OSC 52 requests remains denied by the terminal configuration.
private final class WorkbenchTerminalView: AppTerminalView {
    var onInput: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        onInput?()
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        onInput?()
        super.insertText(string, replacementRange: replacementRange)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":
                if let text = NSPasteboard.general.string(forType: .string) { onInput?(); _ = paste(text: text) }
                return true
            case "c": return copySelectedTextToPasteboard()
            case "k", "t", "n", "w", "r": return false
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
