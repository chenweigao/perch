import AppKit
import Combine
import GhosttyTerminal
import SwiftUI
import WorkbenchCore

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var kimi: KimiConnection
    @Published var native: NativeAgentConnection
    private var kimiEnvironments: [UUID: KimiConnection] = [:]
    private var nativeEnvironments: [UUID: NativeAgentConnection] = [:]
    @Published var connections: [HostConnection]
    /// Whether the user has configured a machine list. Persisting the built-in
    /// machine's identity alone does not dismiss first-run setup.
    @Published private(set) var configuredEnvironment: Bool
    @Published var pendingHostRemoval: SSHHost?
    @Published var selectedHostID: UUID
    @Published private(set) var tabs = TerminalTabs()
    @Published private(set) var openedSessions: [SavedTerminal] = []
    @Published private(set) var terminals: [AttachedTerminal] = []
    @Published var showDashboard = true
    @Published var selectedGroupID: UUID?
    @Published var hostFilter: UUID?
    @Published var workspace = LocalWorkspace()
    @Published var workspaceError: String?
    @Published private(set) var allSessions: [WorkspaceSession] = []
    @Published var showArchived = false
    @Published var showSessionDirectory = false
    @Published var pendingDeletion: WorkspaceSession?
    @Published var renamingSession: WorkspaceSession?
    @Published var managementError: String?
    @Published var managing = Set<String>()
    /// Optimistic archive state applied before the server confirms, so the row
    /// leaves or returns in the same animation as the click. Cleared once the
    /// refreshed remote list agrees, or reverted on failure.
    private var archiveOverrides: [String: Bool] = [:]
    @Published var isArchiving = false
    @Published var archiveResult: BatchArchiveRun?
    @Published var showLocalSetup = false
    @Published var localOMP: DiscoveryState?
    @Published var probingLocal = false
    @Published var groupingSession: WorkspaceSession?
    @Published var search = ""
    @Published var onlyAttention = false
    @Published var showAddHost = false
    @Published var setupHost: SSHHost?
    @Published var launchAfterSetup: TaskLaunchDefaults?
    @Published var pendingSetupLaunch = false
    @Published var showNewTerminal = false
    @Published var showNewKimi = false
    @Published var showRenderReport = false
    @Published var renderReport = ""
    @Published var showGroupEditor = false
    @Published var editingGroup: WorkItemGroup?
    @Published var editingGroupSessionsOnly = false
    @Published var taskNotice: TaskNotice?
    @Published var notificationError: String?
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "task.notifications") {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "task.notifications")
            if notificationsEnabled { notifications.requestPermission { [weak self] error in self?.notificationError = error } }
        }
    }
    private let notifications = TaskNotifications()
    private var taskEvents = TaskEventTracker()
    private var pendingNotificationID: String?
    @Published var showConversationFind = false
    @Published var showSessionSearch = false
    @Published private(set) var navigation = SessionNavigation()
    private var navigatingHistory = false
    @Published var showFileViewer = false
    let fileBrowser = RemoteFileBrowser()
    private static let workspaceFileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.agentworkbench.mac")
        .appendingPathComponent("workspace.json")
    private let workspaceURL = WorkbenchModel.workspaceFileURL
    private lazy var workspaceWriter = WorkspaceWriter(url: workspaceURL)
    private var canSaveWorkspace = true
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    /// Session id → settings revision of the one naming attempt. A saved
    /// configuration change allows exactly one retry per session.
    private var namingAttempts: [String: Int] = [:]

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
        for connection in connections { observe(connection) }
        if !hosts.isEmpty { registerEnvironment(kimi: kimi, native: native) }
        for host in hosts where host.id != kimi.host.id {
            registerEnvironment(kimi: KimiConnection(host: host), native: NativeAgentConnection(host: host))
        }
        observers.append(NotificationCenter.default.addObserver(forName: .init("PerchOpenConversationFile"), object: nil, queue: .main) { [weak self] notice in
            guard let url = notice.object as? URL, let reference = ConversationFileReference(url: url) else { return }
            MainActor.assumeIsolated {
                guard let self, !self.showDashboard, self.selectedHost != nil else { return }
                self.showFileViewer = true; self.syncFileViewer()
                self.fileBrowser.open(reference.path, line: reference.line, fromConversation: true)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.connections.filter { $0.wantsConnection }.forEach { $0.connect() }
                self.connectEnabledAgents()
            }
        })
    }

    #if PERCH_ACCEPTANCE
    /// Full production views with an in-memory native transport. No restoration,
    /// persistence, connection startup, notifications or user workspace observers.
    init(acceptanceHost host: SSHHost, sessions: [WorkspaceSession], native: NativeAgentConnection) {
        kimi = KimiConnection(setupHost: host)
        self.native = native
        connections = []
        configuredEnvironment = true
        selectedHostID = host.id
        canSaveWorkspace = false
        allSessions = sessions
        workspace.starred = Array(sessions.prefix(4).map(\.reference))
        workspace.groups = [WorkItemGroup(name: "性能验收", goal: "固定离线数据", nextStep: "",
                                          sessions: Array(sessions.prefix(12).map(\.reference)))]
    }
    #endif

    private func registerEnvironment(kimi: KimiConnection, native: NativeAgentConnection) {
        kimiEnvironments[kimi.host.id] = kimi; nativeEnvironments[native.host.id] = native
        native.onSessionsChanged = { [weak self] in self?.catalogChanged() }
        kimi.onSessionsChanged = { [weak self] in self?.catalogChanged() }
        native.$online.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.catalogChanged() } }.store(in: &subscriptions)
        kimi.$online.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.catalogChanged() } }.store(in: &subscriptions)
        kimi.$conversation.sink { [weak self, weak kimi] conversation in
            Task { @MainActor in
                guard let self, let kimi, let conversation else { return }
                let session = conversation.snapshot.session
                self.considerNaming(reference: SessionReference(hostID: kimi.host.id, terminalID: session.id, kind: .kimi),
                                    remoteTitle: session.title, messages: conversation.messages,
                                    busy: session.busy, turnCompleted: session.lastTurnReason == "completed")
            }
        }.store(in: &subscriptions)
        native.$snapshot.sink { [weak self, weak native] snapshot in
            Task { @MainActor in
                guard let self, let native, let snapshot else { return }
                self.considerNaming(reference: SessionReference(hostID: native.host.id, terminalID: snapshot.id, kind: snapshot.provider),
                                    remoteTitle: snapshot.title, messages: snapshot.messages,
                                    busy: snapshot.busy, turnCompleted: false)
            }
        }.store(in: &subscriptions)
    }
    func activateAgentEnvironment(_ hostID: UUID) {
        guard let nextKimi = kimiEnvironments[hostID], let nextNative = nativeEnvironments[hostID] else { return }
        kimi = nextKimi; native = nextNative; selectedHostID = hostID
        if started { connectEnabledAgents() }
    }
    private func connectEnabledAgents() {
        if kimi.host.enabledAgents.contains(.kimi), !kimi.online, !kimi.connecting { kimi.connect() }
        if native.host.hasNativeAgents, !native.online { native.connect() }
    }
    func startNewTask() { if connections.isEmpty { configureHost() } else { showNewKimi = true } }
    func configureHost(_ host: SSHHost? = nil) { setupHost = host; showAddHost = true }
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
            if !host.enabledAgents.contains(.terminal) { connection.disconnect() }
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
        if started, host.enabledAgents.contains(.terminal) { selectedConnection?.connect() }
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
        else { showNewKimi = true }
    }
    func reconnectSelectedEnvironment() {
        if showKimi { kimi.connect() }
        else if showNative { native.connect() }
        else { selectedConnection?.connect() }
    }
    var selectedReference: SessionReference? { openedSessions.first { $0.session.id == tabs.selectedID }?.session }
    var showNative: Bool { !showDashboard && [.omp, .qoder, .dsh, .codex, .claude].contains(selectedReference?.kind) }
    var showKimi: Bool { !showDashboard && selectedReference?.kind == .kimi }
    var selectedTerminalID: String? { selectedReference?.kind == .terminal ? tabs.selectedID : nil }
    var previewTerminalID: String? { tabs.previewID }
    var selectedConnection: HostConnection? { connections.first { $0.id == selectedHostID } }
    var selectedTerminal: AttachedTerminal? { terminals.first { $0.id == selectedTerminalID } }
    var selectedGroup: WorkItemGroup? { workspace.groups.first { $0.id == selectedGroupID } }
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
        if next != allSessions { allSessions = next }
    }
    /// User-triggered list mutations (pin, archive) animate the row move;
    /// streamed catalog updates stay instant. Honors system Reduce Motion.
    private func animateCatalogChange(_ changes: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { changes() }
        else { withAnimation(.easeInOut(duration: 0.24), changes) }
    }
    var sessionScope: SessionScope {
        SessionCatalog.scope(allSessions, starred: workspace.starred, group: selectedGroup,
                             hostFilter: hostFilter, search: search,
                             onlyAttention: onlyAttention, showArchived: showArchived)
    }
    var scopedSessions: [WorkspaceSession] { sessionScope.sessions }

    private func observe(_ connection: HostConnection) {
        connection.onSnapshot = { [weak self] in self?.snapshotUpdated() }
        connection.$online.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.catalogChanged() } }.store(in: &subscriptions)
    }
    func removeHost(_ host: SSHHost) {
        guard let index = connections.firstIndex(where: { $0.id == host.id }) else { return }
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
        if hostFilter == host.id { hostFilter = nil }
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
        tabs.select(identity); showDashboard = false
        if let reference = selectedReference {
            if reference.kind != .terminal { activateAgentEnvironment(reference.hostID) }
            selectedHostID = reference.hostID
            if let group = selectedGroup, !group.sessions.contains(reference) { selectedGroupID = nil }
            if let group = selectedGroup { workspace.lastSessionByGroup[group.id.uuidString] = reference.id }
            if [.omp, .qoder, .dsh, .codex, .claude].contains(reference.kind) { native.select(reference.terminalID) }
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
        for terminal in terminals { terminal.context.isSurfaceVisible = !showDashboard && terminal.id == selectedTerminalID }
        if focus && !showDashboard && !showKimi { selectedTerminal?.context.requestFocus() }
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
        connections.filter { $0.host.enabledAgents.contains(.terminal) }.forEach { $0.connect() }; connectEnabledAgents()
    }
    func showHome(groupID: UUID? = nil) {
        onlyAttention = false; search = ""; showSessionDirectory = false
        showArchived = false
        selectedGroupID = groupID; hostFilter = nil; showDashboard = true
        tabs.showOverview(); updateVisibility(); saveWorkspace()
    }
    func showInbox() { showHome(); onlyAttention = true }
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
    func markReviewed(_ item: WorkspaceSession) {
        guard let kimi = kimiEnvironments[item.reference.hostID], let native = nativeEnvironments[item.reference.hostID] else { return }
        guard item.online else { return }
        if [.omp, .qoder, .dsh, .codex, .claude].contains(item.reference.kind), let session = native.sessions.first(where: { $0.id == item.reference.terminalID }) {
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
        selectedGroupID = nil; hostFilter = nil; showDashboard = true
        tabs.showOverview(); updateVisibility(); saveWorkspace()
    }
    func toggleStar(_ reference: SessionReference) {
        animateCatalogChange { workspace.toggleStar(reference) }
        saveWorkspace()
    }
    func setGroups(_ groupIDs: Set<UUID>, for reference: SessionReference) {
        for index in workspace.groups.indices {
            workspace.groups[index].sessions.removeAll { $0 == reference }
            if groupIDs.contains(workspace.groups[index].id) { workspace.groups[index].sessions.append(reference) }
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
        if [.omp, .qoder, .dsh, .codex, .claude].contains(item.reference.kind) {
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
                                  archived: session.archived == true, online: kimi.online, busy: session.busy,
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
                                   hasConfiguredEnvironment: configuredEnvironment, concurrencyLimit: 4)
    }
    /// What could not be restored, and any local-storage failure. A save or read
    /// failure used to be recorded and never shown.
    var dashboardContext: DashboardContext {
        DashboardContext(pendingRestoration: pendingRestoration, storageError: workspaceError)
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
        else if [.omp, .qoder, .dsh, .codex, .claude].contains(reference.kind) {
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
        return reference.kind == .kimi ? kimi.online : [.omp, .qoder, .dsh, .codex, .claude].contains(reference.kind) && native.online
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
        } else if [.omp, .qoder, .dsh, .codex, .claude].contains(reference.kind) {
            let existing = native.drafts[id] ?? ""
            native.drafts[id] = existing.isEmpty ? quoted + "\n\n" : existing + "\n\n" + quoted + "\n\n"
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil) }
    }
    /// Looks for a local OMP by running each candidate path directly. A GUI process
    /// does not inherit the shell PATH, and no shell is involved in the lookup, so a
    /// hostile directory name cannot become a command.
    func discoverLocalOMP() {
        guard !probingLocal else { return }
        probingLocal = true
        Task {
            defer { probingLocal = false }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = ProcessInfo.processInfo.environment["PATH"]
            for candidate in LocalAgentDiscovery.candidates(named: "omp", defaults: LocalAgentDiscovery.ompSearchPaths,
                                                            path: path, home: home) {
                guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
                do {
                    let output = try await ProcessRunner.run(candidate, ["--version"])
                    guard let version = LocalAgentDiscovery.parseOMPVersion(String(decoding: output, as: UTF8.self)) else {
                        localOMP = .unusable(path: candidate, reason: L("无法解析版本输出")); return
                    }
                    localOMP = .found(path: candidate, version: version); return
                } catch { localOMP = .unusable(path: candidate, reason: error.localizedDescription); return }
            }
            localOMP = .missing(hint: LocalAgentDiscovery.missingOMPHint)
        }
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
    /// One automatic naming attempt per session, only while its remote title
    /// is still a placeholder. Kimi waits for the first completed turn so a
    /// server-side title wins the race; native bridge titles never improve.
    private func considerNaming(reference: SessionReference, remoteTitle: String, messages: [KimiMessage],
                                busy: Bool, turnCompleted: Bool) {
        let settings = ActivitySummarySettings.shared
        let configuration = settings.configuration
        guard configuration.enabled, configuration.nameSessions, configuration.isValid else { return }
        guard workspace.sessionTitles[reference.id] == nil, !workspace.autoNamedSessions.contains(reference.id),
              namingAttempts[reference.id] != settings.revision else { return }
        if reference.kind == .kimi { guard !busy, turnCompleted else { return } }
        guard let excerpt = SessionNaming.excerpt(from: messages),
              SessionNaming.isPlaceholder(remoteTitle, kind: reference.kind, firstUserText: excerpt) else { return }
        let revision = settings.revision
        namingAttempts[reference.id] = revision
        Task {
            do {
                let key = try settings.apiKey()
                let name = try await SessionNamingClient().name(configuration: configuration, apiKey: key,
                                                                excerpt: excerpt, language: AppLanguage.current.localization)
                guard settings.revision == revision, workspace.sessionTitles[reference.id] == nil,
                      !workspace.autoNamedSessions.contains(reference.id) else { return }
                applyGeneratedName(name, for: reference)
            } catch {
                // Naming stays silent like summaries; the next launch may retry.
            }
        }
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
        if [.omp, .qoder, .dsh, .codex, .claude].contains(item.reference.kind) { return native.online && native.sessions.first(where: { $0.id == item.reference.terminalID })?.busy == false }
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
                else if [.omp, .qoder, .dsh, .codex, .claude].contains(item.reference.kind) { try await native.action(item.reference.terminalID, "delete") }
                else if let connection = connections.first(where: { $0.id == item.reference.hostID }) { try await connection.closeTerminal(item.reference.terminalID) }
                if tabs.ids.contains(item.id) { close(item.id) }
                workspace.removeSession(item.reference)
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
                  [.omp, .qoder, .dsh, .codex, .claude].contains(reference.kind),
                  let snapshot = nativeEnvironments[reference.hostID]?.snapshot,
                  snapshot.id == reference.terminalID {
            messages = snapshot.messages
        }
        let hints = RemoteGitDirectoryHints.candidates(messages: messages, liveTools: liveTools,
                                                       sessionDirectory: directory)
        fileBrowser.configure(host: selectedHost, cwd: directory, gitDirectoryHints: hints)
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
        if let id = pendingNotificationID, let item = allSessions.first(where: { $0.id == id && $0.online && !$0.archived }) {
            pendingNotificationID = nil; open(item)
        }
        for item in allSessions where item.archived && tabs.ids.contains(item.id) { close(item.id) }
        restoreAvailableSessions()
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
        context = TerminalViewState(theme: TerminalTheme(light: palette, dark: palette),
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
