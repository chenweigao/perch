import Foundation
import UniformTypeIdentifiers
import WorkbenchCore

@MainActor
final class KimiConnection: ObservableObject {
    private(set) var host: SSHHost
    var onSessionsChanged: (() -> Void)?
    var port: Int { host.kimiPort }
    @Published private(set) var sessions: [KimiSession] = []
    @Published private(set) var selectedId: String?
    @Published private(set) var conversation: KimiConversation?
    @Published private(set) var timings = ConversationTimings()
    @Published private(set) var online = false
    @Published private(set) var connecting = false
    @Published private var stateMessage: String.LocalizationValue = "未连接"
    var state: String { L(stateMessage) }
    func state(locale: Locale) -> String { L(stateMessage, locale: locale) }
    @Published var error: String?
    @Published var actionError: String?
    @Published private(set) var commandFeedback: [String: String] = [:]
    @Published private(set) var commandErrors: [String: String] = [:]
    @Published var models: [JSONValue] = []
    @Published private(set) var modelsError: String?
    @Published var modelChoices: [String: String] = [:]
    @Published var thinkingChoices: [String: ThinkingLevel] = [:]
    /// Effort levels come from each model's own support_efforts, so a model with
    /// no declared levels does not imply that it cannot reason.
    var catalog: [AgentModel] { ModelSelectionCatalog.parseKimi(models) }
    @Published var permissionChoices: [String: String] = [:]
    func permissionCapability(for id: String) -> PermissionCapability {
        PermissionCatalog.capability(for: .kimi, selected: permissionMode(for: id))
    }
    func setPermission(_ mode: String, for id: String) {
        guard PermissionCatalog.isValid(mode, for: .kimi) else { return }
        permissionChoices[id] = mode
    }
    private func permissionMode(for id: String) -> String? {
        if let selected = permissionChoices[id] { return selected }
        let reported = conversation?.snapshot.session.id == id
            ? conversation?.snapshot.session.agentConfig["permission_mode"].string
            : sessions.first { $0.id == id }?.agentConfig["permission_mode"].string
        guard let reported, PermissionCatalog.isValid(reported, for: .kimi) else { return nil }
        return reported
    }
    @Published var drafts: [String: String] = [:] { didSet { persistDrafts() } }
    @Published private(set) var pendingPrompts: [String: [KimiPrompt]] = [:]
    @Published var attachments: [String: [URL]] = [:] { didSet { persistDrafts() } }
    @Published private(set) var aborting: Set<String> = []
    @Published private(set) var loadingTaskOutput: Set<String> = []
    @Published private(set) var stoppingTasks: Set<String> = []
    /// The task list is auxiliary information. A failed read stays in its own
    /// panel instead of presenting itself as a session error.
    @Published private(set) var taskListError: String?
    /// One subagent transcript at a time: the sheet that reads it owns the
    /// subscription, and closing it unsubscribes that agent again.
    @Published private(set) var subagentTranscript: KimiSubagentTranscript?
    @Published private(set) var subagentTranscriptError: String?
    @Published private(set) var loadingSubagentTranscript = false
    @Published private(set) var loadingOlderSubagentTurns = false
    @Published private var sendingSessions: Set<String> = []
    var sending: Bool { selectedId.map { sendingSessions.contains($0) } ?? false }
    @Published var loading = false
    @Published private(set) var snapshotReady = false
    @Published var loadingOlder = false
    @Published var resolving = Set<String>()
    private(set) var api: KimiAPI?
    private var cachedConversations = KimiConversationCache()
    private var socket: URLSessionWebSocketTask?
    private var tunnel: Process?
    private var folder: URL?
    private var task: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var listRefresh: Task<Void, Never>?
    private var taskRefresh: Task<Void, Never>?
    private var archivingBatch = false
    func beginArchiveBatch() { archivingBatch = true; listRefresh?.cancel() }
    func endArchiveBatch() { archivingBatch = false }
    private var generation = UUID()
    private var selectionGeneration = UUID()
    private var subscribedId: String?
    private var savedSelectionKey: String { "kimi.session.\(host.id)" }

    private var draftFile: DraftFile?
    private var draftLoadError: String?
    @Published private(set) var draftSaveError: String?
    private var savedDrafts: SavedDrafts { SavedDrafts(text: drafts, attachments: attachments) }
    private func loadDrafts() {
        let file = DraftFile.applicationFile(namespace: "kimi-\(host.id)")
        do {
            let saved = try file.load()
            drafts = saved.text
            attachments = saved.attachments
            draftFile = file
        } catch { draftLoadError = error.localizedDescription; draftSaveError = "Draft recovery failed; the original file was preserved: \(error.localizedDescription)" }
    }
    private func persistDrafts() {
        draftFile?.save(savedDrafts) { [weak self] error in
            Task { @MainActor in self?.draftSaveError = error.map { "Drafts could not be saved: " + $0 } }
        }
    }
    func flushDrafts() throws {
        if let draftLoadError { throw WorkbenchError(draftLoadError) }
        try draftFile?.flush(savedDrafts)
    }

    init(host: SSHHost) { self.host = host; selectedId = UserDefaults.standard.string(forKey: savedSelectionKey); loadDrafts() }

    /// Setup never restores drafts, selection or an existing conversation.
    init(setupHost: SSHHost) { self.host = setupHost }

    /// Isolated connection checks use a local HTTP fixture without SSH.
    init(host: SSHHost, api: KimiAPI) { self.host = host; self.api = api; online = true }

    func refreshModels() async {
        guard online, let api else { return }
        do {
            let catalog = try await api.get(JSONValue.self, "/api/v1/models")
            guard self.api === api else { return }
            models = catalog["items"].array; modelsError = nil
        } catch {
            guard self.api === api else { return }
            modelsError = error.localizedDescription
        }
    }

    func updateHost(_ value: SSHHost) {
        if value.kimiPort != host.kimiPort || value.kimiTokenPath != host.kimiTokenPath || value.destination != host.destination { disconnect() }
        host = value
    }

    func connect() {
        guard host.isLocal || !host.destination.isEmpty else { return }
        disconnect()
        let token = UUID(); generation = token; connecting = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            var delay = 1
            while !Task.isCancelled && generation == token {
                do {
                    stateMessage = "连接 Kimi Web"
                    try await establish(token: token)
                    guard let api else { throw CancellationError() }
                    let catalog = try await api.get(JSONValue.self, "/api/v1/models")
                    models = catalog["items"].array
                    try await refreshSessions()
                    let ws = try api.webSocket(); socket = ws; ws.resume()
                    let (hello, _) = try await receive(ws)
                    guard hello.type == "server_hello", hello.payload["protocol_version"].int == 2 else {
                        throw WorkbenchError("此 Kimi Web 的事件协议尚未支持")
                    }
                    try await sendFrame(ws, type: "client_hello", payload: ["client_id": .string("agent-workbench")])
                    online = true; stateMessage = "已连接"; error = nil; delay = 1
                    if let id = selectedId, sessions.contains(where: { $0.id == id }) {
                        do {
                            try await refreshConversation(selectionToken: selectionGeneration)
                            try await subscribe(id)
                        } catch is CancellationError { if Task.isCancelled { throw CancellationError() } }
                        await refreshTasks()
                        // A reconnect drops every subscription, including an open
                        // subagent transcript, so read and subscribe it again.
                        if let agentId = subagentTranscript?.agentId { await openSubagentTranscript(agentId) }
                    }
                    onSessionsChanged?()
                    let heartbeat = Task {
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(for: .seconds(20))
                                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                                    ws.sendPing { error in if let error { c.resume(throwing: error) } else { c.resume() } }
                                }
                            } catch { ws.cancel(with: .goingAway, reason: nil); return }
                        }
                    }
                    let poll = Task { [weak self] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(30)); try await self?.refreshSessions() }
                            catch { return }
                        }
                    }
                    defer { heartbeat.cancel(); poll.cancel(); ws.cancel(with: .goingAway, reason: nil) }
                    while !Task.isCancelled && generation == token {
                        let (event, data) = try await receive(ws)
                        do { try await handle(event, data: data) }
                        catch is CancellationError { if Task.isCancelled { throw CancellationError() } }
                    }
                } catch is CancellationError { break }
                catch {
                    guard generation == token else { break }
                    snapshotReady = false
                    online = false; self.error = error.localizedDescription; stateMessage = "\(delay) 秒后重连"
                    closeTransport()
                    do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    func disconnect() {
        generation = UUID(); selectionGeneration = UUID()
        task?.cancel(); task = nil; selectionTask?.cancel(); listRefresh?.cancel(); taskRefresh?.cancel()
        historyTask?.cancel(); historyTask = nil; loadingOlder = false; loading = false
        snapshotReady = false
        subagentTranscript = nil; subagentTranscriptError = nil
        closeTransport(); online = false; connecting = false; error = nil; stateMessage = "未连接"
    }
    private func closeTransport() {
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; subscribedId = nil
        api?.invalidate(); api = nil
        if let tunnel, tunnel.isRunning { tunnel.terminate() }; tunnel = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil
    }
    private func establish(token: UUID) async throws {
        if host.isLocal {
            let data = try await LocalAgentRuntime.endpoint(for: .kimi, host: host)
            try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
            let endpoint = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let port = endpoint["port"].int, let secret = endpoint["token"].string else {
                throw WorkbenchError(L("本机服务未返回连接信息"))
            }
            api = KimiAPI(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: secret)
            return
        }
        try SSHCommand.validateDestination(host.destination)
        // Read this server's existing credential through SSH; keep it only in process memory.
        let data = try await SetupCommandRunner.run("/usr/bin/ssh", RemoteSetup.sshArguments(host.destination,
            command: "cat " + RemoteSetup.remotePath(host.kimiTokenPath)))
        try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
        let secret = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw WorkbenchError("远端 Kimi Web 凭证为空") }
        let localPort = try KimiAPI.availableLoopbackPort()
        let directory = URL(fileURLWithPath: "/tmp/awb-kimi-\(UUID().uuidString.prefix(10))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        folder = directory
        let control = directory.appendingPathComponent("ssh").path
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-N", "-T", "-M", "-S", control, "-o", "ControlPersist=no", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-L", "127.0.0.1:\(localPort):127.0.0.1:\(port)", host.destination]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); process.standardError = errors; tunnel = process; try process.run()
        for _ in 0..<150 {
            try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
            if !process.isRunning { throw WorkbenchError(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
            if FileManager.default.fileExists(atPath: control) {
                let client = KimiAPI(baseURL: URL(string: "http://127.0.0.1:\(localPort)")!, token: secret)
                api = client
                _ = try await client.get(JSONValue.self, "/api/v1/meta")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WorkbenchError("Kimi SSH 转发建立超时")
    }

    func refreshSessions() async throws {
        guard let api else { throw WorkbenchError("请先连接 Kimi Web") }
        let token = generation
        var all: [KimiSession] = []; var before: String?
        repeat {
            let path = "/api/v1/sessions?page_size=100&include_archive=true" + (before.map { "&before_id=\($0)" } ?? "")
            let page = try await api.get(KimiPage<KimiSession>.self, path)
            all.append(contentsOf: page.items)
            before = page.hasMore ? page.items.last?.id : nil
        } while before != nil
        guard token == generation else { throw CancellationError() }
        var clocks = timings
        for session in all {
            clocks.observe(sessionID: session.id, running: session.busy,
                           waiting: ["approval", "question"].contains(session.pendingInteraction ?? ""))
        }
        if clocks != timings { timings = clocks }
        if sessions != all { sessions = all; onSessionsChanged?() }
    }
    func select(_ id: String) {
        guard id != selectedId || (!snapshotReady && !loading) else { return }
        if let conversation { cachedConversations.store(conversation) }
        // Unsubscribe while the previous session is still the selected one.
        closeSubagentTranscript()
        selectedId = id; UserDefaults.standard.set(id, forKey: savedSelectionKey)
        conversation = cachedConversations.take(id)
        loadSelected(id)
    }
    /// Messages of a session opened this launch, for local name suggestions.
    func loadedMessages(for id: String) -> [KimiMessage]? {
        let loaded = conversation?.snapshot.session.id == id ? conversation : cachedConversations.value(id)
        return loaded?.hasOlder == false ? loaded?.messages : nil
    }
    func reloadSelected() {
        guard online, !loading, let id = selectedId else { return }
        loadSelected(id)
    }
    private func loadSelected(_ id: String) {
        selectionGeneration = UUID(); let token = selectionGeneration
        historyTask?.cancel(); historyTask = nil; loadingOlder = false
        snapshotReady = false; loading = true; actionError = nil; taskListError = nil
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do { try await refreshConversation(selectionToken: token); try await subscribe(id) }
            catch is CancellationError {} catch { if token == selectionGeneration { actionError = error.localizedDescription } }
            await refreshTasks(selectionToken: token)
            if token == selectionGeneration { loading = false }
        }
    }
    private func refreshConversation(selectionToken: UUID) async throws {
        guard let api, let id = selectedId else { return }
        let value = try await api.get(KimiSnapshot.self, "/api/v1/sessions/\(id)/snapshot")
        try Task.checkCancellation()
        guard selectionToken == selectionGeneration, id == selectedId else { throw CancellationError() }
        let prompts = try await api.get(KimiPromptQueue.self, "/api/v1/sessions/\(id)/prompts")
        guard selectionToken == selectionGeneration, id == selectedId else { throw CancellationError() }
        // The snapshot's message page is only the trailing window. The conversation
        // retains older pages it has seen, and both are needed to recognise a prompt's
        // user message after a long turn pushed it out of the window.
        let retained = conversation?.snapshot.session.id == id ? conversation?.messages ?? [] : []
        pendingPrompts[id] = KimiPrompt.reconcile(local: pendingPrompts[id] ?? [],
                                                remote: prompts.queued + (prompts.active.map { [$0] } ?? []),
                                                messages: retained + value.messages.items,
                                                settled: !value.session.busy)
        if let current = conversation, value.epoch == current.snapshot.epoch, value.asOfSeq < current.lastSeq {
            // Keep newer events from this same server epoch, but settle the read.
            // Otherwise a refresh can leave the cached conversation unsendable.
            snapshotReady = true; loading = false
            return
        }
        if conversation != nil { conversation?.reconcile(value) } else { conversation = KimiConversation(value) }
        timings.observe(sessionID: id, turnID: value.inFlightTurn.map { String($0.turnId) },
                        requestID: value.inFlightTurn?.currentPromptId, running: value.session.busy,
                        waiting: !value.pendingApprovals.isEmpty || !value.pendingQuestions.isEmpty)
        // Catalog observers may select another session synchronously. Publish this
        // snapshot's state before notifying them, never after their new selection.
        snapshotReady = true; loading = false
        if let i = sessions.firstIndex(where: { $0.id == id }), sessions[i] != value.session {
            sessions[i] = value.session; onSessionsChanged?()
        }
    }
    private func subscribe(_ id: String) async throws {
        guard let socket, selectedId == id, let conversation else { return }
        if let old = subscribedId, old != id { try await sendFrame(socket, type: "unsubscribe", payload: ["session_ids": .array([.string(old)])]) }
        guard selectedId == id else { return }
        subscribedId = id
        try await sendFrame(socket, type: "subscribe", payload: [
            "session_ids": .array([.string(id)]),
            "cursors": .object([id: .object(["seq": .number(Double(conversation.lastSeq)), "epoch": .string(conversation.snapshot.epoch)])]),
            "agent_filter": .object([id: .array([.string("main")])])
        ])
    }
    private func handle(_ event: KimiEvent, data: Data) async throws {
        // Transcript frames belong to the open subagent sheet; they never enter
        // the main conversation fold.
        if event.type.hasPrefix("transcript.") {
            applyTranscript(event, data: data)
            return
        }
        if event.type == "error", event.sessionId == nil {
            actionError = event.payload["msg"].string ?? "Kimi 事件通道出错"
            if event.payload["fatal"] == .bool(true) { throw WorkbenchError(actionError!) }
            return
        }
        if event.type == "ack", let code = event.payload["code"].int, code != 0 { throw WorkbenchError(event.payload["msg"].string ?? "Kimi 订阅失败") }
        if event.type == "ping", let socket { try await sendFrame(socket, type: "pong", payload: [:]); return }
        if ["session.meta.updated", "event.session.created", "event.session.archived", "event.session.work_changed", "event.session.status_changed"].contains(event.type),
           !(archivingBatch && event.type == "event.session.archived") {
            listRefresh?.cancel()
            listRefresh = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)); try await self?.refreshSessions() } catch {}
            }
        }
        if event.type == "resync_required", event.payload["session_id"].string == selectedId {
            try await refreshConversation(selectionToken: selectionGeneration)
            if let id = selectedId { try await subscribe(id) }
            return
        }
        guard event.sessionId == selectedId, conversation != nil else { return }
        if KimiTaskBoard.changesTaskList(event.type) { scheduleTaskRefresh() }
        let needsSnapshot = conversation!.apply(event)
        if needsSnapshot {
            try await refreshConversation(selectionToken: selectionGeneration)
            if event.volatile == true, let id = selectedId { try await subscribe(id) }
        }
    }
    /// The raw frame stays available: a transcript delivery is decoded into its
    /// own typed payload from the same bytes.
    private func receive(_ ws: URLSessionWebSocketTask) async throws -> (KimiEvent, Data) {
        let message = try await ws.receive()
        let data: Data
        switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: throw WorkbenchError("未知 WebSocket 消息") }
        return (try KimiWire.decodeEvent(from: data), data)
    }
    private func sendFrame(_ ws: URLSessionWebSocketTask, type: String, payload: [String: JSONValue]) async throws {
        let frame = JSONValue.object(["type": .string(type), "id": .string(UUID().uuidString), "payload": .object(payload)])
        try await ws.send(.string(String(decoding: JSONEncoder().encode(frame), as: UTF8.self)))
    }

    func loadOlder() { loadHistory(all: false) }
    func loadAllHistoryForSearch() { loadHistory(all: true) }
    private func loadHistory(all: Bool) {
        guard online, snapshotReady, !loadingOlder, let api, let id = selectedId, conversation?.hasOlder == true else { return }
        let token = selectionGeneration; loadingOlder = true
        historyTask = Task {
            defer { if token == selectionGeneration { loadingOlder = false; historyTask = nil } }
            do {
                while token == selectionGeneration, conversation?.hasOlder == true, let first = conversation?.messages.first {
                    let page = try await api.get(KimiPage<KimiMessage>.self, "/api/v1/sessions/\(id)/messages?page_size=100&before_id=\(first.id)")
                    try Task.checkCancellation()
                    guard token == selectionGeneration else { return }
                    conversation?.prepend(page)
                    if !all || page.items.isEmpty { break }
                }
            } catch is CancellationError {} catch {
                if token == selectionGeneration { actionError = error.localizedDescription }
            }
        }
    }
    /// Reads the persisted task list of the selected session. Subagent lifecycle
    /// events keep the roster current locally; this list is the only source for
    /// background processes and detached children.
    func refreshTasks(selectionToken: UUID? = nil) async {
        let token = selectionToken ?? selectionGeneration
        guard token == selectionGeneration, online, let api, let id = selectedId, conversation != nil else { return }
        do {
            let list = try await api.get(KimiTaskList.self, "/api/v1/sessions/\(id)/tasks")
            guard token == selectionGeneration, id == selectedId else { return }
            conversation?.tasks.reconcile(background: list.items)
            taskListError = nil
        } catch is CancellationError {
        } catch {
            if token == selectionGeneration, id == selectedId { taskListError = error.localizedDescription }
        }
    }
    private func scheduleTaskRefresh() {
        taskRefresh?.cancel()
        taskRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)); await self?.refreshTasks() } catch {}
        }
    }
    /// Reads a tail on demand. An empty result is stored too, so expanding the
    /// row again does not re-read a task that has produced nothing yet.
    func loadTaskOutput(_ task: KimiTask) {
        guard online, let api, let id = selectedId, !loadingTaskOutput.contains(task.id) else { return }
        loadingTaskOutput.insert(task.id)
        Task { [weak self] in
            guard let self else { return }
            defer { loadingTaskOutput.remove(task.id) }
            do {
                let value = try await api.get(KimiTask.self, "/api/v1/sessions/\(id)/tasks/\(task.id)?with_output=true&output_bytes=16384")
                guard id == selectedId else { return }
                conversation?.tasks.store(output: value.outputPreview ?? "", for: task.id)
            } catch {
                if id == selectedId { taskListError = error.localizedDescription }
            }
        }
    }
    /// Stops one background task. The task list, not this acknowledgement, decides
    /// when the row leaves its running state.
    func cancelTask(_ task: KimiTask) {
        guard online, let api, let id = selectedId, !stoppingTasks.contains(task.id) else { return }
        stoppingTasks.insert(task.id); taskListError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { stoppingTasks.remove(task.id) }
            do {
                let result = try await api.post(JSONValue.self, "/api/v1/sessions/\(id)/tasks/\(task.id):cancel")
                guard result["cancelled"] == .bool(true) else { throw WorkbenchError("服务端未确认停止") }
                await refreshTasks()
            } catch {
                if id == selectedId { taskListError = "停止未确认：" + error.localizedDescription }
            }
        }
    }
    /// Turn-granular pages; the transcript API accepts 1 to 100 turns.
    private static let transcriptPageSize = 20
    /// The block grade streams whole frames. The delta grade would add
    /// per-character appends, which this client does not fold.
    private static let transcriptGrade = "block"

    /// Reads one subagent's transcript, then subscribes to its operations from
    /// that page's watermark. Reading again refreshes both. Without an event
    /// channel the page stays readable and the reader can refresh it explicitly.
    func openSubagentTranscript(_ agentId: String) async {
        guard online, let api, let id = selectedId else { return }
        loadingSubagentTranscript = true; subagentTranscriptError = nil
        defer { loadingSubagentTranscript = false }
        do {
            let page = try await api.get(KimiTranscriptPage.self,
                                         "/api/v1/sessions/\(id)/transcript?agent_id=\(agentId)&page_size=\(Self.transcriptPageSize)")
            guard selectedId == id else { return }
            var transcript = KimiSubagentTranscript(agentId: agentId)
            transcript.load(page, prepend: false)
            subagentTranscript = transcript
            guard let socket else { return }
            var payload: [String: JSONValue] = ["session_id": .string(id),
                                                "transcript": .object([agentId: .string(Self.transcriptGrade)])]
            if let seq = page.seq { payload["transcript_since"] = .object([agentId: .number(Double(seq))]) }
            try await sendFrame(socket, type: "subscribe_v2", payload: payload)
        } catch is CancellationError {
        } catch {
            if selectedId == id { subagentTranscriptError = error.localizedDescription }
        }
    }
    func loadOlderSubagentTurns() async {
        guard online, let api, let id = selectedId, !loadingOlderSubagentTurns,
              let transcript = subagentTranscript, transcript.hasMoreOlder,
              let oldest = transcript.turns.first?.turnId else { return }
        loadingOlderSubagentTurns = true
        defer { loadingOlderSubagentTurns = false }
        do {
            let page = try await api.get(KimiTranscriptPage.self,
                                         "/api/v1/sessions/\(id)/transcript?agent_id=\(transcript.agentId)&page_size=\(Self.transcriptPageSize)&before_turn=\(oldest)")
            guard selectedId == id, subagentTranscript?.agentId == transcript.agentId else { return }
            var updated = subagentTranscript ?? transcript
            updated.load(page, prepend: true)
            subagentTranscript = updated
        } catch is CancellationError {
        } catch {
            if selectedId == id { subagentTranscriptError = error.localizedDescription }
        }
    }
    /// Closing the sheet releases the subscription; the child keeps running.
    func closeSubagentTranscript() {
        guard let transcript = subagentTranscript else { return }
        subagentTranscript = nil; subagentTranscriptError = nil
        guard let socket, let id = selectedId else { return }
        Task { [weak self] in
            try? await self?.sendFrame(socket, type: "unsubscribe_v2", payload: [
                "session_id": .string(id), "agent_ids": .array([.string(transcript.agentId)])
            ])
        }
    }
    private func applyTranscript(_ event: KimiEvent, data: Data) {
        guard event.sessionId == selectedId, let transcript = subagentTranscript else { return }
        do {
            var updated = transcript
            switch event.type {
            case "transcript.reset":
                let reset = try KimiWire.decodeTranscript(KimiTranscriptReset.self, from: data)
                guard reset.agentId == transcript.agentId else { return }
                updated.apply(reset)
            case "transcript.ops":
                let batch = try KimiWire.decodeTranscript(KimiTranscriptOpsBatch.self, from: data)
                guard batch.agentId == transcript.agentId else { return }
                updated.apply(batch)
            default: return
            }
            subagentTranscript = updated
        } catch {
            subagentTranscriptError = error.localizedDescription
        }
    }
    func setArchived(_ id: String, archived: Bool, refresh: Bool = true) async throws {
        guard online, let api else { throw WorkbenchError("请先连接 Kimi") }
        if archived {
            let current = try await api.get(KimiSession.self, "/api/v1/sessions/\(id)")
            guard !current.busy else { throw WorkbenchError("此会话正在运行，请完成或停止后再归档") }
            let result = try await api.post(JSONValue.self, "/api/v1/sessions/\(id):archive")
            guard result["archived"] == .bool(true) else { throw WorkbenchError("服务端未确认归档") }
        } else {
            let result = try await api.post(JSONValue.self, "/api/v2/sessions:restore", body: .object(["ids": .array([.string(id)])]))
            guard let item = result["results"].array.first(where: { $0["id"].string == id }), item["ok"] == .bool(true) else {
                throw WorkbenchError(result["results"].array.first?["error"]["message"].string ?? "恢复归档失败")
            }
        }
        if refresh {
            do { try await refreshSessions() }
            catch { actionError = "归档操作已受理，同步失败：\(error.localizedDescription)" }
        }
    }
    func deleteSession(_ id: String) async throws {
        guard online, let api else { throw WorkbenchError("请先连接 Kimi") }
        let current = try await api.get(KimiSession.self, "/api/v1/sessions/\(id)")
        guard !current.busy else { throw WorkbenchError("此会话正在运行，请完成或停止后再删除") }
        let result = try await api.post(JSONValue.self, "/api/v1/sessions/\(id):delete")
        guard result["deleted"] == .bool(true) else { throw WorkbenchError("服务端未确认删除") }
        cachedConversations.remove(id)
        drafts.removeValue(forKey: id); attachments.removeValue(forKey: id)
        permissionChoices.removeValue(forKey: id)
        if selectedId == id {
            selectionGeneration = UUID(); selectionTask?.cancel(); historyTask?.cancel(); historyTask = nil
            selectedId = nil; conversation = nil; loading = false; loadingOlder = false; snapshotReady = false
        }
        sessions.removeAll { $0.id == id }; onSessionsChanged?()
    }

    @discardableResult
    func createSession(title: String, cwd: String, initialPrompt: String? = nil, model: String? = nil,
                       permissionMode: String? = nil) async throws -> KimiSession {
        guard let api else { throw WorkbenchError("请先连接 Kimi Web") }
        if let permissionMode, !PermissionCatalog.isValid(permissionMode, for: .kimi) {
            throw WorkbenchError("Kimi 权限模式无效")
        }
        let initialPermission = permissionMode ?? PermissionDefaults.mode(for: .kimi)
        var body: [String: JSONValue] = ["metadata": .object(["cwd": .string(cwd)])]
        if !title.isEmpty { body["title"] = .string(title) }
        let session = try await api.post(KimiSession.self, "/api/v1/sessions", body: .object(body))
        if let initialPrompt { drafts[session.id] = initialPrompt }
        if let model { modelChoices[session.id] = model }
        if let initialPermission { permissionChoices[session.id] = initialPermission }
        sessions.insert(session, at: 0); onSessionsChanged?()
        select(session.id)
        return session
    }
    func sendPrompt(mode: DeliveryMode = .steer) {
        guard online, snapshotReady, !loading, !sending, let id = selectedId else { return }
        Task { await sendPrompt(for: id, mode: mode) }
    }
    /// A newly created session can accept a prompt before its display snapshot loads.
    /// Keep the destination fixed even when catalog updates restore another tab.
    func sendPrompt(for id: String, mode: DeliveryMode = .steer) async {
        guard online, let api else {
            actionError = "发送未确认，草稿已保留。请先连接 Kimi。"
            return
        }
        guard !sendingSessions.contains(id) else { return }
        var text = drafts[id] ?? ""
        var startingGoal = false
        let files = attachments[id] ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        commandErrors[id] = nil
        do {
            if let command = try KimiCommand.parse(text) {
                guard files.isEmpty else { throw WorkbenchError(L("Remove attachments before running a command.")) }
                let busy = conversation?.snapshot.session.id == id ? conversation?.snapshot.session.busy : sessions.first { $0.id == id }?.busy
                guard !command.requiresIdle || busy != true else { throw WorkbenchError(L("Wait for the current task to finish before running this command.")) }
                if case .goalStart = command {
                    let chosen = modelChoices[id] ?? ""
                    let current = conversation?.snapshot.session.id == id
                        ? conversation?.snapshot.session.model ?? "" : sessions.first { $0.id == id }?.model ?? ""
                    guard !chosen.isEmpty || !current.isEmpty else { throw WorkbenchError(L("Choose a model before starting a goal.")) }
                }
                sendingSessions.insert(id)
                if selectedId == id { actionError = nil }
                commandFeedback[id] = nil
                defer { sendingSessions.remove(id) }
                let submittedDraft = text
                if let objective = try await runCommand(command, for: id, api: api) {
                    // Goal creation and the starter prompt are separate Kimi APIs.
                    // Once created, retain only the objective on a failed send so
                    // retrying cannot accidentally create the same goal again.
                    if drafts[id] == submittedDraft { drafts[id] = objective }
                    text = objective
                    startingGoal = true
                } else {
                    if drafts[id] == submittedDraft { drafts[id] = "" }
                    return
                }
            }
        } catch {
            commandErrors[id] = error.localizedDescription
            if selectedId == id { actionError = error.localizedDescription }
            return
        }
        let promptID = "awb_\(UUID().uuidString)"
        let preview: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
            + files.map { .object(["type": .string("file"), "name": .string($0.lastPathComponent)]) }
        pendingPrompts[id, default: []].append(KimiPrompt(id: promptID, content: preview))
        let chosenModel = modelChoices[id]
        let permissionMode = permissionMode(for: id)
        // The server accepts an unrecognised thinking value without failing, so the
        // level is resolved against the target model before it is sent.
        let effort = activeModel(for: id)?.resolve(thinkingChoices[id])
        sendingSessions.insert(id)
        if selectedId == id { actionError = nil }
        defer { sendingSessions.remove(id) }
        do {
            var content: [JSONValue] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : [.object(["type": .string("text"), "text": .string(text)])]
            for file in files {
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let uploaded = try await api.upload(file, mediaType: mime)
                guard let fileId = uploaded["id"].string else { throw WorkbenchError("附件上传响应缺少文件标识") }
                if mime.hasPrefix("image/") {
                    content.append(.object(["type": .string("image"), "source": .object(["kind": .string("file"), "file_id": .string(fileId)]), "name": .string(file.lastPathComponent)]))
                } else {
                    content.append(.object(["type": .string("file"), "file_id": .string(fileId), "name": .string(file.lastPathComponent), "media_type": .string(mime), "size": uploaded["size"]]))
                }
            }
            var body: [String: JSONValue] = [
                "prompt_id": .string(promptID),
                "content": .array(content)
            ]
            if let model = chosenModel, !model.isEmpty { body["model"] = .string(model) }
            if let effort { body["thinking"] = .string(effort.rawValue) }
            if let permissionMode { body["permission_mode"] = .string(permissionMode) }
            timings.submitted(promptID)
            let accepted = try await api.post(KimiPrompt.self, "/api/v1/sessions/\(id)/prompts", body: .object(body))
            if startingGoal { commandFeedback[id] = L("Goal created. First message accepted.") }
            if let index = pendingPrompts[id]?.firstIndex(where: { $0.id == promptID }) {
                pendingPrompts[id]?[index] = accepted
            }
            if drafts[id] == text { drafts[id] = "" }
            attachments[id]?.removeAll { files.contains($0) }
            if mode == .steer && ["queued", "blocked"].contains(accepted.status) {
                await steerPrompt(promptID, for: id)
            }
        } catch {
            let message = "发送未确认，草稿已保留。请检查会话后再发送。\n" + error.localizedDescription
            if startingGoal { commandFeedback[id] = L("Goal created; the first message is unconfirmed. Check the conversation before sending again.") }
            updatePrompt(promptID, for: id, status: "unknown", error: message)
            if selectedId == id { actionError = message }
        }
    }
    private func runCommand(_ command: KimiCommand, for id: String, api: KimiAPI) async throws -> String? {
        let path = "/api/v1/sessions/\(id)"
        switch command {
        case .help:
            commandFeedback[id] = KimiCommand.helpText
        case .goalStatus:
            let goal = try await api.get(KimiGoal?.self, path + "/goal")
            if let goal {
                commandFeedback[id] = "\(goal.objective)\n\(goal.status) · \(goal.turnsUsed) turns · \(goal.tokensUsed) tokens"
            } else { commandFeedback[id] = L("No active goal.") }
        case .compact(let instructions):
            _ = try await api.post(JSONValue.self, path + ":compact", body: .object(["instruction": .string(instructions)]))
            commandFeedback[id] = L("Compaction requested. Watch the conversation for progress.")
        case .goalStart(let objective):
            _ = try await api.post(JSONValue.self, path + "/profile", body: .object(["agent_config": .object(["goal_objective": .string(objective)])]))
            commandFeedback[id] = L("Goal created. Sending the objective to start work.")
            return objective
        case .goalControl(let control):
            _ = try await api.post(JSONValue.self, path + "/profile", body: .object(["agent_config": .object(["goal_control": .string(control)])]))
            // The profile resume endpoint starts continuation itself. Do not send
            // a second prompt or change the user's existing permission mode.
            switch control {
            case "pause": commandFeedback[id] = L("Goal paused. An active turn can still finish; use Stop to interrupt it.")
            case "cancel": commandFeedback[id] = L("Goal removed. An active turn can still finish; use Stop to interrupt it.")
            default: commandFeedback[id] = L("Goal resume requested.")
            }
        case .plan(let enabled):
            _ = try await api.post(JSONValue.self, path + "/profile", body: .object(["agent_config": .object(["plan_mode": .bool(enabled)])]))
            commandFeedback[id] = enabled ? L("Plan mode enabled.") : L("Plan mode disabled.")
        }
        return nil
    }
    private func updatePrompt(_ promptID: String, for id: String, status: String, error: String? = nil) {
        guard let index = pendingPrompts[id]?.firstIndex(where: { $0.id == promptID }) else { return }
        pendingPrompts[id]?[index].status = status
        pendingPrompts[id]?[index].error = error
    }
    /// Only steers an already accepted id. Failure must never re-submit its text.
    func steerPrompt(_ promptID: String, for id: String) async {
        guard online, let api else { return }
        updatePrompt(promptID, for: id, status: "steering")
        do {
            _ = try await api.post(JSONValue.self, "/api/v1/sessions/\(id)/prompts/\(promptID):steer", body: .object([:]))
            updatePrompt(promptID, for: id, status: "steered")
        } catch {
            // The queued prompt may have started while the request was in flight.
            // Keep its accepted identity and re-read the queue/history, never replay.
            updatePrompt(promptID, for: id, status: "queued",
                         error: "引导未确认；消息已接收。" + error.localizedDescription)
        }
        if selectedId == id {
            do { try await refreshConversation(selectionToken: selectionGeneration) }
            catch { actionError = error.localizedDescription }
        }
    }
    /// The model the next prompt will actually use: the explicit choice if any,
    /// otherwise whatever the session is already configured with.
    func activeModel(for id: String) -> AgentModel? {
        let chosen = modelChoices[id] ?? ""
        let current = chosen.isEmpty ? (sessions.first { $0.id == id }?.model ?? "") : chosen
        return ModelSelectionCatalog.model(current, in: catalog)
    }
    var isStopping: Bool { selectedId.map { aborting.contains($0) } ?? false }
    var canStop: Bool {
        online && snapshotReady && !loading && !isStopping
            && conversation?.snapshot.session.busy == true
    }
    func abort() {
        guard canStop, let api, let id = selectedId else { return }
        aborting.insert(id); actionError = nil
        Task {
            defer { aborting.remove(id) }
            do { _ = try await api.post(JSONValue.self, "/api/v1/sessions/\(id):abort") }
            catch {
                if selectedId == id { actionError = "Stop request not confirmed: \(error.localizedDescription)" }
            }
            // The snapshot, not this HTTP acknowledgement, decides when the send
            // arrow returns. A still-busy session continues to offer Stop.
        }
    }
    func resolve(_ approval: KimiApproval, decision: String) {
        guard snapshotReady, !loading else { return }
        performInteraction(id: approval.id, path: "approvals/\(approval.id)", body: .object(["decision": .string(decision)]))
    }
    func answer(_ question: KimiQuestion, answers: [String: JSONValue]) {
        guard snapshotReady, !loading else { return }
        performInteraction(id: question.id, path: "questions/\(question.id)", body: .object(["answers": .object(answers), "method": .string("click")]))
    }
    private func performInteraction(id: String, path: String, body: JSONValue) {
        guard online, let api, let session = selectedId, !resolving.contains(id) else { return }
        resolving.insert(id); actionError = nil
        Task {
            defer { resolving.remove(id) }
            do {
                _ = try await api.post(JSONValue.self, "/api/v1/sessions/\(session)/\(path)", body: body)
                if selectedId == session { try await refreshConversation(selectionToken: selectionGeneration) }
            } catch { actionError = error.localizedDescription }
        }
    }
}
