import Foundation
import WorkbenchCore

@MainActor
private final class TransportFixture {
    var sessions: [String: [String: Any]] = [:]
    var receipts: [String: String] = [:]
    var prompts: [String] = []
    var losePromptResponse = false
    var failCatalog = false
    var archives = 0

    init() {
        for id in ["a", "b"] {
            sessions[id] = ["id": id, "provider": "omp", "title": id, "cwd": "/fixture",
                            "busy": false, "archived": false, "updated": 1.0, "completed": 0,
                            "pending": 0, "model": "fixture", "cancelled": false]
        }
    }
    func request(_ path: String, _ body: JSONValue?) async throws -> Data {
        let parts = path.split(separator: "/").map(String.init)
        var result: [String: Any] = [:]
        if path == "/sessions" {
            if failCatalog { throw WorkbenchError("catalog unavailable") }
            result = ["sessions": sessions.keys.sorted().compactMap { sessions[$0] }]
        } else if parts.count == 4 && parts[2] == "requests" {
            result = ["id": parts[3], "status": receipts[parts[3]] ?? "notFound"]
        } else if parts.count == 3 {
            let id = parts[1]
            switch parts[2] {
            case "prompt":
                let key = body!["requestId"].string!
                if receipts[key] == nil {
                    prompts.append(id); receipts[key] = "accepted"
                    sessions[id]?["busy"] = true; sessions[id]?["turnId"] = key
                    sessions[id]?["turnState"] = "accepted"
                }
                if losePromptResponse { losePromptResponse = false; throw WorkbenchError("response lost") }
                result = ["id": key, "status": receipts[key]!]
            case "abort":
                // An old optimistic cancellation flag is still not terminal evidence.
                sessions[id]?["cancelled"] = true
                result = ["ok": true]
            case "archive": archives += 1; result = ["ok": true]
            default: throw WorkbenchError("Unexpected route: \(path)")
            }
        } else { throw WorkbenchError("Unexpected route: \(path)") }
        return try JSONSerialization.data(withJSONObject: result)
    }
}

@main
struct ConnectionChecks {
    @MainActor
    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("connection did not settle")
    }
    @MainActor
    static func main() async throws {
        let fixture = TransportFixture()
        let connection = NativeAgentConnection(host: SSHHost(name: "Fixture", destination: "fixture"), transport: fixture.request)
        try await connection.refresh()
        connection.select("a")
        let a = connection.reference("a")!, b = connection.reference("b")!

        // Resume must dispatch even if the catalog has not changed at all.
        connection.queue.enqueue("暂停中的中文", for: a, mode: .nextTurn, id: "resume-a")
        connection.queue.pauseForStop(a)
        connection.resumeQueue(a)
        await settle { connection.queue.message("resume-a")?.state == .accepted }
        precondition(fixture.prompts == ["a"])

        // Another idle session must not starve behind the first one.
        connection.select("b"); connection.drafts["b"] = "另一个会话"
        connection.send()
        await settle { fixture.prompts.count == 2 && !connection.sending }
        precondition(fixture.prompts == ["a", "b"])

        // An accepted mutation followed by read failure must remain a success.
        fixture.failCatalog = true
        try await connection.action("a", "archive", ["archived": .bool(true)])
        precondition(fixture.archives == 1 && connection.actionError?.contains("同步失败") == true)
        fixture.failCatalog = false

        connection.select("a"); try await connection.refresh(); connection.stop()
        await settle { connection.stops.phase(for: a) == .stopping }
        precondition(connection.queue.isPaused(a))
        fixture.sessions["a"]?["busy"] = false
        fixture.sessions["a"]?["turnState"] = "stopped"
        fixture.receipts["resume-a"] = "stopped"
        try await connection.refresh()
        precondition(connection.stops.phase(for: a) == .stopped)
        fixture.sessions["a"]?["busy"] = true
        fixture.sessions["a"]?["turnId"] = "new-turn"
        try await connection.refresh()
        precondition(connection.stops.phase(for: a) == .idle)

        // A lost response is reconciled by receipt, never automatically replayed.
        let lost = TransportFixture(); lost.losePromptResponse = true
        let client = NativeAgentConnection(host: SSHHost(name: "Lost", destination: "fixture"), transport: lost.request)
        try await client.refresh(); client.select("a"); client.drafts["a"] = "仅执行一次"
        client.send()
        await settle { !client.queue.allItems.isEmpty && !client.sending }
        let pending = client.queue.allItems[0]
        if case .unknown = pending.state {} else { preconditionFailure("must preserve uncertainty") }
        precondition(client.queue.exitWarningCount == 1)
        try await client.refresh()
        precondition(client.queue.message(pending.id)?.state == .accepted)
        precondition(lost.prompts.count == 1 && client.queue.exitWarningCount == 0)
        lost.sessions["a"]?["busy"] = false; lost.receipts[pending.id] = "completed"
        try await client.refresh()
        precondition(client.queue.allItems.isEmpty && lost.prompts.count == 1)
        precondition(connection.queue.items(for: b).count == 1)
        print("PASS: actual connection resume, cross-session dispatch, receipt recovery, stop evidence and mutation/read separation")
    }
}
