import Foundation
import WorkbenchCore

/// Hold only the requests involved in a session switch; no SSH or real history.
private final class SelectionProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var held: Set<String> = []
    private static var failed: Set<String> = []
    private static var pending: [String: SelectionProtocol] = [:]
    private static var counts: [String: Int] = [:]
    private static var sequence = 10
    private var stopped = false

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        held = []; failed = []; pending = [:]; counts = [:]; sequence = 10
    }
    static func setSequence(_ value: Int) { lock.lock(); defer { lock.unlock() }; sequence = value }
    static func hold(_ path: String) { lock.lock(); defer { lock.unlock() }; held.insert(path) }
    static func fail(_ path: String, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if value { failed.insert(path) } else { failed.remove(path) }
    }
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
    static func release(_ path: String) {
        lock.lock(); held.remove(path); let request = pending.removeValue(forKey: path); lock.unlock()
        request?.respond()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        Self.counts[path, default: 0] += 1
        let hold = Self.held.contains(path)
        if hold { Self.pending[path] = self }
        Self.lock.unlock()
        if !hold { respond() }
    }
    private func respond() {
        let path = request.url!.path
        Self.lock.lock(); let cancelled = stopped; let fail = Self.failed.contains(path); let sequence = Self.sequence; Self.lock.unlock()
        guard !cancelled else { return }
        func session(_ id: String, _ updated: String) -> [String: Any] {
            ["id": id, "title": id, "updated_at": updated, "busy": false,
             "metadata": ["cwd": "/fixture"], "agent_config": ["model": "fixture/model"]]
        }
        func message(_ id: String) -> [String: Any] {
            ["id": id, "role": "user", "created_at": "1", "content": [["type": "text", "text": id]]]
        }
        let result: [String: Any]
        if path == "/api/v1/sessions" {
            result = ["items": [session("a", "catalog"), session("b", "catalog")], "has_more": false]
        } else {
            let id = String(path.split(separator: "/")[3])
            if path.hasSuffix("/snapshot") {
                result = ["as_of_seq": sequence, "epoch": "fixture", "session": session(id, "snapshot"),
                          "messages": ["items": [message(id + "-latest")], "has_more": true],
                          "pending_approvals": [], "pending_questions": []]
            } else if path.hasSuffix("/prompts") {
                result = ["active": NSNull(), "queued": []]
            } else if path.hasSuffix("/messages") {
                result = ["items": [message(id + "-older")], "has_more": false]
            } else { preconditionFailure("Unexpected selection fixture route: \(path)") }
        }
        let envelope: [String: Any] = fail ? ["msg": "fixture unavailable"] : ["code": 0, "data": result]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fail ? 503 : 200,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: envelope))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private func selectionClient() -> KimiConnection {
    SelectionProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SelectionProtocol.self]
    return KimiConnection(host: SSHHost(name: "Selection fixture", destination: "fixture"),
                          api: KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: configuration))
}

@MainActor
func checkKimiSelectionIsolation() async throws {
    var failures: [String] = []
    for scenario in ["catalog callback", "cached retry", "manual refresh", "older snapshot", "older history", "full history", "send failure", "disconnect"] {
        let client = selectionClient()
        defer {
            client.disconnect()
            UserDefaults.standard.removeObject(forKey: "kimi.session.\(client.host.id)")
        }
        do {
            switch scenario {
            case "catalog callback":
                try await client.refreshSessions()
                SelectionProtocol.hold("/api/v1/sessions/b/snapshot")
                client.onSessionsChanged = { [weak client] in
                    if client?.selectedId == "a" { client?.select("b") }
                }
                client.select("a")
                await ConnectionChecks.settle { SelectionProtocol.count("/api/v1/sessions/b/snapshot") == 1 }
                let isolated = client.selectedId == "b" && client.conversation == nil && client.loading && !client.snapshotReady
                SelectionProtocol.release("/api/v1/sessions/b/snapshot")
                await ConnectionChecks.settle { client.conversation?.snapshot.session.id == "b" && !client.loading }
                guard isolated else { throw WorkbenchError("A snapshot marked pending B as loaded after the catalog callback switched sessions") }
            case "cached retry":
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                client.select("b")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                SelectionProtocol.fail("/api/v1/sessions/a/snapshot", true)
                client.select("a")
                await ConnectionChecks.settle { !client.loading }
                precondition(client.conversation?.snapshot.session.id == "a" && !client.snapshotReady && client.actionError != nil)
                SelectionProtocol.fail("/api/v1/sessions/a/snapshot", false)
                client.select("a")
                guard client.loading else { throw WorkbenchError("Cached conversation prevents retrying its failed snapshot") }
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                precondition(client.actionError == nil && SelectionProtocol.count("/api/v1/sessions/a/snapshot") == 3)
            case "manual refresh":
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                client.actionError = "previous error"
                client.reloadSelected()
                precondition(client.loading && !client.snapshotReady && client.actionError == nil)
                precondition(client.conversation?.snapshot.session.id == "a", "Refresh retains visible history")
                client.reloadSelected()
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                precondition(SelectionProtocol.count("/api/v1/sessions/a/snapshot") == 2, "Repeated clicks do not duplicate the pending refresh")
                SelectionProtocol.fail("/api/v1/sessions/a/snapshot", true)
                client.reloadSelected()
                await ConnectionChecks.settle { !client.loading }
                precondition(!client.snapshotReady && client.actionError != nil && client.conversation != nil)
                SelectionProtocol.fail("/api/v1/sessions/a/snapshot", false)
                client.reloadSelected()
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                precondition(client.actionError == nil)
            case "older snapshot":
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                SelectionProtocol.setSequence(5)
                client.reloadSelected()
                await ConnectionChecks.settle { !client.loading }
                precondition(client.conversation?.lastSeq == 10, "A behind snapshot cannot replace newer same-epoch history")
                precondition(client.snapshotReady, "A behind snapshot still settles the refresh so sending can resume")
            case "older history", "full history":
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                SelectionProtocol.hold("/api/v1/sessions/a/messages")
                if scenario == "older history" { client.loadOlder() } else { client.loadAllHistoryForSearch() }
                await ConnectionChecks.settle { SelectionProtocol.count("/api/v1/sessions/a/messages") == 1 }
                client.select("b")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                guard !client.loadingOlder else {
                    SelectionProtocol.release("/api/v1/sessions/a/messages")
                    await ConnectionChecks.settle { !client.loadingOlder }
                    throw WorkbenchError("A history request blocks history loading in B")
                }
                SelectionProtocol.hold("/api/v1/sessions/b/messages")
                client.loadOlder()
                await ConnectionChecks.settle { SelectionProtocol.count("/api/v1/sessions/b/messages") == 1 }
                SelectionProtocol.fail("/api/v1/sessions/a/messages", true)
                SelectionProtocol.release("/api/v1/sessions/a/messages")
                precondition(client.loadingOlder && client.actionError == nil)
                SelectionProtocol.release("/api/v1/sessions/b/messages")
                await ConnectionChecks.settle { !client.loadingOlder }
                precondition(client.conversation?.messages.first?.id == "b-older" && client.actionError == nil)
            case "send failure":
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                client.drafts["a"] = "Keep this instruction"
                SelectionProtocol.hold("/api/v1/sessions/a/prompts")
                SelectionProtocol.fail("/api/v1/sessions/a/prompts", true)
                let send = Task { await client.sendPrompt(for: "a") }
                await ConnectionChecks.settle { SelectionProtocol.count("/api/v1/sessions/a/prompts") == 2 }
                client.select("b")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                client.actionError = "B's own message"
                SelectionProtocol.release("/api/v1/sessions/a/prompts")
                await send.value
                precondition(client.drafts["a"] == "Keep this instruction")
                precondition(client.pendingPrompts["a"]?.first?.error != nil)
                guard client.actionError == "B's own message" else { throw WorkbenchError("A send failure overwrote B's feedback") }
            default:
                SelectionProtocol.hold("/api/v1/sessions/a/snapshot")
                client.select("a")
                await ConnectionChecks.settle { SelectionProtocol.count("/api/v1/sessions/a/snapshot") == 1 }
                client.disconnect()
                guard !client.loading && !client.loadingOlder && !client.snapshotReady else {
                    throw WorkbenchError("Disconnect leaves the cancelled snapshot spinner active")
                }
            }
            print("PASS: Kimi selection \(scenario)")
        } catch {
            failures.append("\(scenario): \(error.localizedDescription)")
            print("FAIL: Kimi selection \(scenario): \(error.localizedDescription)")
        }
    }
    if !failures.isEmpty { throw WorkbenchError(failures.joined(separator: "\n")) }
}
