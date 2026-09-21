import Foundation
import UniformTypeIdentifiers
import WorkbenchCore

@MainActor
final class KimiConnection: ObservableObject {
    let host: SSHHost
    var onSessionsChanged: (() -> Void)?
    let port = 58627
    @Published private(set) var sessions: [KimiSession] = []
    @Published private(set) var selectedId: String?
    @Published private(set) var conversation: KimiConversation?
    @Published private(set) var online = false
    @Published private(set) var connecting = false
    @Published private var stateMessage: String.LocalizationValue = "未连接"
    var state: String { L(stateMessage) }
    func state(locale: Locale) -> String { L(stateMessage, locale: locale) }
    @Published var error: String?
    @Published var actionError: String?
    @Published var models: [JSONValue] = []
    @Published var modelChoices: [String: String] = [:]
    @Published var thinkingChoices: [String: ThinkingLevel] = [:]
    /// Effort levels come from each model's own support_efforts, so a model with
    /// none genuinely has no effort control rather than a hidden default.
    var catalog: [AgentModel] { ModelSelectionCatalog.parseKimi(models) }
    @Published var manualPermissions: [String: Bool] = [:]
    @Published var drafts: [String: String] = [:] { didSet { persistDrafts() } }
    @Published var attachments: [String: [URL]] = [:] { didSet { persistDrafts() } }
    @Published private(set) var aborting: Set<String> = []
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
    private var listRefresh: Task<Void, Never>?
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

    /// Isolated connection checks use a local HTTP fixture without SSH.
    init(host: SSHHost, api: KimiAPI) { self.host = host; self.api = api; online = true }

    func connect() {
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
                    let ws = api.webSocket(); socket = ws; ws.resume()
                    let hello = try await receive(ws)
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
                        let event = try await receive(ws)
                        do { try await handle(event) }
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
        task?.cancel(); task = nil; selectionTask?.cancel(); listRefresh?.cancel()
        snapshotReady = false
        closeTransport(); online = false; connecting = false; stateMessage = "未连接"
    }
    private func closeTransport() {
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; subscribedId = nil
        api?.invalidate(); api = nil
        if let tunnel, tunnel.isRunning { tunnel.terminate() }; tunnel = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil
    }
    private func establish(token: UUID) async throws {
        try SSHCommand.validateDestination(host.destination)
        // Read this server's existing credential through SSH; keep it only in process memory.
        let data = try await ProcessRunner.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", host.destination, "cat ~/.kimi-code/server.token"])
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
        if sessions != all { sessions = all; onSessionsChanged?() }
    }
    func select(_ id: String) {
        guard id != selectedId || (conversation == nil && !loading) else { return }
        if let conversation { cachedConversations.store(conversation) }
        selectedId = id; UserDefaults.standard.set(id, forKey: savedSelectionKey)
        selectionGeneration = UUID(); let token = selectionGeneration
        conversation = cachedConversations.take(id); snapshotReady = false; loading = true; actionError = nil
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do { try await refreshConversation(selectionToken: token); try await subscribe(id) }
            catch is CancellationError {} catch { if token == selectionGeneration { actionError = error.localizedDescription } }
            if token == selectionGeneration { loading = false }
        }
    }
    func reloadSelected() {
        let token = selectionGeneration
        Task { do { try await refreshConversation(selectionToken: token) } catch { actionError = error.localizedDescription } }
    }
    private func refreshConversation(selectionToken: UUID) async throws {
        guard let api, let id = selectedId else { return }
        let value = try await api.get(KimiSnapshot.self, "/api/v1/sessions/\(id)/snapshot")
        guard selectionToken == selectionGeneration, id == selectedId else { throw CancellationError() }
        if let current = conversation, value.epoch == current.snapshot.epoch, value.asOfSeq < current.lastSeq { return }
        if conversation != nil { conversation?.reconcile(value) } else { conversation = KimiConversation(value) }
        if let i = sessions.firstIndex(where: { $0.id == id }), sessions[i] != value.session {
            sessions[i] = value.session; onSessionsChanged?()
        }
        snapshotReady = true; loading = false
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
    private func handle(_ event: KimiEvent) async throws {
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
        let needsSnapshot = conversation!.apply(event)
        if needsSnapshot {
            try await refreshConversation(selectionToken: selectionGeneration)
            if event.volatile == true, let id = selectedId { try await subscribe(id) }
        }
    }
    private func receive(_ ws: URLSessionWebSocketTask) async throws -> KimiEvent {
        let message = try await ws.receive()
        let data: Data
        switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: throw WorkbenchError("未知 WebSocket 消息") }
        // Control frames keep code/msg outside payload. Preserve them when decoding acknowledgements.
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        if raw["type"].string == "ack", let code = raw["code"].int, code != 0 { throw WorkbenchError(raw["msg"].string ?? "Kimi 控制请求失败") }
        return try KimiWire.decoder().decode(KimiEvent.self, from: data)
    }
    private func sendFrame(_ ws: URLSessionWebSocketTask, type: String, payload: [String: JSONValue]) async throws {
        let frame = JSONValue.object(["type": .string(type), "id": .string(UUID().uuidString), "payload": .object(payload)])
        try await ws.send(.string(String(decoding: JSONEncoder().encode(frame), as: UTF8.self)))
    }

    func loadOlder() {
        guard !loadingOlder, let api, let id = selectedId, let first = conversation?.messages.first, conversation?.hasOlder == true else { return }
        let token = selectionGeneration; loadingOlder = true
        Task {
            defer { loadingOlder = false }
            do {
                let page = try await api.get(KimiPage<KimiMessage>.self, "/api/v1/sessions/\(id)/messages?page_size=100&before_id=\(first.id)")
                if token == selectionGeneration { conversation?.prepend(page) }
            } catch { actionError = error.localizedDescription }
        }
    }
    func loadAllHistoryForSearch() {
        guard !loadingOlder, let api, let id = selectedId else { return }
        let token = selectionGeneration; loadingOlder = true
        Task {
            defer { loadingOlder = false }
            do {
                while token == selectionGeneration, conversation?.hasOlder == true, let first = conversation?.messages.first {
                    let page = try await api.get(KimiPage<KimiMessage>.self, "/api/v1/sessions/\(id)/messages?page_size=100&before_id=\(first.id)")
                    guard token == selectionGeneration else { return }
                    conversation?.prepend(page)
                    if page.items.isEmpty { break }
                }
            } catch { actionError = error.localizedDescription }
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
        if selectedId == id { selectionGeneration = UUID(); selectionTask?.cancel(); selectedId = nil; conversation = nil; loading = false }
        sessions.removeAll { $0.id == id }; onSessionsChanged?()
    }

    @discardableResult
    func createSession(title: String, cwd: String, initialPrompt: String? = nil, model: String? = nil) async throws -> KimiSession {
        guard let api else { throw WorkbenchError("请先连接 Kimi Web") }
        var body: [String: JSONValue] = ["metadata": .object(["cwd": .string(cwd)])]
        if !title.isEmpty { body["title"] = .string(title) }
        let session = try await api.post(KimiSession.self, "/api/v1/sessions", body: .object(body))
        if let initialPrompt { drafts[session.id] = initialPrompt }
        if let model { modelChoices[session.id] = model }
        sessions.insert(session, at: 0); onSessionsChanged?()
        select(session.id)
        return session
    }
    func sendPrompt() {
        guard online, snapshotReady, !loading, !sending, let id = selectedId else { return }
        Task { await sendPrompt(for: id) }
    }
    /// A newly created session can accept a prompt before its display snapshot loads.
    /// Keep the destination fixed even when catalog updates restore another tab.
    func sendPrompt(for id: String) async {
        guard online, let api else {
            actionError = "发送未确认，草稿已保留。请先连接 Kimi。"
            return
        }
        guard !sendingSessions.contains(id) else { return }
        let text = drafts[id] ?? ""
        let files = attachments[id] ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        let chosenModel = modelChoices[id]
        let manual = manualPermissions[id] == true
        // The server accepts an unrecognised thinking value without failing, so the
        // level is resolved against the target model before it is sent.
        let effort = activeModel(for: id)?.resolve(thinkingChoices[id])
        sendingSessions.insert(id); actionError = nil
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
                "prompt_id": .string("awb_\(UUID().uuidString)"),
                "content": .array(content)
            ]
            if let model = chosenModel, !model.isEmpty { body["model"] = .string(model) }
            if let effort { body["thinking"] = .string(effort.rawValue) }
            if manual { body["permission_mode"] = .string("manual") }
            _ = try await api.post(JSONValue.self, "/api/v1/sessions/\(id)/prompts", body: .object(body))
            if drafts[id] == text { drafts[id] = "" }
            attachments[id]?.removeAll { files.contains($0) }
        } catch { actionError = "发送未确认，草稿已保留。请检查会话后再发送。\n\(error.localizedDescription)" }
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
