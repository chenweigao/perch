import Foundation
import Combine
import WorkbenchCore

@MainActor
final class NativeAgentConnection: ObservableObject {
    let host: SSHHost
    @Published private(set) var sessions: [NativeAgentSession] = []
    @Published private(set) var snapshot: NativeAgentSnapshot?
    @Published private(set) var selectedID: String?
    @Published private(set) var online = false
    @Published var error: String?
    @Published var actionError: String?
    @Published var drafts: [String: String] = [:]
    @Published private var sendingSessions: Set<String> = []
    var sending: Bool { selectedID.map { sendingSessions.contains($0) } ?? false }
    @Published var queue = OutboundQueue()
    @Published var stops = StopController()
    /// The runtime's own catalog, read once per connection. Only OMP answers
    /// `omp models`, so a Qoder session keeps an empty list rather than being
    /// offered models it cannot switch to.
    @Published private(set) var models: [AgentModel] = []
    /// The hosted bridge rejects `prompt` while a turn runs, so this adapter may only
    /// offer next-turn queueing. Steering stays unsupported until the bridge itself
    /// forwards a verified mid-turn command.
    let capabilities = AgentCapabilities(nativeConversation: true, stop: true, steer: .unsupported,
                                         queueWhileBusy: true, resume: true)
    var onSessionsChanged: (() -> Void)?
    private var api: KimiAPI?
    private var tunnel: Process?
    private var directory: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let requestTransport: ((String, JSONValue?) async throws -> Data)?
    init(host: SSHHost) { self.host = host; requestTransport = nil }
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
                        if let id = selectedID {
                            let suffix = snapshot?.id == id ? "?revision=\(snapshot!.revision)" : ""
                            let value: JSONValue = try await request("/sessions/\(id)\(suffix)")
                            if id == selectedID && value["unchanged"] != .bool(true) {
                                snapshot = try KimiWire.decoder().decode(NativeAgentSnapshot.self, from: JSONEncoder().encode(value))
                            }
                        }
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
    func disconnect() { generation = UUID(); task?.cancel(); task = nil; online = false; closeTunnel() }
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
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        if let error = value["error"].string, value["id"].string == nil { throw WorkbenchError(error) }
        return try KimiWire.decoder().decode(T.self, from: data)
    }
    func refresh() async throws {
        struct Catalog: Decodable { let sessions: [NativeAgentSession] }
        let value: Catalog = try await request("/sessions")
        let next = value.sessions.sorted { $0.updated > $1.updated }
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
    }
    func create(provider: SessionKind, cwd: String, model: String) async throws -> NativeAgentSession {
        let session: NativeAgentSession = try await request("/sessions", body: .object(["provider": .string(provider.rawValue), "cwd": .string(cwd), "model": .string(model)]))
        try await refresh(); select(session.id); return session
    }
    func loadModels() async {
        guard models.isEmpty else { return }
        do {
            let value: JSONValue = try await request("/models")
            models = ModelSelectionCatalog.parseOMP(value["models"])
        } catch { actionError = error.localizedDescription }
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
        capabilities.modes(isStreaming: sessions.first { $0.id == id }?.busy ?? false)
    }
    /// Queues the draft and hands it to the runtime when the session is free. The
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
        Task {
            defer { sendingSessions.remove(id); drainQueues() }
            do {
                let receipt: NativeRequestReceipt = try await request("/sessions/\(id)/prompt", body: .object([
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
        case "completed", "stopped": queue.markDelivered(receipt.id); return
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
        for session in sessions where !session.busy && pending.contains(session.id) { deliver(session.id) }
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
        drafts[id] = ""
        Task {
            do { try await action(id, "command", ["name": .string(command.name)]) }
            catch {
                // The draft is restored so the text is not lost when the command is
                // refused, which is the common case for a session with no history.
                if (drafts[id] ?? "").isEmpty { drafts[id] = draft }
                actionError = error.localizedDescription
            }
        }
    }
    /// Requests a stop for the session that was on screen. The phase stays short of
    /// "stopped" until the bridge reports the runtime's own terminal state.
    func stop() {
        guard online, let id = selectedID, let reference = reference(id),
              let session = sessions.first(where: { $0.id == id }), session.busy,
              let turn = session.turnId, let attempt = stops.request(reference, turn: turn) else { return }
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
