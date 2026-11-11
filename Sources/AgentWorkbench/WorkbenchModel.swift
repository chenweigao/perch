import AppKit
import Combine
import Observation
import SwiftUI
import WorkbenchCore

@MainActor
@Observable
final class WorkbenchModel {
    let navigationState = WorkbenchNavigationState()
    let catalog = SessionCatalogState()
    let sidebarRepositories = SidebarRepositoryState()
    let conversationPresentations = ConversationPresentationCache()
    let commandLineIsland = CommandLineIslandState()
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
    var showDashboard: Bool {
        get { navigationState.showDashboard }
        set { navigationState.showDashboard = newValue }
    }
    var showAllTaskGroups: Bool {
        get { navigationState.showAllTaskGroups }
        set { navigationState.showAllTaskGroups = newValue }
    }
    var homeSection: WorkbenchHomeSection {
        get { navigationState.homeSection }
        set { navigationState.homeSection = newValue }
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
            if workspace.starred != oldValue.starred || workspace.sidebarProjectLocations != oldValue.sidebarProjectLocations { cachedSidebar = [:] }
        }
    }
    @ObservationIgnored private var cachedGroupIndex: SessionGroupIndex?
    @ObservationIgnored private var cachedGroupShortcuts: (catalogRevision: Int, selectedID: UUID?, summaries: [TaskGroupSummary])?
    /// One entry per filter: the list and the callers that ask for `.all` (revealing the
    /// selection, the move-to-project menu) no longer evict each other on every pass.
    @ObservationIgnored private var cachedSidebar: [SidebarRecentFilter: (catalogRevision: Int, repositoryRevision: Int, projection: SidebarProjection)] = [:]
    @ObservationIgnored private var cachedRepositoryRequests: (catalogRevision: Int, hosts: [SSHHost], requests: [SidebarRepositoryRequest])?
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
    var setupProvider: SessionKind?
    var launchAfterSetup: TaskLaunchDefaults?
    var pendingSetupLaunch = false
    /// Inline new-task draft covering the detail area; selection underneath is kept.
    var draftingNewTask = false
    var newTaskProject: SidebarProjectLocation?
    var showGroupEditor = false
    var editingGroup: WorkItemGroup?
    var editingGroupSessionsOnly = false
    let taskNotifications = WorkbenchNotificationState()
    var taskNotice: TaskNotice? { get { taskNotifications.taskNotice } set { taskNotifications.taskNotice = newValue } }
    var notificationError: String? { get { taskNotifications.notificationError } set { taskNotifications.notificationError = newValue } }
    var notificationsEnabled: Bool { get { taskNotifications.notificationsEnabled } set { taskNotifications.notificationsEnabled = newValue } }
    var showsDockBadge: Bool { get { taskNotifications.showsDockBadge } set { taskNotifications.showsDockBadge = newValue } }
    var mutedTasks: Set<String> { taskNotifications.mutedTasks }
    func toggleTaskNotifications(_ id: String) { taskNotifications.toggleTaskNotifications(id) }
    @ObservationIgnored private var pendingNotificationID: String?
    var showConversationFind = false
    var workspaceSearchQuery = ""
    var workspaceSearchEntryID: String?
    var showSessionSearch = false
    var projectOverview: SidebarProjectLocation?
    var pendingFileOutcome: GroupOutcome?
    var showFollowUps = false
    var companionShortcutError: String?
    @ObservationIgnored var followUpLoop: Task<Void, Never>?
    var followUpNotices: [String] = []
    private(set) var navigation: SessionNavigation {
        get { navigationState.navigation }
        set { navigationState.navigation = newValue }
    }
    @ObservationIgnored private var navigatingHistory = false
    var showFileViewer = false
    let fileBrowser = RemoteFileBrowser()
    /// The inspector's changes page reads independently of the file window.
    let changesBrowser = RemoteFileBrowser(workingTreeOnly: true)
    /// File navigation in the inspector must not replace a detached reader's tabs.
    let inspectorFiles = RemoteFileBrowser()
    /// Artifact availability learned only from reads the user already triggered;
    /// the task panel never stats files eagerly. A missing artifact keeps its
    /// name in the record but no longer offers a dead-end open.
    private(set) var missingWorkspaceFiles: Set<String> = []
    func isWorkspaceFileMissing(hostID: UUID, path: String) -> Bool {
        missingWorkspaceFiles.contains("\(hostID.uuidString):\(path)")
    }
    func wireFileAvailability() {
        for browser in [fileBrowser, changesBrowser, inspectorFiles] {
            browser.onFileAvailability = { [weak self] path, available in
                guard let self, let hostID = browser.host?.id else { return }
                let key = "\(hostID.uuidString):\(path)"
                // Skip no-op mutations so settled reads do not invalidate the panel.
                if available {
                    if missingWorkspaceFiles.contains(key) { missingWorkspaceFiles.remove(key) }
                } else if !missingWorkspaceFiles.contains(key) {
                    missingWorkspaceFiles.insert(key)
                }
            }
        }
    }
    @ObservationIgnored let fileWindow = FileWindowController()
    let taskContextWindow = TaskContextWindowController()
    private static let workspaceFileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.agentworkbench.mac")
        .appendingPathComponent("workspace.json")
    private let workspaceURL = WorkbenchModel.workspaceFileURL
    @ObservationIgnored private lazy var workspaceWriter = WorkspaceWriter(url: workspaceURL)
    @ObservationIgnored private var canSaveWorkspace = true
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    let naming = WorkbenchNamingState()
    var namingInProgress: Set<String> { naming.namingInProgress }
    var namingErrors: [String: String] { naming.namingErrors }
    var sessionNamer: (ActivitySummaryConfiguration, String, String) async throws -> String {
        get { naming.sessionNamer }
        set { naming.sessionNamer = newValue }
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
            workspaceError = L("本地工作台读取失败，原文件已保留：\(error.localizedDescription)")
        }
        if let reference = selectedReference { navigation.visit(reference.id) }
        taskNotifications.start(onOpen: { [weak self] id in self?.openNotifiedTask(id) },
                                onOpenDashboard: { [weak self] in self?.showHome() })
        wireFileAvailability()
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
                self.fileBrowser.open(reference.path, line: reference.line, fromConversation: true, source: self.selectedReference)
                self.fileWindow.show(model: self)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .conversationAction, object: nil, queue: .main) { [weak self] notice in
            guard let payload = notice.object as? ConversationActionPayload else { return }
            MainActor.assumeIsolated { self?.handleConversationAction(payload) }
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
        // The project fixture needs a selectable creation target, but never calls
        // connect, observes it, or restores any saved hosts.
        connections = ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_SIDEBAR_VARIANT"] == "projects"
            ? [HostConnection(host: host)] : []
        configuredEnvironment = true
        selectedHostID = host.id
        canSaveWorkspace = false
        allSessions = sessions
        sidebarRepositories.acceptanceReplace(host: host,
            roots: Dictionary(sessions.map { ($0.directory, $0.directory) }, uniquingKeysWith: { first, _ in first }))
        kimiEnvironments[host.id] = self.kimi; nativeEnvironments[host.id] = native
        workspace.starred = Array(sessions.prefix(4).map(\.reference))
        workspace.groups = [WorkItemGroup(name: "性能验收", goal: "固定离线数据", nextStep: "", // l10n-ignore
                                          sessions: Array(sessions.prefix(12).map(\.reference)))]
        wireFileAvailability()
    }
    func acceptanceUpdateCatalog(_ sessions: [WorkspaceSession]) { allSessions = sessions }
    #endif

    func registerEnvironment(kimi: KimiConnection, native: NativeAgentConnection) {
        kimiEnvironments[kimi.host.id] = kimi; nativeEnvironments[native.host.id] = native
        let sharedMaster = connections.first { $0.id == kimi.host.id }
        kimi.hostConnection = sharedMaster
        native.hostConnection = sharedMaster
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
                                    remoteTitle: session.title, messages: conversation.messages, hasOlder: conversation.hasOlder)
                if let revision = conversation.taskRecapRevision {
                    let key = "\(kimi.host.id):kimi:\(session.id):\(revision)"
                    let sessionID = session.id
                    let provider: @MainActor () async throws -> [KimiMessage] = { [weak kimi] in
                        guard let kimi else { throw CancellationError() }
                        return try await kimi.recapMessages(for: sessionID)
                    }
                    TaskRecapStore.shared.registerMessages(for: key, provider: provider)
                }
            }
        }
        kimi.onConversationChanged?(kimi.conversation)
        native.onSnapshotChanged = { [weak self, weak native] snapshot in
            Task { @MainActor in
                guard let self, let native, let snapshot else { return }
                self.considerNaming(reference: SessionReference(hostID: native.host.id, terminalID: snapshot.id, kind: snapshot.provider),
                                    remoteTitle: snapshot.title, messages: snapshot.messages, hasOlder: snapshot.hasOlder)
                if let revision = snapshot.taskRecapRevision {
                    let key = "\(native.host.id):native:\(snapshot.id):\(revision)"
                    let sessionID = snapshot.id
                    let provider: @MainActor () async throws -> [KimiMessage] = { [weak native] in
                        guard let native, native.selectedID == sessionID, native.snapshot?.id == sessionID else {
                            throw CancellationError()
                        }
                        return try await native.recapMessages(for: sessionID)
                    }
                    TaskRecapStore.shared.registerMessages(for: key, provider: provider)
                }
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
    func usesLegacyKimiConnection(_ reference: SessionReference) -> Bool {
        guard reference.kind == .kimi,
              let kimi = kimiEnvironments[reference.hostID],
              !(nativeEnvironments[reference.hostID]?.sessions.contains { $0.id == reference.terminalID } ?? false) else {
            return false
        }
        return kimi.online
            || kimi.sessions.contains { $0.id == reference.terminalID }
            || kimi.conversation?.snapshot.session.id == reference.terminalID
    }
    func isNativeSession(_ reference: SessionReference) -> Bool {
        reference.kind != .terminal && !usesLegacyKimiConnection(reference)
    }
    func connectSSH(_ hostID: UUID) {
        guard let agents = agentConnections(for: hostID) else { return }
        if agents.native.host.hasNativeAgents, !agents.native.wantsConnection { agents.native.connect() }
    }
    func disconnectSSH(_ hostID: UUID) {
        kimiEnvironments[hostID]?.disconnect()
        nativeEnvironments[hostID]?.disconnect()
    }
    func setAutoConnect(_ enabled: Bool, for hostID: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == hostID }) else { return }
        let connection = connections[index]
        var host = connection.host
        host.autoConnectSSH = enabled
        var saved = connections.map(\.host)
        saved[index] = host
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: "hosts")
            connection.updateHost(host)
            kimiEnvironments[hostID]?.updateHost(host)
            nativeEnvironments[hostID]?.updateHost(host)
            if enabled {
                if started { connectSSH(hostID) }
            }
            else { disconnectSSH(hostID) }
        } catch { workspaceError = error.localizedDescription }
    }
    func startNewTask(in project: SidebarProjectLocation? = nil) {
        newTaskProject = project
        if let project { clearScope(); activateAgentEnvironment(project.hostID) }
        if connections.isEmpty { configureHost() } else { draftingNewTask = true }
    }

    func moveSidebarSession(_ item: WorkspaceSession, to project: SidebarProjectLocation?) {
        workspace.sidebarProjectLocations[item.id] = project
        saveWorkspace()
    }
    func configureHost(_ host: SSHHost? = nil, provider: SessionKind? = nil) {
        if host?.isLocal == true { showLocalSetup = true; return }
        setupHost = host; setupProvider = provider; showAddHost = true
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
            kimiEnvironments[host.id]?.disconnect()
            if !host.hasNativeAgents { nativeEnvironments[host.id]?.disconnect() }
        } else {
            let connection = HostConnection(host: host); connections.append(connection)
            registerEnvironment(kimi: KimiConnection(host: host), native: NativeAgentConnection(host: host))
        }
        UserDefaults.standard.set(data, forKey: "hosts")
        configuredEnvironment = true
        activateAgentEnvironment(host.id)
        showHome(groupID: selectedGroupID)
        if started {
            if host.autoConnectSSH { connectSSH(host.id) }
        }
        if let launch {
            let key = "new.task.defaults." + (selectedGroupID?.uuidString ?? "global")
            UserDefaults.standard.set(try JSONEncoder().encode(launch), forKey: key)
        }
        launchAfterSetup = startTask ? launch : nil
        pendingSetupLaunch = startTask
    }
    func setupDismissed() {
        setupHost = nil; setupProvider = nil
        guard pendingSetupLaunch else { return }
        pendingSetupLaunch = false
        draftingNewTask = true
    }
    func reconnectSelectedEnvironment() {
        if showKimi { kimi.connect() }
        else if showNative { native.connect() }
        else { selectedConnection?.connect() }
    }
    var selectedReference: SessionReference? { openedSessions.first { $0.session.id == tabs.selectedID }?.session }
    var showNative: Bool { !showDashboard && (selectedReference.map(isNativeSession) ?? false) }
    var showKimi: Bool { !showDashboard && (selectedReference.map(usesLegacyKimiConnection) ?? false) }
    var previewTerminalID: String? { tabs.previewID }
    var selectedConnection: HostConnection? { connections.first { $0.id == selectedHostID } }
    /// The quick shell follows the selected session's host and directory. The
    /// dashboard and the new-task draft have no resolvable target.
    var commandLineTarget: CommandLineIslandState.Target? {
        guard !showDashboard, !draftingNewTask, let item = selectedItem,
              connections.contains(where: { $0.id == item.reference.hostID }) else { return nil }
        return CommandLineIslandState.Target(hostID: item.reference.hostID, hostName: item.hostName,
                                             directory: item.directory)
    }
    func toggleCommandLineIsland() {
        guard let target = commandLineTarget,
              let connection = connections.first(where: { $0.id == target.hostID })
        else { commandLineIsland.hide(); return }
        commandLineIsland.toggle(target: target, connection: connection)
    }
    func retargetCommandLineIsland() {
        guard let target = commandLineTarget,
              let connection = connections.first(where: { $0.id == target.hostID }) else { return }
        commandLineIsland.retarget(target: target, connection: connection)
    }
    func restartCommandLineIsland() {
        guard let target = commandLineIsland.target,
              let connection = connections.first(where: { $0.id == target.hostID }) else { return }
        commandLineIsland.restart(connection: connection)
    }
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
    /// The sidebar reads this on every pass to key its repository task. It scans the whole
    /// catalog per machine, so it is recomputed only when the catalog or the machines change.
    var sidebarRepositoryRequests: [SidebarRepositoryRequest] {
        let revision = catalog.revision
        let hosts = connections.map(\.host)
        if let cached = cachedRepositoryRequests, cached.catalogRevision == revision, cached.hosts == hosts {
            return cached.requests
        }
        let requests = computeSidebarRepositoryRequests()
        cachedRepositoryRequests = (revision, hosts, requests)
        return requests
    }
    private func computeSidebarRepositoryRequests() -> [SidebarRepositoryRequest] {
        connections.compactMap { connection in
            let directories = Set(allSessions.filter {
                !$0.archived && $0.reference.hostID == connection.id && ($0.online || connection.host.isLocal)
            }.map(\.directory).filter { $0.hasPrefix("/") && !$0.contains("\0") }).sorted()
            let sessions = allSessions.filter {
                !$0.archived && $0.online && $0.reference.hostID == connection.id && $0.reference.kind != .terminal
            }.map { SidebarRepositorySession(reference: $0.reference, directory: $0.directory,
                                             revision: $0.section == .running ? 0 : $0.updatedAt) }
                .sorted { $0.reference.id < $1.reference.id }
            return directories.isEmpty ? nil : SidebarRepositoryRequest(host: connection.host, directories: directories, sessions: sessions)
        }
    }
    func sidebarProjectMessages(_ reference: SessionReference) async throws -> [KimiMessage] {
        if usesLegacyKimiConnection(reference), let connection = kimiEnvironments[reference.hostID] {
            return try await connection.projectMessages(for: reference.terminalID)
        }
        if let connection = nativeEnvironments[reference.hostID] {
            return try await connection.projectMessages(for: reference.terminalID)
        }
        throw WorkbenchError("Project history unavailable")
    }
    var sidebarProjectLocations: [String: SidebarProjectLocation] {
        let _ = sidebarRepositories.revision
        var locations = workspace.sidebarProjectLocations
        #if PERCH_ACCEPTANCE
        if ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_SIDEBAR_VARIANT"] != "projects" { return locations }
        #endif
        let hosts = Dictionary(connections.map { ($0.id, $0.host) }, uniquingKeysWith: { first, _ in first })
        for item in allSessions where locations[item.id] == nil {
            locations[item.id] = sidebarRepositories.location(for: item, host: hosts[item.reference.hostID])
        }
        return locations
    }
    func sidebarProjection(filter: SidebarRecentFilter) -> SidebarProjection {
        let revision = catalog.revision
        let repositoryRevision = sidebarRepositories.revision
        let starred = workspace.starred
        let _ = workspace.sidebarProjectLocations
        if let cached = cachedSidebar[filter], cached.catalogRevision == revision,
           cached.repositoryRevision == repositoryRevision { return cached.projection }
        let locations = sidebarProjectLocations
        let projection = SidebarProjection(sessions: allSessions, starred: starred, filter: filter, projectLocations: locations)
        cachedSidebar[filter] = (revision, repositoryRevision, projection)
        return projection
    }
    func setScope(groupID: UUID?) {
        // Changing the scope narrows the current page; it does not leave it.
        let inbox = onlyAttention, allGroups = showAllTaskGroups
        showHome(groupID: groupID)
        onlyAttention = inbox; showAllTaskGroups = allGroups
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
        let conversations = kimiEnvironments.values.flatMap { kimi in kimi.sessions.map { session in
            let reference = SessionReference(hostID: kimi.host.id, terminalID: session.id, kind: .kimi)
            let turn = SessionTurn(kimi: session)
            let section = turn.section(reviewed: workspace.reviewedKimiUpdates[reference.id])
            return WorkspaceSession(reference: reference,
                title: workspace.displayTitle(session.displayTitle, for: reference), directory: session.cwd, hostName: kimi.host.name,
                detail: section == .review ? L("Kimi · 结果待查看") : "Kimi · \(session.status)", online: kimi.online,
                section: section, canMarkReviewed: section == .review, archived: archiveOverrides[reference.id] ?? (session.archived == true), updatedAt: sessionDateParser.date(from: session.updatedAt)?.timeIntervalSince1970 ?? 0,
                turn: turn)
        }
        }
        let agents = nativeEnvironments.values.flatMap { native in native.sessions.map { session in
            let reference = SessionReference(hostID: native.host.id, terminalID: session.id, kind: session.provider)
            let turn = SessionTurn(native: session)
            let section = turn.section(reviewed: workspace.reviewedKimiUpdates[reference.id])
            return WorkspaceSession(reference: reference, title: workspace.displayTitle(session.title, for: reference), directory: session.cwd, hostName: native.host.name,
                detail: "\(session.provider.label) · \(section == .review ? L("结果待查看") : session.status)", online: native.online, section: section,
                canMarkReviewed: section == .review, archived: archiveOverrides[reference.id] ?? session.archived, updatedAt: session.updated,
                turn: turn)
        }
        }
        let next = (conversations + agents).sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        allSessions = next
        taskNotifications.updateDockBadge(next)
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

    func removeHost(_ host: SSHHost) {
        guard let index = connections.firstIndex(where: { $0.id == host.id }) else { return }
        conversationPresentations.remove(prefix: host.id.uuidString + ":")
        connections[index].disconnect()
        kimiEnvironments[host.id]?.disconnect(); nativeEnvironments[host.id]?.disconnect()
        kimiEnvironments.removeValue(forKey: host.id); nativeEnvironments.removeValue(forKey: host.id)
        connections.remove(at: index)
        for saved in openedSessions where saved.session.hostID == host.id { close(saved.session.id) }
        let fallback = connections.first?.host.id ?? SSHHost.unconfigured.id
        if selectedHostID == host.id { selectedHostID = fallback }
        if kimi.host.id == host.id || native.host.id == host.id { activateAgentEnvironment(selectedHostID) }
        if connections.isEmpty {
            kimi = KimiConnection(host: .unconfigured); native = NativeAgentConnection(host: .unconfigured)
            showDashboard = true; tabs.showOverview()
        }
        configuredEnvironment = !connections.isEmpty
        if scopeHostID == host.id { scopeHostID = nil }
        do { UserDefaults.standard.set(try JSONEncoder().encode(connections.map(\.host)), forKey: "hosts") }
        catch { managementError = L("机器已移除，但保存机器列表失败：\(error.localizedDescription)") }
        if fileBrowser.host?.id == host.id {
            fileBrowser.source = nil
            fileBrowser.configure(host: nil, cwd: "")
        }
        if changesBrowser.host?.id == host.id {
            changesBrowser.source = nil
            changesBrowser.configure(host: nil, cwd: "")
        }
        if inspectorFiles.host?.id == host.id {
            inspectorFiles.source = nil
            inspectorFiles.configure(host: nil, cwd: "")
        }
        rebuildCatalog(); saveWorkspace()
    }
    func open(_ item: WorkspaceSession, pinned: Bool = false) {
        guard item.online, !item.archived else { return }
        openReference(item.reference, title: item.title, pinned: pinned)
    }
    private func openReference(_ reference: SessionReference, title: String, pinned: Bool) {
        tabs.open(reference.id, pinned: true)
        openedSessions.removeAll { !tabs.ids.contains($0.session.id) }
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
        let probe = PerfDiagnostics.begin()
        defer { PerfDiagnostics.end("session_select", probe, detail: selectedReference.map { "kind=\($0.kind.rawValue)" }) }
        if !navigatingHistory { navigation.visit(identity) }
        tabs.select(identity); showDashboard = false; draftingNewTask = false
        if let reference = selectedReference {
            activateAgentEnvironment(reference.hostID)
            selectedHostID = reference.hostID
            if let group = selectedGroup, !group.sessions.contains(reference) { selectedGroupID = nil }
            if let group = selectedGroup { workspace.lastSessionByGroup[group.id.uuidString] = reference.id }
            if isNativeSession(reference) { native.select(reference.terminalID) }
            else if usesLegacyKimiConnection(reference), kimi.online { kimi.select(reference.terminalID) }
        }
        saveWorkspace()
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
    func close(_ identity: String) {
        tabs.close(identity); openedSessions.removeAll { $0.session.id == identity }
        if let selected = tabs.selectedID, !showDashboard { select(selected) }
        else { showDashboard = true; saveWorkspace() }
    }
    func start() {
        guard !started else { return }
        if let reference = selectedReference { activateAgentEnvironment(reference.hostID) }
        started = true
        startFollowUpLoop()
        for connection in connections {
            if connection.host.autoConnectSSH { connectSSH(connection.id) }
        }
    }
    func showHome(groupID: UUID? = nil) {
        onlyAttention = false; search = ""; showSessionDirectory = false
        showArchived = false; draftingNewTask = false
        // Leaving for the workbench, inbox or session list closes the full group
        // list; opening a group from that list keeps it for the way back.
        if groupID == nil { showAllTaskGroups = false; navigationState.homeSection = .overview }
        selectedGroupID = groupID
        if let index = workspace.groups.firstIndex(where: { $0.id == groupID }) {
            workspace.groups[index].lastOpenedAt = Date().timeIntervalSince1970
        }
        showDashboard = true
        tabs.showOverview(); saveWorkspace()
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
            if usesLegacyKimiConnection(item.reference) { agents.kimi.select(item.reference.terminalID) }
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
        if usesLegacyKimiConnection(ref) { agents.kimi.select(ref.terminalID) }
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
        if usesLegacyKimiConnection(ref), let c = kimiEnvironments[ref.hostID], let session = c.sessions.first(where: { $0.id == ref.terminalID }) {
            revision = item.section == .review ? session.updatedAt : session.pendingInteraction ?? session.lastTurnReason ?? ""
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
        if isNativeSession(item.reference), let session = native.sessions.first(where: { $0.id == item.reference.terminalID }) {
            workspace.reviewedKimiUpdates[item.id] = String(session.completed)
        } else if usesLegacyKimiConnection(item.reference), let session = kimi.sessions.first(where: { $0.id == item.reference.terminalID }) {
            workspace.markReviewed(session, on: kimi.host.id)
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
        tabs.showOverview(); saveWorkspace()
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
        if isNativeSession(item.reference) {
            guard let session = native.sessions.first(where: { $0.id == item.reference.terminalID }) else {
                return ArchiveSubject(reference: item.reference, fingerprint: "missing", online: false)
            }
            let turn = SessionTurn(native: session)
            return ArchiveSubject(reference: item.reference,
                                  fingerprint: "\(session.completed):\(session.updated)",
                                  archived: session.archived, online: native.online, busy: turn.running,
                                  pendingInteraction: turn.pending, failed: turn.failed,
                                  stopped: session.cancelled == true, starred: starred,
                                  completedTurns: session.completed, reviewed: item.section != .review,
                                  queuedMessages: queued, hasCompletionSignal: true)
        }
        if usesLegacyKimiConnection(item.reference) {
            guard let session = kimi.sessions.first(where: { $0.id == item.reference.terminalID }) else {
                return ArchiveSubject(reference: item.reference, fingerprint: "missing", online: false)
            }
            let turn = SessionTurn(kimi: session)
            return ArchiveSubject(reference: item.reference, fingerprint: session.updatedAt,
                                  archived: session.archived == true, online: kimi.online, busy: turn.running,
                                  pendingInteraction: turn.pending,
                                  failed: turn.failed, stopped: false, starred: starred,
                                  completedTurns: session.lastTurnReason == "completed" ? 1 : 0,
                                  reviewed: item.section != .review, queuedMessages: queued,
                                  hasCompletionSignal: session.lastTurnReason != nil)
        }
        // Anything that is neither Kimi nor a native agent no longer exists;
        // the neutral fallback marks it non-busy without a completion signal.
        return ArchiveSubject(reference: item.reference,
                              fingerprint: "unknown",
                              archived: item.archived, online: item.online, busy: false,
                              pendingInteraction: false, failed: false, stopped: false,
                              starred: starred, completedTurns: 0,
                              reviewed: item.section != .review, queuedMessages: 0,
                              hasCompletionSignal: false)
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
        guard let kimi = kimiEnvironments[reference.hostID], let native = nativeEnvironments[reference.hostID] else { throw WorkbenchError(L("当前会话没有可用的执行环境。")) }
        if usesLegacyKimiConnection(reference) { try await kimi.setArchived(reference.terminalID, archived: archived, refresh: false) }
        else if isNativeSession(reference) {
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
        return usesLegacyKimiConnection(reference) ? kimi.online : isNativeSession(reference) && native.online
    }
    /// Stage a compact citation; the original Markdown quote is restored on send.
    /// Existing draft text is kept: quoting is an addition, not a replacement.
    func quoteSelection(_ text: String) {
        guard canQuoteSelection, let reference = selectedReference else { return }
        appendQuoteToDraft(text, kimi: kimi, native: native, isKimi: usesLegacyKimiConnection(reference), id: reference.terminalID)
        DispatchQueue.main.async { NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil) }
    }
    /// Message-level transcript actions (quote / edit-and-resend / resend /
    /// regenerate) route to the connection owning the payload's session.
    func handleConversationAction(_ payload: ConversationActionPayload) {
        let context = payload.context
        let kimi = kimiEnvironments[context.hostID]
        let native = nativeEnvironments[context.hostID]
        let id = context.sessionID
        let reference = SessionReference(hostID: context.hostID, terminalID: id, kind: context.kind)
        let isKimi = usesLegacyKimiConnection(reference)
        switch payload.action {
        case .quote(let text):
            appendQuoteToDraft(text, kimi: kimi, native: native, isKimi: isKimi, id: id)
        case .editAndResend(let text):
            appendToDraft(kimi: kimi, native: native, isKimi: isKimi, id: id, text: text)
        case .resend(let text):
            if isKimi { kimi?.resend(text, for: id) } else { native?.resend(text, for: id) }
        case .regenerate(let messageID):
            let failure = isKimi ? kimi?.resendPrompt(before: messageID, for: id)
                                 : native?.resendPrompt(before: messageID, for: id)
            if let failure {
                if isKimi { kimi?.actionError = failure } else { native?.actionError = failure }
            }
        case .openSubagent(let toolCallId):
            // A sheet over the conversation; the composer is not the target.
            if !isKimi { native?.openSubagent(toolCallId, in: id) }
            return
        case .showTurnDetails:
            showTurn(.task, of: reference)
            return
        case .showEdit(let tool, let messageID):
            guard selectedReference == reference else { return }
            let messages: [KimiMessage]
            if isKimi, let conversation = kimi?.conversation, conversation.snapshot.session.id == id {
                messages = conversation.displayMessages
            } else if let snapshot = native?.snapshot, snapshot.id == id {
                messages = snapshot.messages
            } else { messages = [] }
            taskContextWindow.editRecord = (reference, ConversationEditRecord(step: tool, messages: messages, messageID: messageID))
            showTurn(.edits, of: reference)
            return
        case .showChanges:
            showTurn(.changes, of: reference)
            return
        case .turnStalled:
            if let item = allSessions.first(where: { $0.reference == reference }) {
                taskNotifications.deliverStall(id: item.id, title: item.title,
                                               visibleSessionID: showDashboard ? nil : selectedReference?.id)
            }
            return
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil) }
    }
    /// The status line asks for its own session: a panel locked to another one
    /// follows again, and the task page shows its list, where 本轮 leads.
    private func showTurn(_ page: WorkspaceInspectorPage, of reference: SessionReference) {
        if let locked = taskContextWindow.locked, locked != reference { taskContextWindow.locked = nil }
        if page == .task, taskContextWindow.detail?.source == reference { taskContextWindow.detail = nil }
        if page == .task, taskContextWindow.fileDetail?.source == reference { taskContextWindow.fileDetail = nil }
        taskContextWindow.showPage(page, model: self)
    }
    private func appendQuoteToDraft(_ text: String, kimi: KimiConnection?, native: NativeAgentConnection?, isKimi: Bool, id: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let store = isKimi ? kimi?.pastes : native?.pastes else { return }
        do {
            let token = DraftPaste.token(id: try store.save(DraftPaste.quote(text)), kind: .cite)
            appendToDraft(kimi: kimi, native: native, isKimi: isKimi, id: id, text: token + "\n\n")
        } catch {
            let message = L("无法保存引用：\(error.localizedDescription)")
            if isKimi { kimi?.actionError = message } else { native?.actionError = message }
        }
    }
    private func appendToDraft(kimi: KimiConnection?, native: NativeAgentConnection?, isKimi: Bool, id: String, text: String) {
        if isKimi, let kimi {
            let existing = kimi.drafts[id] ?? ""
            kimi.drafts[id] = existing.isEmpty ? text : existing + "\n\n" + text
        } else if !isKimi, let native {
            let existing = native.drafts[id] ?? ""
            native.drafts[id] = existing.isEmpty ? text : existing + "\n\n" + text
        }
    }
    /// Exports the currently shown conversation's loaded messages as a local
    /// document. The save panel decides the destination; failures surface in
    /// the active connection's action line.
    func exportSelectedConversation(markdown: Bool) {
        guard let reference = selectedReference else { return }
        let isKimi = usesLegacyKimiConnection(reference)
        let kimi = kimiEnvironments[reference.hostID]
        let native = nativeEnvironments[reference.hostID]
        let messages = isKimi ? kimi?.conversation?.displayMessages : native?.snapshot?.messages
        guard let messages, !messages.isEmpty else { return }
        do {
            let data: Data
            let ext: String
            if markdown {
                data = Data(ConversationExport.markdown(messages).utf8); ext = "md"
            } else {
                data = try ConversationExport.json(messages); ext = "json"
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "conversation-\(reference.terminalID).\(ext)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            if isKimi { kimi?.actionError = error.localizedDescription }
            else { native?.actionError = error.localizedDescription }
        }
    }
    /// Review feedback is staged in the same task; it never sends automatically.
    func appendReviewContext(_ text: String, to reference: SessionReference) {
        guard selectedReference == reference, canQuoteSelection else { return }
        let id = reference.terminalID
        if usesLegacyKimiConnection(reference) {
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
            let connection = HostConnection(host: host); connections.append(connection)
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
        if reference.kind == .terminal { messages = nil }
        else if usesLegacyKimiConnection(reference) { messages = kimiEnvironments[reference.hostID]?.loadedMessages(for: reference.terminalID) }
        else { messages = nativeEnvironments[reference.hostID]?.loadedMessages(for: reference.terminalID) }
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
        return L("首条消息接收后即可为占位标题自动命名，无需等待本轮完成；已有标题保持不变。")
    }
    private func reconsiderNaming() {
        for kimi in kimiEnvironments.values {
            guard let conversation = kimi.conversation else { continue }
            let session = conversation.snapshot.session
            considerNaming(reference: SessionReference(hostID: kimi.host.id, terminalID: session.id, kind: .kimi),
                           remoteTitle: session.title, messages: conversation.messages, hasOlder: conversation.hasOlder)
        }
        for native in nativeEnvironments.values {
            guard let snapshot = native.snapshot else { continue }
            considerNaming(reference: SessionReference(hostID: native.host.id, terminalID: snapshot.id, kind: snapshot.provider),
                           remoteTitle: snapshot.title, messages: snapshot.messages, hasOlder: snapshot.hasOlder)
        }
    }
    private func considerNaming(reference: SessionReference, remoteTitle: String, messages: [KimiMessage], hasOlder: Bool) {
        naming.consider(reference: reference, remoteTitle: remoteTitle, messages: messages, hasOlder: hasOlder,
                        mayName: { self.workspace.sessionTitles[reference.id] == nil && !self.workspace.autoNamedSessions.contains(reference.id) },
                        remoteTitleNow: { self.namingRemoteTitle(for: reference) },
                        loadHistory: { self.loadHistoryForNaming(reference, remoteTitle: remoteTitle) },
                        apply: { self.applyGeneratedName($0, for: reference) })
    }
    /// Naming needs the first user message, which a partially loaded history
    /// does not contain. Pull the remaining pages in the background instead of
    /// waiting for the user to scroll to the top; each page re-enters
    /// `considerNaming` through the conversation publishers. Only titles that
    /// could still be placeholders fetch, so named sessions never pay for it.
    private func loadHistoryForNaming(_ reference: SessionReference, remoteTitle: String) {
        guard SessionNaming.couldBePlaceholder(remoteTitle, kind: reference.kind) else { return }
        if usesLegacyKimiConnection(reference) { kimiEnvironments[reference.hostID]?.loadAllHistoryForSearch() }
        else { nativeEnvironments[reference.hostID]?.loadAllHistoryForSearch() }
    }
    private func namingRemoteTitle(for reference: SessionReference) -> String? {
        if usesLegacyKimiConnection(reference) {
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
        if isNativeSession(item.reference) { return native.online && native.sessions.first(where: { $0.id == item.reference.terminalID })?.busy == false }
        return kimi.online && kimi.sessions.first(where: { $0.id == item.reference.terminalID })?.busy == false
    }
    func setArchived(_ item: WorkspaceSession, archived: Bool) {
        guard let kimi = kimiEnvironments[item.reference.hostID], let native = nativeEnvironments[item.reference.hostID] else { return }
        guard canArchive(item), !managing.contains(item.id) else { return }
        managementError = nil
        managing.insert(item.id)
        // Optimistic: the row moves with the click; a failure animates it back.
        archiveOverrides[item.id] = archived
        animateCatalogChange { rebuildCatalog() }
        if archived, tabs.ids.contains(item.id) { close(item.id) }
        Task {
            defer { managing.remove(item.id) }
            do {
                if usesLegacyKimiConnection(item.reference) { try await kimi.setArchived(item.reference.terminalID, archived: archived) }
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
        let isKimi = usesLegacyKimiConnection(item.reference)
        managing.insert(item.id); managementError = nil
        Task {
            defer { managing.remove(item.id) }
            do {
                if isKimi { try await kimi.deleteSession(item.reference.terminalID) }
                else if item.reference.kind != .terminal { try await native.action(item.reference.terminalID, "delete") }
                if tabs.ids.contains(item.id) { close(item.id) }
                workspace.removeSession(item.reference)
                let kind = isKimi ? "kimi" : "native"
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
        taskContextWindow.togglePage(.files, model: self)
    }
    func syncInspectorFiles() {
        let directory = selectedItem?.directory ?? ""
        let changed = inspectorFiles.source != selectedReference ||
            inspectorFiles.host?.id != selectedHost?.id || inspectorFiles.cwd != directory
        inspectorFiles.source = selectedReference
        inspectorFiles.configure(host: selectedHost, cwd: directory,
                                 directoryHints: selectedDirectoryHints(directory))
        if selectedHost != nil, changed || inspectorFiles.path.isEmpty {
            inspectorFiles.open(directory.isEmpty ? "." : directory)
        } else if selectedHost != nil, inspectorFiles.error != nil || inspectorFiles.content == nil {
            inspectorFiles.open(inspectorFiles.path)
        }
    }
    /// Expanding is an explicit handoff to the full reader; the inspector keeps
    /// its own location and can remain open beside the conversation.
    func expandInspectorFile() {
        guard let host = inspectorFiles.host, !inspectorFiles.path.isEmpty else { return }
        pendingFileOutcome = nil
        fileBrowser.source = inspectorFiles.source
        fileBrowser.configure(host: host, cwd: inspectorFiles.cwd)
        fileBrowser.open(inspectorFiles.path, line: inspectorFiles.targetLine, source: inspectorFiles.source)
        showFileViewer = true
        fileWindow.show(model: self)
    }
    /// The inspector's changes page hands the full review to the file window's
    /// Git page; a window being created reads status itself.
    func reviewChangesInFileWindow() {
        showFileViewer = true
        syncFileViewer()
        fileBrowser.mode = .git
        if fileWindow.window != nil, fileBrowser.gitStatus == nil, !fileBrowser.loading { fileBrowser.loadGitStatus() }
        fileWindow.show(model: self)
    }
    private func syncFileViewer() {
        guard showFileViewer else { return }
        let directory = selectedItem?.directory ?? ""
        pendingFileOutcome = nil
        fileBrowser.source = selectedReference
        fileBrowser.configure(host: selectedHost, cwd: directory, directoryHints: selectedDirectoryHints(directory))
    }
    /// Points the inspector's changes page at the selected session's host and
    /// working directory, preferring the worktrees its agent recently touched.
    func syncChangesBrowser() {
        let directory = selectedItem?.directory ?? ""
        changesBrowser.source = selectedReference
        changesBrowser.configure(host: selectedHost, cwd: directory, directoryHints: selectedDirectoryHints(directory))
    }
    func selectedDirectoryHints(_ directory: String, reference: SessionReference? = nil) -> [String] {
        var messages: [KimiMessage] = []
        var liveTools: [KimiLiveTool] = []
        let target = reference ?? selectedReference
        if let target, usesLegacyKimiConnection(target),
           let conversation = kimiEnvironments[target.hostID]?.conversation,
           conversation.snapshot.session.id == target.terminalID {
            messages = conversation.messages
            liveTools = conversation.live?.runningTools ?? []
        } else if let target,
                  isNativeSession(target),
                  let snapshot = nativeEnvironments[target.hostID]?.snapshot,
                  snapshot.id == target.terminalID {
            messages = snapshot.messages
        }
        return RemoteGitDirectoryHints.candidates(messages: messages, liveTools: liveTools,
                                                  sessionDirectory: directory)
    }
    func forgetRestoration(_ saved: SavedTerminal) { close(saved.session.id) }
    func saveWorkspace() {
        guard canSaveWorkspace else { return }
        var saved = workspace
        saved.pinned = tabs.ids.filter { $0 != tabs.previewID }.compactMap { id in openedSessions.first { $0.session.id == id } }
        saved.selectedTerminalID = tabs.selectedID == tabs.previewID ? nil : tabs.selectedID
        saved.selectedGroupID = selectedGroupID
        saved.destination = showDashboard || saved.selectedTerminalID == nil ? .home : .session
        if saved != workspace { workspace = saved }
        workspaceWriter.save(saved) { [weak self] error in
            // LocalizationValue interpolates strings and numbers, not an arbitrary Error.
            if let error {
                let detail = String(describing: error)
                Task { @MainActor in self?.workspaceError = L("工作台保存失败：\(detail)") }
            }
        }
    }
    /// Persist the dispatch intent before allowing any network side effect.
    func persistFollowUpIntent() throws {
        guard canSaveWorkspace else { throw WorkbenchError(L("工作台无法保存，托管消息尚未发送。")) }
        saveWorkspace()
        try workspaceWriter.flush(workspace)
    }
    func notifyInactiveTask(_ rule: FollowUpRule) { taskNotifications.notifyInactiveTask(rule) }
    private func catalogChanged() {
        let probe = PerfDiagnostics.begin()
        defer { PerfDiagnostics.end("catalog_refresh", probe, detail: "sessions=\(allSessions.count)") }
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
    let restoration = WorkbenchRestorationState()
    var restoreReport: [RestoredSession] { restoration.restoreReport }
    func dismissRestoreReport() { restoration.dismissRestoreReport() }
    func openRestoreEntry(_ entry: RestoredSession) {
        guard let item = allSessions.first(where: { $0.id == entry.id && $0.online && !$0.archived }) else { return }
        open(item)
    }
    private func resolveRestoreReports() {
        for connection in kimiEnvironments.values {
            restoration.resolveKimi(host: connection.host, online: connection.online, sessions: connection.sessions,
                                    workspace: workspace, allSessions: allSessions)
        }
        for connection in nativeEnvironments.values {
            restoration.resolveNative(host: connection.host, online: connection.online, catalogSynced: connection.catalogSynced,
                                      sessions: connection.sessions, workspace: workspace, allSessions: allSessions)
        }
    }
    /// Notifications compare each row's turn facts with the previous ones: the
    /// same `SessionTurn` the sidebar section and the Dock badge come from.
    private func updateTaskEvents() {
        let visible = showDashboard ? nil : selectedReference?.id
        for item in allSessions where !item.archived {
            taskNotifications.observe(item.turn, id: item.id, title: item.title, online: item.online, visibleSessionID: visible)
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
    private func restoreAvailableSessions() {
        if showNative, let reference = selectedReference, let connection = nativeEnvironments[reference.hostID], connection.sessions.contains(where: { $0.id == reference.terminalID }) { connection.select(reference.terminalID) }
        if showKimi, let reference = selectedReference, let connection = kimiEnvironments[reference.hostID], connection.online, connection.sessions.contains(where: { $0.id == reference.terminalID }) { connection.select(reference.terminalID) }
    }
    func flushDrafts() throws { for connection in kimiEnvironments.values { try connection.flushDrafts() }; for connection in nativeEnvironments.values { try connection.flushDrafts() } }
    func shutdown() {
        taskContextWindow.close()
        inspectorFiles.cancel()
        fileWindow.close()
        followUpLoop?.cancel(); followUpLoop = nil
        conversationPresentations.removeAll()
        try? flushDrafts()
        saveWorkspace()
        if canSaveWorkspace { do { try workspaceWriter.flush(workspace) } catch { workspaceError = error.localizedDescription } }
        kimiEnvironments.values.forEach { $0.disconnect() }; nativeEnvironments.values.forEach { $0.disconnect() }; connections.forEach { $0.disconnect() }
    }

}
