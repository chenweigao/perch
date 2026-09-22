import Foundation
import WorkbenchCore

@MainActor
private final class TransportFixture {
    var sessions: [String: [String: Any]] = [:]
    var receipts: [String: String] = [:]
    var prompts: [String] = []
    var steers: [String] = []
    var creates: [(SessionKind, String)] = []
    var modelChanges: [(String, String, String)] = []
    var thinkingChanges: [(String, String)] = []
    var losePromptResponse = false
    var holdPromptResponse = false
    var pendingPrompt: CheckedContinuation<Void, Error>?
    var failCatalog = false
    var archives = 0
    var abortedTurns: [(String, String?)] = []
    var holdSnapshots = false
    var failSnapshot = false
    var snapshotRequests: [String] = []
    var pendingSnapshots: [(CheckedContinuation<Data, Error>, Data)] = []
    var returnedSnapshots = 0

    init() {
        for id in ["a", "b"] {
            sessions[id] = ["id": id, "provider": "omp", "title": id, "cwd": "/fixture",
                            "busy": false, "archived": false, "updated": 1.0, "completed": 0,
                            "pending": 0, "model": "fixture", "cancelled": false, "steer": true]
        }
    }
    func request(_ path: String, _ body: JSONValue?) async throws -> Data {
        let parts = path.split(separator: "?")[0].split(separator: "/").map(String.init)
        var result: [String: Any] = [:]
        if path == "/models" {
            result = ["models": [["id": "gpt-codex", "provider": "codex", "name": "GPT Codex",
                                  "thinking": ["low", "medium", "ultra"], "defaultThinking": "medium"]]]
        } else if path == "/sessions", let body {
            let provider = SessionKind(rawValue: body["provider"].string ?? "")!
            let id = provider == .codex ? "native-codex-thread" : "created"
            creates.append((provider, body["model"].string ?? ""))
            sessions[id] = ["id": id, "provider": provider.rawValue, "title": "created", "cwd": body["cwd"].string ?? "/fixture",
                            "busy": false, "archived": false, "updated": 2.0, "completed": 0,
                            "pending": 0, "model": body["model"].string ?? "", "cancelled": false, "steer": provider == .codex]
            result = sessions[id]!
        } else if path == "/sessions" {
            if failCatalog { throw WorkbenchError("catalog unavailable") }
            result = ["sessions": sessions.keys.sorted().compactMap { sessions[$0] }]
        } else if parts.count == 4 && parts[2] == "requests" {
            result = ["id": parts[3], "status": receipts[parts[3]] ?? "notFound"]
        } else if parts.count == 2 {
            let id = parts[1]
            snapshotRequests.append(id)
            if failSnapshot { throw WorkbenchError("snapshot unavailable") }
            result = sessions[id]!
            result["revision"] = snapshotRequests.count
            result["messages"] = []; result["interactions"] = []
            let data = try JSONSerialization.data(withJSONObject: result)
            defer { returnedSnapshots += 1 }
            if holdSnapshots {
                return try await withCheckedThrowingContinuation { pendingSnapshots.append(($0, data)) }
            }
            return data
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
                if holdPromptResponse { try await withCheckedThrowingContinuation { pendingPrompt = $0 } }
                if losePromptResponse { losePromptResponse = false; throw WorkbenchError("response lost") }
                result = ["id": key, "status": receipts[key]!]
            case "steer":
                let key = body!["requestId"].string!
                steers.append(key); receipts[key] = "accepted"
                result = ["id": key, "status": "accepted"]
            case "model":
                let provider = body?["provider"].string ?? "", model = body?["model"].string ?? ""
                modelChanges.append((id, provider, model)); sessions[id]?["model"] = model
                result = ["ok": true]
            case "thinking":
                let level = body?["level"].string ?? ""
                thinkingChanges.append((id, level)); sessions[id]?["thinking"] = level
                result = ["ok": true]
            case "abort":
                abortedTurns.append((id, body?["turnId"].string))
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
        try await checkKimiTaskLaunch()
        try await checkKimiSteering()
        try await checkKimiPendingSettle()
        try await checkKimiSelectionIsolation()
        try await checkSendFailureIsolation()
        try await checkImmediateSelection()
        try await checkSelectionRetry()
        let unsupportedFixture = TransportFixture()
        let unsupportedClient = NativeAgentConnection(host: SSHHost(name: "Commands", destination: "fixture"), transport: unsupportedFixture.request)
        try await unsupportedClient.refresh(); unsupportedClient.select("a")
        await settle { unsupportedClient.snapshot?.id == "a" }
        unsupportedClient.drafts["a"] = "/goal fix scrolling"
        unsupportedClient.send()
        precondition(unsupportedClient.drafts["a"] == "/goal fix scrolling" && unsupportedClient.actionError != nil)
        precondition(unsupportedFixture.prompts.isEmpty, "An unavailable goal command must not become a literal model prompt")
        unsupportedClient.disconnect()
        let fixture = TransportFixture()
        let steeringFixture = TransportFixture()
        let steeringClient = NativeAgentConnection(host: SSHHost(name: "Steer", destination: "fixture"), transport: steeringFixture.request)
        try await steeringClient.refresh(); steeringClient.select("a")
        steeringClient.drafts["a"] = "original"; steeringClient.send()
        await settle { !steeringClient.sending }
        try await steeringClient.refresh()
        let originalTurn = steeringFixture.sessions["a"]?["turnId"] as? String
        precondition(steeringClient.modes(for: "a") == [.steer, .nextTurn])
        steeringClient.drafts["a"] = "guide now"; steeringClient.send(mode: .steer)
        await settle { steeringFixture.steers.count == 1 && !steeringClient.sending }
        precondition(steeringFixture.prompts.count == 1)
        precondition(steeringFixture.sessions["a"]?["turnId"] as? String == originalTurn)
        steeringClient.drafts["a"] = "guide again"; steeringClient.send(mode: .steer)
        await settle { steeringFixture.steers.count == 2 && !steeringClient.sending }
        steeringClient.drafts["a"] = "next turn"; steeringClient.send(mode: .nextTurn)
        precondition(steeringFixture.prompts.count == 1)
        let consumedID = steeringFixture.steers[0]
        steeringFixture.receipts[consumedID] = "consumed"
        steeringClient.select("b")
        try await steeringClient.refresh()
        precondition(steeringClient.queue.message(consumedID) == nil, "Consumed guidance in a background session must not block queued work")
        steeringClient.disconnect()
        print("PASS: native steering during accepted turn, repeated guidance, next-turn queue")
        let connection = NativeAgentConnection(host: SSHHost(name: "Fixture", destination: "fixture"), transport: fixture.request)
        try await connection.refresh()
        connection.select("a")
        let a = connection.reference("a")!, b = connection.reference("b")!
        precondition(!connection.canStop && !connection.isStopping)
        connection.stop()
        precondition(fixture.abortedTurns.isEmpty, "Idle composer must not send an abort")

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

        connection.select("a"); try await connection.refresh()
        precondition(connection.canStop)
        connection.stop(); connection.stop()
        precondition(connection.isStopping && !connection.canStop, "Disable repeated stop clicks immediately")
        await settle { connection.stops.phase(for: a) == .stopping }
        precondition(fixture.abortedTurns.count == 1 && fixture.abortedTurns[0].0 == "a" && fixture.abortedTurns[0].1 == "resume-a")
        precondition(connection.isStopping && !connection.canStop, "Acknowledgement is not a stopped turn")
        connection.select("b")
        precondition(!connection.isStopping && connection.canStop, "Stop UI state belongs to the selected session")
        connection.select("a")
        precondition(connection.queue.isPaused(a))
        fixture.sessions["a"]?["busy"] = false
        fixture.sessions["a"]?["turnState"] = "stopped"
        fixture.receipts["resume-a"] = "stopped"
        try await connection.refresh()
        precondition(connection.stops.phase(for: a) == .stopped)
        precondition(!connection.isStopping && !connection.canStop)
        fixture.sessions["a"]?["busy"] = true
        fixture.sessions["a"]?["turnId"] = "new-turn"
        try await connection.refresh()
        precondition(connection.stops.phase(for: a) == .idle && connection.canStop)

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
        try await checkCodexConnection()
        print("PASS: actual connection resume, cross-session dispatch, receipt recovery, stop evidence and mutation/read separation")
    }

    @MainActor
    static func checkCodexConnection() async throws {
        let fixture = TransportFixture()
        let client = NativeAgentConnection(host: SSHHost(name: "Codex", destination: "fixture"), transport: fixture.request)
        await client.loadModels()
        guard let model = client.models.first(where: { $0.provider == "codex" }) else {
            preconditionFailure("Codex model catalog was not decoded")
        }
        precondition(model.defaultThinking == .medium && model.thinking.last == .ultra)
        let session = try await client.create(provider: .codex, cwd: "/fixture", model: model.id)
        precondition(session.id == "native-codex-thread" && session.provider == .codex)
        precondition(fixture.creates.count == 1 && fixture.creates[0].0 == .codex && fixture.creates[0].1 == model.id)
        await settle { client.snapshot?.id == session.id }

        client.setModel(model, for: session.id)
        await settle { fixture.modelChanges.count == 1 && fixture.thinkingChanges.count == 1 }
        precondition(fixture.modelChanges[0].1 == "codex" && fixture.modelChanges[0].2 == model.id)
        precondition(fixture.thinkingChanges[0].1 == "medium")

        client.drafts[session.id] = "start native turn"; client.send()
        await settle { fixture.prompts.last == session.id && !client.sending }
        try await client.refresh()
        precondition(client.modes(for: session.id) == [.steer, .nextTurn])
        client.drafts[session.id] = "guide native turn"; client.send(mode: .steer)
        await settle { fixture.steers.count == 1 && !client.sending }
        client.disconnect()
        print("PASS: Codex native thread identity, catalog effort, model actions and steering")
    }

    @MainActor
    static func checkSendFailureIsolation() async throws {
        let fixture = TransportFixture(); fixture.holdPromptResponse = true
        let client = NativeAgentConnection(host: SSHHost(name: "Send fixture", destination: "fixture"), transport: fixture.request)
        try await client.refresh(); client.select("a")
        client.drafts["a"] = "Keep this instruction"; client.send()
        await settle { fixture.pendingPrompt != nil }
        let message = client.queue.allItems[0]
        client.select("b"); client.actionError = "B's own message"
        fixture.pendingPrompt?.resume(throwing: WorkbenchError("A's send failed"))
        await settle { if case .unknown = client.queue.message(message.id)?.state { return true }; return false }
        precondition(client.actionError == "B's own message", "A send failure must not replace B's feedback")
        precondition(client.queue.message(message.id)?.text == "Keep this instruction")
        print("PASS: native send failure stays with its queued message across selection changes")
    }

    @MainActor
    static func checkSelectionRetry() async throws {
        let fixture = TransportFixture(); fixture.failSnapshot = true
        let client = NativeAgentConnection(host: SSHHost(name: "Retry", destination: "fixture"), transport: fixture.request)
        try await client.refresh()
        client.select("a")
        await settle { client.actionError != nil }
        precondition(client.snapshot == nil && client.selectedID == "a")
        fixture.failSnapshot = false
        client.select("a")
        await settle { client.snapshot?.id == "a" }
        precondition(client.actionError == nil && fixture.snapshotRequests == ["a", "a"])
        client.select("a")
        await Task.yield()
        precondition(fixture.snapshotRequests.count == 2, "Selecting a loaded session must not refetch it")
        print("PASS: failed conversation load can retry the same session without creating a new task")
    }

    @MainActor
    static func checkImmediateSelection() async throws {
        let fixture = TransportFixture(); fixture.holdSnapshots = true
        let client = NativeAgentConnection(host: SSHHost(name: "Selection", destination: "fixture"), transport: fixture.request)
        try await client.refresh()
        client.select("a")
        await settle { fixture.snapshotRequests == ["a"] }
        client.select("b")
        await settle { fixture.snapshotRequests == ["a", "b"] }
        client.select("a")
        await settle { fixture.pendingSnapshots.count == 3 }
        // Transport deliberately ignores cancellation and completes out of order.
        fixture.pendingSnapshots[2].0.resume(returning: fixture.pendingSnapshots[2].1)
        await settle { client.snapshot?.revision == 3 }
        fixture.pendingSnapshots[0].0.resume(returning: fixture.pendingSnapshots[0].1)
        fixture.pendingSnapshots[1].0.resume(returning: fixture.pendingSnapshots[1].1)
        await settle { fixture.returnedSnapshots == 3 }
        precondition(client.snapshot?.id == "a" && client.snapshot?.revision == 3)
        precondition(client.actionError == nil)
        client.select("b")
        await settle { fixture.pendingSnapshots.count == 4 }
        client.disconnect()
        fixture.pendingSnapshots[3].0.resume(returning: fixture.pendingSnapshots[3].1)
        await settle { fixture.returnedSnapshots == 4 }
        precondition(client.snapshot == nil && !client.online)
        print("PASS: immediate selection reads, A-B-A stale response isolation and disconnect cancellation")
    }
}
