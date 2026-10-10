import Foundation
import Observation
import UniformTypeIdentifiers
import WorkbenchCore

@MainActor @Observable
final class NativeAgentConnection {
    let conversation = NativeConversationState()
    private(set) var host: SSHHost
    private(set) var sessions: [NativeAgentSession] = []
    private(set) var snapshot: NativeAgentSnapshot? {
        get { conversation.snapshot }
        set { conversation.snapshot = newValue; onSnapshotChanged?(newValue) }
    }
    var selectedID: String? { conversation.selectedID }
    private(set) var timings = ConversationTimings()
    private(set) var online = false {
        didSet { if online != oldValue { onOnlineChanged?() } }
    }
    /// `online` marks the tunnel, not the data: the first catalog arrives one poll
    /// later. Restore reporting waits for this flag so it never judges a session
    /// against a stale pre-disconnect list.
    private(set) var catalogSynced = false
    private(set) var wantsConnection = false
    var error: String?
    var actionError: String? {
        get { conversation.actionError }
        set { conversation.actionError = newValue }
    }
    var drafts: [String: String] = [:] { didSet { persistDrafts(coalescing: true) } }
    /// Staged files for the composer; bytes are copied into the queued message at
    /// send time, so these URLs only matter until then.
    var attachments: [String: [URL]] = [:] { didSet { persistDrafts() } }
    private var sendingSessions: Set<String> = []
    var sending: Bool { selectedID.map { sendingSessions.contains($0) } ?? false }
    var queue = OutboundQueue() { didSet { persistDrafts() } }
    /// Sent prompts per session, oldest first, for composer Up-arrow recall.
    private(set) var history: [String: [String]] = [:] { didSet { persistDrafts() } }
    func historyEntries(for id: String) -> [String] { history[id] ?? [] }
    var stops = StopController()
    /// The bridge's combined catalog: OMP answers `omp models`, Codex answers
    /// `model/list`, and dsh contributes its ACP config options after each handshake.
    /// Qoder keeps an empty list rather than being offered models it cannot switch to.
    private(set) var models: [AgentModel] = []
    /// Reading the catalog is asked for by the conversation header and by the
    /// new-task sheet, so its failure belongs to whichever control is showing a
    /// model list rather than to the whole session.
    private(set) var modelsError: String?
    /// The bridge process actually serving this connection: its source digest and
    /// start time, not the files currently deployed on the host.
    private(set) var runtime = RunningRuntime.unknown
    @ObservationIgnored var onOnlineChanged: (() -> Void)?
    @ObservationIgnored var onSnapshotChanged: ((NativeAgentSnapshot?) -> Void)?
    @ObservationIgnored var onSessionsChanged: (() -> Void)?
    @ObservationIgnored private var api: KimiAPI?
    @ObservationIgnored private var tunnel: Process?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    var loadingOlder: Bool { conversation.loadingOlder }
    @ObservationIgnored private var historyWindows: [String: (start: Int, epoch: String)] = [:]
    @ObservationIgnored private var nextCatalogRefresh = Date.distantPast
    @ObservationIgnored private var nextIdleSnapshotRefresh = Date.distantPast
    /// Idle snapshot reads double their interval while nothing changes (2s → 4s → 8s).
    @ObservationIgnored private var idleSnapshotInterval: TimeInterval = 2
    @ObservationIgnored private var pendingWake: CheckedContinuation<Void, Never>?
    private var selectionGeneration: UUID { conversation.generation }
    @ObservationIgnored private var generation = UUID()
    private let requestTransport: ((String, JSONValue?) async throws -> Data)?
    @ObservationIgnored private var draftFile: DraftFile?
    /// Folded long pastes live on disk per host; tokens ride inside drafts.
    let pastes: DraftPasteStore
    @ObservationIgnored private var draftLoadError: String?
    private(set) var draftSaveError: String?
    private var savedDrafts: SavedDrafts { SavedDrafts(text: drafts, attachments: attachments, outbox: queue, history: history) }
    private func loadDrafts() {
        let file = DraftFile.applicationFile(namespace: "native-\(host.id)")
        do {
            let saved = try file.load()
            drafts = saved.text
            attachments = saved.attachments
            queue = saved.outbox
            history = saved.history
            draftFile = file
        } catch { draftLoadError = error.localizedDescription; draftSaveError = L("草稿恢复失败，原文件已保留：\(error.localizedDescription)") }
    }
    private func persistDrafts(coalescing: Bool = false) {
        draftFile?.save(savedDrafts, coalescing: coalescing) { [weak self] error in
            Task { @MainActor in self?.draftSaveError = error.map { L("草稿保存失败：\($0)") } }
        }
    }
    func flushDrafts() throws {
        if let draftLoadError { throw WorkbenchError(draftLoadError) }
        try draftFile?.flush(savedDrafts)
    }

    init(host: SSHHost) {
        self.host = host; requestTransport = nil
        pastes = DraftPasteStore.applicationStore(namespace: "native-\(host.id)")
        loadDrafts()
    }
    /// A setup probe must never drain the user's persisted outbox.
    init(setupHost: SSHHost) {
        self.host = setupHost; requestTransport = nil
        pastes = DraftPasteStore.applicationStore(namespace: "native-\(setupHost.id)")
    }
    /// Used by the isolated connection contract checks; no SSH or App is started.
    init(host: SSHHost, transport: @escaping (String, JSONValue?) async throws -> Data) {
        self.host = host; requestTransport = transport; online = true
        pastes = DraftPasteStore.applicationStore(namespace: "native-\(host.id)")
    }
    func updateHost(_ value: SSHHost) {
        if value.destination != host.destination { disconnect() }
        host = value
    }
    func setupStatus(provider: SessionKind) async throws -> JSONValue {
        try await request("/setup?provider=" + provider.rawValue)
    }
    func connect() {
        guard host.isLocal || !host.destination.isEmpty else { return }
        disconnect(); let token = UUID(); generation = token; wantsConnection = true
        task = Task {
            while !Task.isCancelled && generation == token {
                do {
                    try await establish(token)
                    online = true; error = nil; onSessionsChanged?()
                    while !Task.isCancelled && generation == token {
                        try await poll()
                        await sleepUntilNextPoll()
                    }
                } catch is CancellationError { return }
                catch {
                    guard generation == token else { return }
                    online = false; catalogSynced = false; self.error = error.localizedDescription; closeTunnel(); onSessionsChanged?()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
    }
    func disconnect() {
        generation = UUID(); conversation.cancelLoads()
        task?.cancel(); task = nil
        nextCatalogRefresh = .distantPast
        nextIdleSnapshotRefresh = .distantPast
        idleSnapshotInterval = 2
        wakePolling()
        online = false; catalogSynced = false; wantsConnection = false; error = nil; closeTunnel()
    }
    /// User actions that change remote state or force refreshes wake the poll loop
    /// before its next scheduled deadline.
    private func wakePolling() {
        pendingWake?.resume(); pendingWake = nil
    }
    private func completeWake() {
        pendingWake?.resume(); pendingWake = nil
    }
    /// Idle connections wait for the next due read instead of waking every 400ms.
    /// Busy sessions, pending interactions and in-flight sends keep the fast tick.
    private func sleepUntilNextPoll() async {
        let now = Date()
        var due = nextCatalogRefresh
        if selectedID != nil { due = min(due, nextIdleSnapshotRefresh) }
        if needsFastTick { due = min(due, now.addingTimeInterval(0.4)) }
        let delay = due.timeIntervalSince(now)
        guard delay > 0.05 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingWake = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.completeWake()
            }
        }
    }
    private var needsFastTick: Bool {
        if sessions.contains(where: \.busy) { return true }
        if snapshot?.busy == true || snapshot?.interactions.isEmpty == false { return true }
        if let selected = sessions.first(where: { $0.id == selectedID }), selected.pending > 0 { return true }
        return queue.allItems.contains { message in
            switch message.state {
            case .submitting, .accepted, .running, .unknown: return true
            case .draftQueued, .failed, .stoppedBeforeDelivery, .delivered: return false
            }
        }
    }
    private func closeTunnel() {
        api?.invalidate(); api = nil
        if let tunnel, tunnel.isRunning { tunnel.terminate() }; tunnel = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
    }
    private func establish(_ token: UUID) async throws {
        let data: Data
        if host.isLocal {
            data = try await LocalAgentRuntime.endpoint(for: .codex, host: host)
        } else {
            try SSHCommand.validateDestination(host.destination)
            data = try await SetupCommandRunner.run("/usr/bin/ssh", RemoteSetup.sshArguments(host.destination,
                command: "python3 ~/.local/share/agent-workbench/native/native-agent-service.py --ensure"))
        }
        try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
        let endpoint = try JSONDecoder().decode(JSONValue.self, from: data)
        if let pending = endpoint["restartPending"].int {
            if pending > 0 {
                throw WorkbenchError(L("桥接组件已更新，但远端仍有任务运行。任务结束后重新检查；Perch 会自动安全重启服务。"))
            }
            throw WorkbenchError(L("桥接组件已更新，但无法确认旧服务是否空闲。为避免中断任务，请在远端终端手动重启桥接服务。"))
        }
        guard let port = endpoint["port"].int, let secret = endpoint["token"].string else { throw WorkbenchError("原生对话托管服务未安装或不可用") }
        if host.isLocal {
            api = KimiAPI(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: secret)
            try await readBridgeHealth()
            return
        }
        let local = try KimiAPI.availableLoopbackPort()
        let folder = URL(fileURLWithPath: "/tmp/awb-native-\(UUID().uuidString.prefix(10))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); directory = folder
        let control = folder.appendingPathComponent("ssh").path
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-N", "-T", "-M", "-S", control, "-o", "ControlPersist=no", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-L", "127.0.0.1:\(local):127.0.0.1:\(port)", host.destination]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        tunnel = p; try p.run()
        for _ in 0..<100 {
            try Task.checkCancellation()
            if !p.isRunning { throw WorkbenchError("原生对话 SSH 转发失败") }
            if FileManager.default.fileExists(atPath: control) {
                api = KimiAPI(baseURL: URL(string: "http://127.0.0.1:\(local)")!, token: secret)
                try await readBridgeHealth()
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WorkbenchError("原生对话 SSH 转发超时")
    }
    /// The protocol gate plus the identity of the process actually serving: a
    /// hand-bumped version number does not say which source it is executing.
    private func readBridgeHealth() async throws {
        let health: JSONValue = try await request("/health")
        let expected = RemoteSetup.bridgeServiceVersion
        guard let version = health["version"].int else {
            throw WorkbenchError(L("无法读取远端桥接服务的版本。请重新安装桥接组件后重试。"))
        }
        guard version == expected else {
            throw WorkbenchError(L("远端桥接服务是 v\(version)，此 Perch 需要 v\(expected)。请在主机设置中安装 / 更新桥接组件。"))
        }
        runtime = RunningRuntime(version: health["implementation"].string,
                                 startedAt: health["startedAt"].string)
    }
    private func request<T: Decodable>(_ path: String, body: JSONValue? = nil) async throws -> T {
        let data: Data
        if let requestTransport { data = try await requestTransport(path, body) }
        else {
            guard let api else { throw WorkbenchError("请先连接原生对话服务") }
            data = try await api.request(path, method: body == nil ? "GET" : "POST", body: body)
        }
        return try await Self.decodeResponse(T.self, from: data)
    }
    // A changed snapshot can contain the entire history. Keep decoding off the
    // main actor while the caller retains its selection/cancellation checks.
    nonisolated private static func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
        try Task.checkCancellation()
        return try NativeAgentWire.decode(type, from: data)
    }
    /// Catalogs change much less often than the selected streaming reply.
    /// Receipts still advance at the regular tick so queued sends are not delayed.
    func poll(now: Date = Date()) async throws {
        if now >= nextCatalogRefresh {
            try await refresh()
            nextCatalogRefresh = now.addingTimeInterval(sessions.contains(where: \.busy) ? 2 : 5)
        } else { try await refreshReceipts() }
        let selected = sessions.first { $0.id == selectedID }
        let active = snapshot == nil || snapshot?.busy == true || selected?.busy == true
            || (selected?.pending ?? 0) > 0 || snapshot?.interactions.isEmpty == false
            || queue.allItems.contains { message in
                guard message.session.terminalID == selectedID else { return false }
                switch message.state {
                case .submitting, .accepted, .running, .unknown: return true
                case .draftQueued: return queue.nextPendingID(for: message.session, isStreaming: false) == message.id
                case .failed, .stoppedBeforeDelivery, .delivered: return false
                }
            }
        if !conversation.isSelecting && (active || now >= nextIdleSnapshotRefresh) {
            // Schedule before the read so the read itself can override it (an
            // expanded history window forces an immediate follow-up read).
            nextIdleSnapshotRefresh = now.addingTimeInterval(active ? 2 : idleSnapshotInterval)
            let changed = try await refreshSelected()
            if nextIdleSnapshotRefresh == .distantPast {
                idleSnapshotInterval = 2
            } else if !active {
                if changed {
                    idleSnapshotInterval = 2
                    nextIdleSnapshotRefresh = now.addingTimeInterval(2)
                } else {
                    idleSnapshotInterval = min(8, idleSnapshotInterval * 2)
                }
            }
        }
    }
    func refresh() async throws {
        struct Catalog: Decodable { let sessions: [NativeAgentSession] }
        let value: Catalog = try await request("/sessions")
        let next = value.sessions.sorted { $0.updated > $1.updated }
        if next.first(where: { $0.id == selectedID }) != sessions.first(where: { $0.id == selectedID }) {
            nextIdleSnapshotRefresh = .distantPast
            idleSnapshotInterval = 2
        }
        var clocks = timings
        for session in next {
            clocks.observe(sessionID: session.id, turnID: session.turnId, requestID: session.turnId,
                           running: session.busy, waiting: session.pending > 0)
        }
        if clocks != timings { timings = clocks }
        if let id = selectedID, !next.contains(where: { $0.id == id }) { conversation.select(nil) }
        let changed = next != sessions
        if changed { sessions = next }
        // The first successful read of this connection generation settles the
        // catalog even when nothing moved; observers resolve restore outcomes on it.
        let firstSync = !catalogSynced
        catalogSynced = true
        if changed || firstSync { onSessionsChanged?() }
        reconcileStops()
        nextCatalogRefresh = Date().addingTimeInterval(sessions.contains(where: \.busy) ? 2 : 5)
        try await refreshReceipts()
    }
    private func refreshReceipts() async throws {
        // Receipts, not catalog changes, settle pending sends after a reconnect.
        for message in queue.allItems where !sendingSessions.contains(message.session.terminalID) {
            guard sessions.contains(where: { $0.id == message.session.terminalID }) else { continue }
            switch message.state {
            case .submitting, .accepted, .running, .unknown:
                let receipt: NativeRequestReceipt = try await request("/sessions/\(message.session.terminalID)/requests/\(message.id)")
                apply(receipt)
            default: break
            }
        }
        drainQueues()
    }
    /// Only the selected session's messages are held, so other sessions offer nothing.
    func loadedMessages(for id: String) -> [KimiMessage]? {
        snapshot?.id == id && snapshot?.hasOlder == false ? snapshot?.messages : nil
    }
    func recapMessages(for id: String) async throws -> [KimiMessage] {
        guard id == selectedID, var full = snapshot, full.id == id,
              !full.busy, full.interactions.isEmpty, full.error == nil, full.completed > 0 else {
            throw WorkbenchError(L("任务尚未完成，暂时不能生成 Recap。"))
        }
        let selectionToken = selectionGeneration
        let connectionToken = generation
        let completion = full.completed
        if !full.hasOlder { return full.messages }
        guard online else { throw WorkbenchError(L("需要连接 Agent 才能读取完整任务记录。")) }
        while full.hasOlder {
            guard let window = full.history else { throw WorkbenchError(L("无法读取完整任务记录。")) }
            let page: NativeAgentSnapshot = try await request(
                "/sessions/\(id)?before=\(window.start)&epoch=\(window.epoch)&turns=50")
            try Task.checkCancellation()
            guard selectionToken == selectionGeneration, connectionToken == generation, id == selectedID,
                  let current = snapshot, current.id == id, !current.busy,
                  current.interactions.isEmpty, current.error == nil, current.completed == completion,
                  current.history?.epoch == window.epoch else { throw CancellationError() }
            full = try full.prepending(page)
        }
        return full.messages
    }
    func select(_ id: String) {
        guard selectedID != id || (snapshot == nil && !conversation.isSelecting) else { return }
        if let snapshot, let window = snapshot.history { historyWindows[snapshot.id] = (window.start, window.epoch) }
        conversation.select(id); nextIdleSnapshotRefresh = .distantPast; idleSnapshotInterval = 2
        wakePolling()
        guard online else { return }
        conversation.loadSelection { [weak self] in
            _ = try await self?.refreshSelected()
        }
    }
    #if PERCH_ACCEPTANCE
    func acceptanceRefreshSelected() async throws { _ = try await refreshSelected() }
    #endif
    /// Returns true when a snapshot was applied; unchanged reads return false so
    /// idle polling can back off.
    @discardableResult
    private func refreshSelected() async throws -> Bool {
        try Task.checkCancellation()
        guard let id = selectedID else { return false }
        let token = selectionGeneration, connectionToken = generation
        let suffix: String
        if let current = snapshot, current.id == id {
            if let window = current.history {
                suffix = "?start=\(window.start)&epoch=\(window.epoch)&revision=\(current.revision)"
            } else { suffix = "?revision=\(current.revision)" }
        } else if let window = historyWindows[id] {
            suffix = "?start=\(window.start)&epoch=\(window.epoch)&turns=50"
        } else { suffix = "?turns=50" }
        let response: NativeSnapshotResponse = try await request("/sessions/\(id)\(suffix)")
        try Task.checkCancellation()
        guard token == selectionGeneration, connectionToken == generation, id == selectedID,
              let value = response.snapshot else { return false }
        // A page may have expanded the window while this delta was in flight.
        // It did not cover edits in that newly loaded prefix: leave the revision
        // untouched and let the next normal tick request the expanded window.
        if let window = value.history, window.indices != nil, window.start != snapshot?.history?.start {
            nextIdleSnapshotRefresh = .distantPast
            idleSnapshotInterval = 2
            return true
        }
        let next = try value.applying(to: snapshot)
        if let previous = snapshot, previous.busy != next.busy || previous.completed != next.completed || previous.interactions != next.interactions {
            nextCatalogRefresh = .distantPast
        }
        snapshot = next
        return true
    }
    func loadOlder() { loadHistory(all: false) }
    func loadAllHistoryForSearch() { loadHistory(all: true) }
    private func loadHistory(all: Bool) {
        guard online, !loadingOlder, snapshot?.hasOlder == true, let id = selectedID else { return }
        let token = selectionGeneration, connectionToken = generation
        conversation.loadHistory { [self] in
            repeat {
                guard let current = snapshot, let window = current.history, current.hasOlder else { return }
                let page: NativeAgentSnapshot = try await request("/sessions/\(id)?before=\(window.start)&epoch=\(window.epoch)&turns=50")
                try Task.checkCancellation()
                guard token == selectionGeneration, connectionToken == generation, id == selectedID,
                      let latest = snapshot else { return }
                snapshot = try latest.prepending(page)
                if let expanded = snapshot?.history { historyWindows[id] = (expanded.start, expanded.epoch) }
            } while all
        }
    }

    func create(provider: SessionKind, cwd: String, model: String, thinking: ThinkingLevel? = nil,
                permissionMode: String? = nil) async throws -> NativeAgentSession {
        guard let selectedPermission = permissionMode ?? PermissionDefaults.mode(for: provider),
              PermissionCatalog.isValid(selectedPermission, for: provider) else {
            throw WorkbenchError("当前 Agent 的权限模式无效")
        }
        var body: [String: JSONValue] = [
            "provider": .string(provider.rawValue), "cwd": .string(cwd), "model": .string(model),
            "permissionMode": .string(selectedPermission)
        ]
        if let thinking { body["thinking"] = .string(thinking.rawValue) }
        let session: NativeAgentSession = try await request("/sessions", body: .object(body))
        sessions.insert(session, at: 0); onSessionsChanged?(); select(session.id); return session
    }
    /// The catalog is re-read on every session switch and whenever the new-task
    /// sheet offers a native runtime, because it is not static: a dsh session
    /// contributes its options only after the ACP handshake lands. Failures keep the
    /// last good list and report through `modelsError`.
    func loadModels() async {
        do {
            let value: JSONValue = try await request("/models")
            let parsed = ModelSelectionCatalog.parseOMP(value["models"])
            if parsed != models { models = parsed }
            modelsError = nil
        } catch { modelsError = error.localizedDescription }
    }
    /// The catalog is combined, so a runtime is only offered the models that claim it.
    /// Qoder's SDK reports no catalog at all and stays with a typed model id.
    func models(for kind: SessionKind) -> [AgentModel] {
        ModelSelectionCatalog.forAgent(kind, in: models)
    }
    func model(for snapshot: NativeAgentSnapshot) -> AgentModel? {
        ModelSelectionCatalog.model(snapshot.model, in: models(for: snapshot.provider))
    }
    private(set) var configuringSessions: Set<String> = []

    /// Switching models can leave the current effort unsupported, so the level is
    /// resolved against the target model and re-sent rather than carried over.
    func setModel(_ target: AgentModel, for id: String) {
        guard configuringSessions.insert(id).inserted else { return }
        let current = ThinkingLevel.parse(sessions.first { $0.id == id }?.thinking)
        Task {
            defer { configuringSessions.remove(id) }
            do {
                try await action(id, "model", ["provider": .string(target.provider), "model": .string(target.id)])
                if let resolved = target.resolve(current), resolved != current {
                    try await action(id, "thinking", ["level": .string(resolved.rawValue)])
                }
            } catch { actionError = error.localizedDescription }
        }
    }
    func setThinking(_ level: ThinkingLevel, for id: String) {
        guard configuringSessions.insert(id).inserted else { return }
        Task {
            defer { configuringSessions.remove(id) }
            do { try await action(id, "thinking", ["level": .string(level.rawValue)]) }
            catch { actionError = error.localizedDescription }
        }
    }
    func setPermission(_ mode: String, for id: String) {
        guard let provider = sessions.first(where: { $0.id == id })?.provider,
              [.qoder, .qoderintl, .claude].contains(provider),
              PermissionCatalog.isValid(mode, for: provider) else {
            actionError = L("当前 Agent 不支持动态切换权限")
            return
        }
        Task {
            do { try await action(id, "permission", ["mode": .string(mode)]) }
            catch { actionError = error.localizedDescription }
        }
    }
    func reference(_ id: String) -> SessionReference? {
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        return SessionReference(hostID: host.id, terminalID: id, kind: session.provider)
    }
    func modes(for id: String) -> [DeliveryMode] {
        guard let session = sessions.first(where: { $0.id == id }) else { return [] }
        return AgentCapabilities(nativeConversation: true, stop: true,
                                 steer: session.steer == true ? .commandPresentEffectUnverified : .unsupported,
                                 queueWhileBusy: true, resume: true).modes(isStreaming: session.busy)
    }
    /// Queues the draft and delivers steering during a turn or other input when free. The
    /// draft is cleared only once the message is queued, so nothing is lost if the
    /// request fails.
    func send(mode: DeliveryMode = .now) {
        guard online, let id = selectedID, let reference = reference(id) else { return }
        let draftText = drafts[id] ?? ""
        let files = attachments[id] ?? []
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        if !files.isEmpty {
            guard sessions.first(where: { $0.id == id })?.provider == .claude else {
                actionError = L("当前 Agent 不支持发送附件")
                return
            }
            guard files.count <= 5 else { actionError = L("附件一次最多 5 个"); return }
        }
        // Folded pastes rejoin the prompt here; a lost paste file must not
        // silently send a prompt with a dead token in it.
        let expansion = pastes.expand(draftText)
        guard expansion.missing.isEmpty else {
            actionError = L("粘贴内容已丢失，请重新粘贴后再发送。")
            return
        }
        let text = expansion.text
        // A draft that names one of this session's commands runs that command; sending
        // it to the model would just produce a reply about the text "/compact".
        if let snapshot, snapshot.id == id, let commands = snapshot.commands,
           let invocation = SlashCommands.invocation(in: text, from: commands) {
            guard files.isEmpty else { actionError = L("Remove attachments before running a command."); return }
            run(invocation.command, arguments: invocation.arguments, for: id, draft: text)
            return
        }
        if SlashCommands.invocation(in: text, from: [AgentCommand(name: "goal")]) != nil {
            actionError = L("This agent does not expose /goal to Perch. Use its terminal or a Kimi conversation.")
            return
        }
        var payload: [OutboundAttachment] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                guard !data.isEmpty, data.count <= 10_485_760 else {
                    actionError = L("附件为空或超过 10MB：\(file.lastPathComponent)")
                    return
                }
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                payload.append(OutboundAttachment(name: file.lastPathComponent, mediaType: mime, data: data))
            } catch {
                actionError = L("读取附件失败：\(error.localizedDescription)")
                return
            }
        }
        guard queue.enqueue(text, for: reference, mode: mode, attachments: payload) != nil else { return }
        PromptHistory.record(draftText, for: id, into: &history)
        drafts[id] = ""
        attachments[id] = nil
        actionError = nil
        // A stop pauses the queue so it is not immediately followed by a new turn.
        // Once that stop has settled, an explicit new send lifts the pause; parked
        // messages still wait for "Resume queued messages".
        if queue.isPaused(reference), !stops.isStopping(reference) { queue.unpause(reference) }
        deliver(id)
    }
    private func deliver(_ id: String) {
        guard online, !sendingSessions.contains(id), let reference = reference(id) else { return }
        let busy = sessions.first { $0.id == id }?.busy ?? false
        guard queue.nextPendingID(for: reference, isStreaming: busy) != nil else { return }
        guard let message = queue.nextDelivery(for: reference, isStreaming: busy) else { return }
        sendingSessions.insert(id)
        timings.submitted(message.id)
        wakePolling()
        Task {
            defer { sendingSessions.remove(id); drainQueues() }
            do {
                var fields: [String: JSONValue] = ["text": .string(message.text), "requestId": .string(message.id)]
                if !message.attachments.isEmpty {
                    fields["attachments"] = .array(message.attachments.map {
                        .object(["name": .string($0.name), "mediaType": .string($0.mediaType),
                                 "data": .string($0.data.base64EncodedString())])
                    })
                }
                let receipt: NativeRequestReceipt = try await request("/sessions/\(id)/\(message.mode == .steer ? "steer" : "prompt")", body: .object(fields))
                apply(receipt)
                nextCatalogRefresh = .distantPast
                do { try await refresh() } catch { actionError = "操作已受理，同步失败：\(error.localizedDescription)" }
            } catch {
                queue.markUnknown(message.id, error.localizedDescription)
                if selectedID == id { actionError = error.localizedDescription }
            }
        }
    }
    private func apply(_ receipt: NativeRequestReceipt) {
        guard let message = queue.message(receipt.id) else { return }
        let sessionID = message.session.terminalID
        let next: OutboundState
        switch receipt.status {
        case "submitting", "submitted": next = .submitting
        case "accepted": next = .accepted
        case "running": next = .running
        case "consumed":
            // Keep the local bubble until the corresponding history is on screen.
            if snapshot?.id != sessionID || snapshot?.messages.contains(where: { $0.id == receipt.id }) == true {
                queue.markDelivered(receipt.id)
            } else { queue.markAccepted(receipt.id) }
            return
        case "completed", "stopped":
            if receipt.mode != "steer" {
                timings.finished(sessionID: sessionID, requestID: receipt.id, turnID: receipt.activeTurnId)
            }
            queue.markDelivered(receipt.id); return
        case "failed": next = .failed(receipt.error ?? "运行时拒绝消息")
        case "notFound": next = .failed("服务端没有受理记录，可移回草稿后发送")
        default: next = .unknown(receipt.error ?? "请同步并核对会话，暂勿重复提交")
        }
        if receipt.mode != "steer", ["submitting", "submitted", "accepted", "running"].contains(receipt.status) {
            timings.observe(sessionID: sessionID, turnID: receipt.activeTurnId, requestID: receipt.id,
                            running: true, waiting: timings.turns[sessionID]?.turnID == receipt.activeTurnId
                                && timings.turns[sessionID]?.waitingSince != nil)
        }
        guard next != message.state else { return }
        switch next {
        case .submitting: queue.markSubmitting(receipt.id)
        case .accepted: queue.markAccepted(receipt.id)
        case .running: queue.markRunning(receipt.id)
        case .failed(let error): queue.markFailed(receipt.id, error)
        case .unknown(let error): queue.markUnknown(receipt.id, error)
        default: break
        }
    }
    private func drainQueues() {
        let pending = Set(queue.allItems.filter { $0.state == .draftQueued }.map { $0.session.terminalID })
        for session in sessions where pending.contains(session.id) { deliver(session.id) }
    }
    func resumeQueue(_ reference: SessionReference) {
        guard online, sessions.first(where: { $0.id == reference.terminalID })?.busy == false,
              !stops.isStopping(reference) else { return }
        queue.resume(reference); deliver(reference.terminalID)
    }
    func retry(_ messageID: String) {
        guard let message = queue.retry(messageID) else { return }
        deliver(message.session.terminalID)
    }
    func restoreFailed(_ message: OutboundMessage) {
        guard queue.removeFailed(message.id) else { return }
        let id = message.session.terminalID
        let existing = drafts[id] ?? ""
        drafts[id] = existing.isEmpty ? message.text : existing + "\n\n" + message.text
        // The queued message carries bytes, not URLs, so restoring to the composer
        // means materializing them again.
        for attachment in message.attachments {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentWorkbenchAttachments", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(attachment.name)")
                try attachment.data.write(to: file, options: .atomic)
                attachments[id, default: []].append(file)
            } catch { actionError = L("附件恢复失败：\(error.localizedDescription)") }
        }
        drainQueues()
    }

    /// Re-sends text as a new prompt. An in-progress draft is never replaced:
    /// the resend queues behind it instead.
    func resend(_ text: String, for id: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reference(id) != nil else { return }
        if selectedID == id, (drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[id] = text
            send(mode: modes(for: id).first ?? .now)
            return
        }
        guard let reference = reference(id),
              queue.enqueue(text, for: reference, mode: .nextTurn) != nil else { return }
        PromptHistory.record(text, for: id, into: &history)
        deliver(id)
    }

    /// Regeneration re-sends the user prompt that preceded the given message.
    func resendPrompt(before messageID: String, for id: String) -> String? {
        guard snapshot?.id == id, let messages = snapshot?.messages,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              let user = messages[..<index].last(where: { $0.isUserPrompt }) else {
            return L("找不到这条回复对应的提问，无法重新生成。")
        }
        let text = user.content.filter { $0.type == "text" && !$0.isRuntimeContext }
            .map { $0.skillContextSplit?.prefix ?? $0.text ?? "" }.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return L("这条回复对应的提问没有文字内容。") }
        resend(text, for: id)
        return nil
    }
    /// Runs a slash command instead of sending it to the model. Only `compact` has
    /// its own RPC verb; the runtime has no generic command-invocation command, so
    /// anything else is refused rather than quietly sent as a prompt.
    func run(_ command: AgentCommand, arguments: String, for id: String, draft: String) {
        guard command.name == "compact" else {
            actionError = "暂不支持在 Perch 中执行 /\(command.name)，请在终端使用"
            return
        }
        guard arguments.isEmpty else {
            actionError = "当前版本不支持 /compact 参数；草稿已保留，请调整后发送"
            return
        }
        guard !sendingSessions.contains(id) else { return }
        sendingSessions.insert(id)
        Task {
            defer { sendingSessions.remove(id) }
            do {
                try await action(id, "command", ["name": .string(command.name)])
                if drafts[id] == draft { drafts[id] = "" }
            }
            catch {
                actionError = error.localizedDescription
            }
        }
    }
    var isStopping: Bool {
        guard let id = selectedID, let reference = reference(id) else { return false }
        return stops.isStopping(reference)
    }
    var canStop: Bool {
        guard online, let id = selectedID,
              let session = sessions.first(where: { $0.id == id }), session.busy, session.turnId != nil,
              let reference = reference(id) else { return false }
        let phase = stops.phase(for: reference)
        return phase == .idle || phase.canRetry
    }
    /// Requests a stop for the session that was on screen. The phase stays short of
    /// "stopped" until the bridge reports the runtime's own terminal state.
    func stop() {
        guard canStop, let id = selectedID, let reference = reference(id),
              let turn = sessions.first(where: { $0.id == id })?.turnId,
              let attempt = stops.request(reference, turn: turn) else { return }
        queue.pauseForStop(reference)
        Task {
            do { try await action(id, "abort", ["turnId": .string(turn)]); stops.acknowledge(attempt.requestID) }
            catch { stops.timedOut(attempt.requestID, error.localizedDescription) }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            stops.timedOut(attempt.requestID)
        }
    }
    private func reconcileStops() {
        for session in sessions {
            let reference = SessionReference(hostID: host.id, terminalID: session.id, kind: session.provider)
            guard let attempt = stops.attempt(for: reference) else { continue }
            guard attempt.turn == session.turnId else {
                stops.clear(reference); continue
            }
            if attempt.phase == .stopped || attempt.phase == .completedBeforeStop { continue }
            if !session.busy {
                switch session.turnState {
                case "stopped": stops.resolve(reference, turn: session.turnId, evidence: .runtimeAborted)
                case "completed": stops.resolve(reference, turn: session.turnId, evidence: .completedBeforeStop)
                case "failed", "unknown":
                    if !attempt.phase.isSettled { stops.timedOut(attempt.requestID, session.error ?? "终止结果未知，请核对会话") }
                default: break
                }
            }
        }
    }
    func perform(_ action: String, body: [String: JSONValue] = [:]) {
        guard online, let id = selectedID else { return }
        Task { do { try await self.action(id, action, body) } catch { actionError = error.localizedDescription } }
    }
    func action(_ id: String, _ action: String, _ body: [String: JSONValue] = [:]) async throws {
        let _: JSONValue = try await request("/sessions/\(id)/\(action)", body: .object(body))
        if action == "delete" {
            if selectedID == id { conversation.select(nil) }
            drafts.removeValue(forKey: id); attachments.removeValue(forKey: id)
        }
        // A successful mutation stays successful if only the following read fails.
        do { try await refresh() } catch { self.actionError = "操作已受理，同步失败：\(error.localizedDescription)" }
    }
    func setArchived(_ id: String, archived: Bool) async throws {
        let _: JSONValue = try await request("/sessions/\(id)/archive", body: .object(["archived": .bool(archived)]))
    }
}
