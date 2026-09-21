import Foundation
import Combine
import WorkbenchCore

@MainActor
final class NativeAgentConnection: ObservableObject {
    let host: SSHHost
    @Published private(set) var sessions: [NativeAgentSession] = []
    @Published private(set) var snapshot: NativeAgentSnapshot?
    @Published private(set) var selectedID: String?
    @Published private(set) var timings = ConversationTimings()
    @Published private(set) var online = false
    @Published var error: String?
    @Published var actionError: String?
    @Published var drafts: [String: String] = [:] { didSet { persistDrafts() } }
    @Published private var sendingSessions: Set<String> = []
    var sending: Bool { selectedID.map { sendingSessions.contains($0) } ?? false }
    @Published var queue = OutboundQueue() { didSet { persistDrafts() } }
    @Published var stops = StopController()
    /// The bridge's combined catalog: OMP answers `omp models`, dsh contributes its
    /// ACP config options after each handshake, and a Qoder session keeps an empty
    /// list rather than being offered models it cannot switch to.
    @Published private(set) var models: [AgentModel] = []
    var onSessionsChanged: (() -> Void)?
    private var api: KimiAPI?
    private var tunnel: Process?
    private var directory: URL?
    private var task: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private var generation = UUID()
    private let requestTransport: ((String, JSONValue?) async throws -> Data)?
    private var draftFile: DraftFile?
    private var draftLoadError: String?
    @Published private(set) var draftSaveError: String?
    private var savedDrafts: SavedDrafts { SavedDrafts(text: drafts, outbox: queue) }
    private func loadDrafts() {
        let file = DraftFile.applicationFile(namespace: "native-\(host.id)")
        do {
            let saved = try file.load()
            drafts = saved.text
            queue = saved.outbox
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

    init(host: SSHHost) { self.host = host; requestTransport = nil; loadDrafts() }
    /// Used by the isolated connection contract checks; no SSH or App is started.
    init(host: SSHHost, transport: @escaping (String, JSONValue?) async throws -> Data) {
        self.host = host; requestTransport = transport; online = true
    }
    func connect() {
        disconnect(); let token = UUID(); generation = token
        task = Task {
            while !Task.isCancelled && generation == token {
                do {
                    try await establish(token)
                    online = true; error = nil; onSessionsChanged?()
                    while !Task.isCancelled && generation == token {
                        try await refresh()
                        if selectionTask == nil { try await refreshSelected() }
                        try await Task.sleep(for: .milliseconds(400))
                    }
                } catch is CancellationError { return }
                catch {
                    guard generation == token else { return }
                    online = false; self.error = error.localizedDescription; closeTunnel(); onSessionsChanged?()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
    }
    func disconnect() {
        generation = UUID(); selectionGeneration = UUID()
        task?.cancel(); task = nil; selectionTask?.cancel(); selectionTask = nil
        online = false; closeTunnel()
    }
    private func closeTunnel() {
        api?.invalidate(); api = nil
        if let tunnel, tunnel.isRunning { tunnel.terminate() }; tunnel = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
    }
    private func establish(_ token: UUID) async throws {
        try SSHCommand.validateDestination(host.destination)
        let data = try await ProcessRunner.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", host.destination, "python3 ~/.local/share/agent-workbench/native/native-agent-service.py --ensure"])
        try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
        let endpoint = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let port = endpoint["port"].int, let secret = endpoint["token"].string else { throw WorkbenchError("原生对话托管服务未安装或不可用") }
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
                let health: JSONValue = try await request("/health")
                guard health["version"].int == 2 else { throw WorkbenchError("请更新原生对话桥接服务后重新连接") }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WorkbenchError("原生对话 SSH 转发超时")
    }
    private func request<T: Decodable>(_ path: String, body: JSONValue? = nil) async throws -> T {
        let data: Data
        if let requestTransport { data = try await requestTransport(path, body) }
        else {
            guard let api else { throw WorkbenchError("请先连接原生对话服务") }
            data = try await api.request(path, method: body == nil ? "GET" : "POST", body: body)
        }
        return try NativeAgentWire.decode(T.self, from: data)
    }
    func refresh() async throws {
        struct Catalog: Decodable { let sessions: [NativeAgentSession] }
        let value: Catalog = try await request("/sessions")
        let next = value.sessions.sorted { $0.updated > $1.updated }
        var clocks = timings
        for session in next {
            clocks.observe(sessionID: session.id, turnID: session.turnId, requestID: session.turnId,
                           running: session.busy, waiting: session.pending > 0)
        }
        if clocks != timings { timings = clocks }
        if let id = selectedID, !next.contains(where: { $0.id == id }) { selectedID = nil; snapshot = nil }
        if next != sessions {
            sessions = next
            onSessionsChanged?()
        }
        reconcileStops()
        // Receipts, not catalog changes, settle pending sends after a reconnect.
        for message in queue.allItems where !sendingSessions.contains(message.session.terminalID) {
            guard next.contains(where: { $0.id == message.session.terminalID }) else { continue }
            switch message.state {
            case .submitting, .accepted, .running, .unknown:
                let receipt: NativeRequestReceipt = try await request("/sessions/\(message.session.terminalID)/requests/\(message.id)")
                apply(receipt)
            default: break
            }
        }
        drainQueues()
    }
    func select(_ id: String) {
        guard selectedID != id else { return }; selectedID = id; snapshot = nil; actionError = nil
        selectionTask?.cancel()
        selectionGeneration = UUID(); let token = selectionGeneration
        guard online else { selectionTask = nil; return }
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if selectionGeneration == token { selectionTask = nil } }
            do { try await refreshSelected() }
            catch is CancellationError {}
            catch { if selectionGeneration == token { actionError = error.localizedDescription } }
        }
    }
    private func refreshSelected() async throws {
        try Task.checkCancellation()
        guard let id = selectedID else { return }
        let token = selectionGeneration, connectionToken = generation
        let suffix = snapshot?.id == id ? "?revision=\(snapshot!.revision)" : ""
        let response: NativeSnapshotResponse = try await request("/sessions/\(id)\(suffix)")
        try Task.checkCancellation()
        guard token == selectionGeneration, connectionToken == generation, id == selectedID,
              let value = response.snapshot else { return }
        snapshot = value
    }
    func create(provider: SessionKind, cwd: String, model: String) async throws -> NativeAgentSession {
        let session: NativeAgentSession = try await request("/sessions", body: .object(["provider": .string(provider.rawValue), "cwd": .string(cwd), "model": .string(model)]))
        sessions.insert(session, at: 0); onSessionsChanged?(); select(session.id); return session
    }
    /// The catalog is re-read on every session switch because it is no longer
    /// static: a dsh session contributes its runtime's options only after the ACP
    /// handshake lands. Failures keep the last good list; an empty list is the only
    /// state worth an error message.
    func loadModels() async {
        do {
            let value: JSONValue = try await request("/models")
            let parsed = ModelSelectionCatalog.parseOMP(value["models"])
            if parsed != models { models = parsed }
        } catch { if models.isEmpty { actionError = error.localizedDescription } }
    }
    func model(for snapshot: NativeAgentSnapshot) -> AgentModel? {
        ModelSelectionCatalog.model(snapshot.model, in: models)
    }
    /// Switching models can leave the current effort unsupported, so the level is
    /// resolved against the target model and re-sent rather than carried over.
    func setModel(_ target: AgentModel, for id: String) {
        let current = ThinkingLevel.parse(sessions.first { $0.id == id }?.thinking)
        Task {
            do {
                try await action(id, "model", ["provider": .string(target.provider), "model": .string(target.id)])
                if let resolved = target.resolve(current), resolved != current { setThinking(resolved, for: id) }
            } catch { actionError = error.localizedDescription }
        }
    }
    func setThinking(_ level: ThinkingLevel, for id: String) {
        Task {
            do { try await action(id, "thinking", ["level": .string(level.rawValue)]) }
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
        guard online, let id = selectedID, let reference = reference(id),
              let text = drafts[id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A draft that names one of this session's commands runs that command; sending
        // it to the model would just produce a reply about the text "/compact".
        if let snapshot, snapshot.id == id, let commands = snapshot.commands,
           let invocation = SlashCommands.invocation(in: text, from: commands) {
            run(invocation.command, arguments: invocation.arguments, for: id, draft: text)
            return
        }
        guard queue.enqueue(text, for: reference, mode: mode) != nil else { return }
        drafts[id] = ""
        actionError = nil
        deliver(id)
    }
    private func deliver(_ id: String) {
        guard online, !sendingSessions.contains(id), let reference = reference(id) else { return }
        let busy = sessions.first { $0.id == id }?.busy ?? false
        guard queue.nextPendingID(for: reference, isStreaming: busy) != nil else { return }
        guard let message = queue.nextDelivery(for: reference, isStreaming: busy) else { return }
        sendingSessions.insert(id)
        timings.submitted(message.id)
        Task {
            defer { sendingSessions.remove(id); drainQueues() }
            do {
                let receipt: NativeRequestReceipt = try await request("/sessions/\(id)/\(message.mode == .steer ? "steer" : "prompt")", body: .object([
                    "text": .string(message.text), "requestId": .string(message.id)]))
                apply(receipt)
            } catch {
                queue.markUnknown(message.id, error.localizedDescription)
                actionError = error.localizedDescription
            }
        }
    }
    private func apply(_ receipt: NativeRequestReceipt) {
        guard let message = queue.message(receipt.id) else { return }
        let next: OutboundState
        switch receipt.status {
        case "submitting", "submitted": next = .submitting
        case "accepted": next = .accepted
        case "running": next = .running
        case "consumed":
            // Keep the local bubble until the corresponding history is on screen.
            if snapshot?.id != message.session.terminalID || snapshot?.messages.contains(where: { $0.id == receipt.id }) == true {
                queue.markDelivered(receipt.id)
            } else { queue.markAccepted(receipt.id) }
            return
        case "completed", "stopped":
            timings.finished(sessionID: message.session.terminalID, requestID: receipt.id)
            queue.markDelivered(receipt.id); return
        case "failed": next = .failed(receipt.error ?? "运行时拒绝消息")
        case "notFound": next = .failed("服务端没有受理记录，可移回草稿后发送")
        default: next = .unknown(receipt.error ?? "请同步并核对会话，暂勿重复提交")
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
        drainQueues()
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
            guard let reference = reference(session.id), let attempt = stops.attempt(for: reference) else { continue }
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
        if action == "delete", selectedID == id { selectedID = nil; snapshot = nil }
        // A successful mutation stays successful if only the following read fails.
        do { try await refresh() } catch { self.actionError = "操作已受理，同步失败：\(error.localizedDescription)" }
    }
    func setArchived(_ id: String, archived: Bool) async throws {
        let _: JSONValue = try await request("/sessions/\(id)/archive", body: .object(["archived": .bool(archived)]))
    }
}
