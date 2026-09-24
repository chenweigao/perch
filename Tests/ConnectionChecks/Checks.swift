import Foundation
import WorkbenchCore

@MainActor
private final class TransportFixture {
    var sessions: [String: [String: Any]] = [:]
    var receipts: [String: String] = [:]
    var requestTurns: [String: String] = [:]
    var requestModes: [String: String] = [:]
    var promptReceivedAt: [String: Date] = [:]
    var promoteSteer = false
    var promptReceiptStatus = "accepted"
    var prompts: [String] = []
    var steers: [String] = []
    var creates: [(SessionKind, String, String)] = []
    var permissionChanges: [(String, String)] = []
    var modelChanges: [(String, String, String)] = []
    var thinkingChanges: [(String, String)] = []
    var holdModelResponse = false
    var pendingModel: CheckedContinuation<Void, Error>?
    var losePromptResponse = false
    var holdPromptResponse = false
    var pendingPrompt: CheckedContinuation<Void, Error>?
    var failCatalog = false
    var modelsCatalog: [[String: Any]] = [["agent": "codex", "id": "gpt-codex", "provider": "codex", "name": "GPT Codex",
                                        "thinking": ["low", "medium", "ultra"], "defaultThinking": "medium"]]
    var failModels = false
    var modelRequests = 0
    var archives = 0
    var abortedTurns: [(String, String?)] = []
    var holdSnapshots = false
    var failSnapshot = false
    var snapshotRequests: [String] = []
    var pendingSnapshots: [(CheckedContinuation<Data, Error>, Data)] = []
    var returnedSnapshots = 0

    private func receipt(_ key: String) -> [String: Any] {
        var result: [String: Any] = ["id": key, "status": receipts[key] ?? "notFound"]
        if let mode = requestModes[key] { result["mode"] = mode }
        if let turn = requestTurns[key] {
            if requestModes[key] == "steer" { result["turnId"] = turn }
            else if turn != key { result["runtimeTurnId"] = turn }
        }
        return result
    }

    private static func permission(_ provider: SessionKind, _ mode: String) -> [String: Any] {
        let capability = PermissionCatalog.capability(for: provider, selected: mode)
        return ["selected": capability.selected ?? mode, "options": capability.options, "scope": capability.scope.rawValue]
    }

    init() {
        for id in ["a", "b"] {
            sessions[id] = ["id": id, "provider": "omp", "title": id, "cwd": "/fixture",
                            "busy": false, "archived": false, "updated": 1.0, "completed": 0,
                            "pending": 0, "model": "fixture", "cancelled": false, "steer": true,
                            "permission": Self.permission(.omp, "always-ask")]
        }
    }
    func request(_ path: String, _ body: JSONValue?) async throws -> Data {
        let parts = path.split(separator: "?")[0].split(separator: "/").map(String.init)
        var result: [String: Any] = [:]
        if path == "/models" {
            modelRequests += 1
            if failModels { throw WorkbenchError("catalog unavailable") }
            result = ["models": modelsCatalog]
        } else if path == "/sessions", let body {
            let provider = SessionKind(rawValue: body["provider"].string ?? "")!
            let id = provider == .codex ? "native-codex-thread" : "created"
            let permissionMode = body["permissionMode"].string!
            creates.append((provider, body["model"].string ?? "", permissionMode))
            sessions[id] = ["id": id, "provider": provider.rawValue, "title": "created", "cwd": body["cwd"].string ?? "/fixture",
                            "busy": false, "archived": false, "updated": 2.0, "completed": 0,
                            "pending": 0, "model": body["model"].string ?? "", "cancelled": false, "steer": provider == .codex,
                            "permission": Self.permission(provider, permissionMode)]
            result = sessions[id]!
        } else if parts.count == 3 && parts[2] == "permission", let body {
            let id = parts[1], mode = body["mode"].string!
            guard let raw = sessions[id]?["provider"] as? String,
                  let provider = SessionKind(rawValue: raw),
                  [.qoder, .claude].contains(provider) else {
                throw WorkbenchError("permission is fixed")
            }
            sessions[id]?["permission"] = Self.permission(provider, mode)
            permissionChanges.append((id, mode))
            result = ["ok": true, "permission": Self.permission(provider, mode)]
        } else if path == "/sessions" {
            if failCatalog { throw WorkbenchError("catalog unavailable") }
            result = ["sessions": sessions.keys.sorted().compactMap { sessions[$0] }]
        } else if parts.count == 4 && parts[2] == "requests" {
            let key = parts[3]
            result = receipt(key)
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
                    let turn = sessions[id]?["provider"] as? String == SessionKind.codex.rawValue ? "runtime-\(key)" : key
                    promptReceivedAt[key] = Date()
                    prompts.append(id); receipts[key] = promptReceiptStatus; requestTurns[key] = turn
                    sessions[id]?["busy"] = !["completed", "stopped"].contains(promptReceiptStatus)
                    sessions[id]?["turnId"] = turn
                    sessions[id]?["turnState"] = promptReceiptStatus
                }
                if holdPromptResponse { try await withCheckedThrowingContinuation { pendingPrompt = $0 } }
                if losePromptResponse { losePromptResponse = false; throw WorkbenchError("response lost") }
                result = receipt(key)
            case "steer":
                let key = body!["requestId"].string!
                steers.append(key)
                if promoteSteer {
                    for (previous, turn) in requestTurns where turn == sessions[id]?["turnId"] as? String {
                        receipts[previous] = requestModes[previous] == "steer" ? "consumed" : "completed"
                    }
                    sessions[id]?["busy"] = false; sessions[id]?["pending"] = 0
                    return try await request("/sessions/\(id)/prompt", body)
                }
                receipts[key] = "accepted"; requestModes[key] = "steer"
                requestTurns[key] = sessions[id]?["turnId"] as? String
                result = receipt(key)
            case "model":
                if holdModelResponse { try await withCheckedThrowingContinuation { pendingModel = $0 } }
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
        try await checkNativeLoading()
        try await checkKimiTaskLaunch()
        try await checkKimiSteering()
        try await checkKimiPendingSettle()
        try await checkKimiSelectionIsolation()
        try await checkSendFailureIsolation()
        try await checkImmediateSelection()
        try await checkSelectionRetry()
        try await checkNativeModelCatalog()
        try await checkModelSettingsSerialization()
        try await checkPromotedSteerTiming()
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
        try await checkQoderPermission()
        try await checkClaudePermission()
        print("PASS: actual connection resume, cross-session dispatch, receipt recovery, stop evidence and mutation/read separation")
    }

    /// The new-task sheet reads the catalog before any session exists, so the split
    /// per runtime and the failure path are checked away from a live conversation.
    @MainActor
    static func checkNativeModelCatalog() async throws {
        let fixture = TransportFixture()
        fixture.modelsCatalog = [
            ["agent": "omp", "provider": "openai-codex", "id": "gpt-5.4-mini", "name": "GPT-5.4 mini"],
            ["agent": "dsh", "provider": "deepseek-official", "id": "deepseek-v4-flash", "name": "DeepSeek-V4-Flash"]]
        let client = NativeAgentConnection(host: SSHHost(name: "Catalog", destination: "fixture"), transport: fixture.request)
        await client.loadModels()
        precondition(fixture.modelRequests == 1)
        precondition(client.models(for: .omp).map(\.id) == ["gpt-5.4-mini"])
        precondition(client.models(for: .dsh).map(\.id) == ["deepseek-v4-flash"])
        precondition(client.models(for: .qoder).isEmpty, "Qoder reports no catalog and must not borrow another runtime's")
        precondition(client.models(for: .claude).isEmpty, "Claude reports no catalog and must not borrow another runtime's")
        precondition(client.modelsError == nil && client.actionError == nil)
        // A failed read keeps the last good list and reports to the model control,
        // not as a conversation banner nobody asked for.
        fixture.failModels = true
        await client.loadModels()
        precondition(client.modelsError != nil && client.actionError == nil)
        precondition(client.models(for: .omp).map(\.id) == ["gpt-5.4-mini"], "A failed catalog read must not empty the picker")
        // A bridge that predates tagging still lists everything it knows.
        fixture.failModels = false
        fixture.modelsCatalog = [["provider": "bailian", "id": "kimi-k3", "name": "Kimi K3"]]
        await client.loadModels()
        precondition(client.modelsError == nil)
        precondition(client.models(for: .omp).map(\.id) == ["kimi-k3"] && client.models(for: .dsh).map(\.id) == ["kimi-k3"])
        client.disconnect()
        print("PASS: native model catalog split per runtime, last good list kept on failure, untagged bridge tolerated")
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
        let session = try await client.create(provider: .codex, cwd: "/fixture", model: model.id, permissionMode: "workspace-auto")
        precondition(session.permission?.selected == "workspace-auto" && session.permission?.scope == .newSession)
        precondition(session.id == "native-codex-thread" && session.provider == .codex)
        precondition(fixture.creates.count == 1 && fixture.creates[0].0 == .codex
                     && fixture.creates[0].1 == model.id && fixture.creates[0].2 == "workspace-auto")
        client.setPermission("full-access", for: session.id)
        precondition(client.actionError != nil && fixture.permissionChanges.isEmpty,
                     "Codex permissions are fixed when the session is created")
        await settle { client.snapshot?.id == session.id }

        client.setModel(model, for: session.id)
        await settle { fixture.modelChanges.count == 1 && fixture.thinkingChanges.count == 1 }
        precondition(fixture.modelChanges[0].1 == "codex" && fixture.modelChanges[0].2 == model.id)
        precondition(fixture.thinkingChanges[0].1 == "medium")

        client.drafts[session.id] = "start native turn"; client.send()
        await settle { fixture.prompts.last == session.id && !client.sending }
        try await client.refresh()
        guard let request = client.queue.allItems.first(where: { $0.session.terminalID == session.id }),
              let runtimeTurn = fixture.requestTurns[request.id],
              let startedAt = client.timings.turns[session.id]?.startedAt else {
            preconditionFailure("Codex prompt timing was not started")
        }
        precondition(runtimeTurn != request.id && client.timings.turns[session.id]?.turnID == runtimeTurn)
        precondition(client.timings.turns[session.id]?.observedOnly == false)
        precondition(client.modes(for: session.id) == [.steer, .nextTurn])
        client.drafts[session.id] = "guide native turn"; client.send(mode: .steer)
        await settle { fixture.steers.count == 1 && !client.sending }
        precondition(client.timings.turns[session.id]?.turnID == runtimeTurn
                     && client.timings.turns[session.id]?.startedAt == startedAt,
                     "Steering must not reset the active turn clock")
        fixture.receipts[request.id] = "completed"
        fixture.sessions[session.id]?["busy"] = false
        fixture.sessions[session.id]?["turnState"] = "completed"
        try await client.poll()
        precondition(client.timings.turns[session.id]?.endedAt != nil,
                     "A completion receipt must freeze the runtime turn clock")
        client.disconnect()
        print("PASS: Codex native identity, settings, steering and request/runtime turn timing")
    }

    @MainActor
    static func checkPromotedSteerTiming() async throws {
        for provider in [SessionKind.codex, .omp] {
            for status in ["accepted", "completed", "stopped"] {
                let fixture = TransportFixture()
                fixture.sessions["a"]?["provider"] = provider.rawValue
                let client = NativeAgentConnection(host: SSHHost(name: "Promoted steer", destination: "fixture"), transport: fixture.request)
                try await client.refresh(); client.select("a")
                await settle { client.snapshot?.id == "a" }
                client.drafts["a"] = "previous turn"; client.send()
                await settle { fixture.prompts.count == 1 && !client.sending }
                fixture.sessions["a"]?["pending"] = 1
                try await client.refresh()
                let previous = client.timings.turns["a"]!
                precondition(previous.waitingSince != nil)

                fixture.promoteSteer = true; fixture.promptReceiptStatus = status
                // Inspect the receipt's effect without a later catalog correcting it.
                fixture.failCatalog = true
                client.drafts["a"] = "racing guidance"; client.send(mode: .steer)
                await settle { fixture.steers.count == 1 && !client.sending }
                let key = fixture.steers[0]
                guard let timing = client.timings.turns["a"], let received = fixture.promptReceivedAt[key] else {
                    preconditionFailure("Promoted steer did not establish a clock")
                }
                precondition(timing.turnID == fixture.requestTurns[key] && timing.turnID != previous.turnID)
                precondition(!timing.observedOnly && timing.startedAt <= received && timing.startedAt > previous.startedAt,
                             "A promoted prompt must retain its local submission timestamp")
                precondition(timing.waitingSince == nil && timing.waitingSeconds == 0,
                             "The prior turn's approval wait must not carry into a new prompt")
                precondition((timing.endedAt != nil) == (status != "accepted"),
                             "Immediate completion or stop must freeze the promoted turn without a catalog")
                client.disconnect()
            }
        }
        print("PASS: server-promoted Codex/OMP steer receipts bind submission time, including immediate completion/stop")
    }

    @MainActor
    static func checkModelSettingsSerialization() async throws {
        let fixture = TransportFixture()
        let client = NativeAgentConnection(host: SSHHost(name: "Model settings", destination: "fixture"), transport: fixture.request)
        try await client.refresh()
        let target = AgentModel(id: "new-model", provider: "fixture", name: "New model",
                                thinking: [.low, .high], defaultThinking: .high)
        fixture.holdModelResponse = true
        client.setModel(target, for: "a")
        await settle { fixture.pendingModel != nil }
        precondition(client.configuringSessions.contains("a"))
        client.setThinking(.low, for: "a")
        client.setModel(target, for: "a")
        precondition(fixture.thinkingChanges.isEmpty && fixture.modelChanges.isEmpty)
        fixture.holdModelResponse = false
        fixture.pendingModel?.resume(); fixture.pendingModel = nil
        await settle { !client.configuringSessions.contains("a") }
        precondition(fixture.modelChanges.count == 1 && fixture.modelChanges[0].1 == "fixture")
        precondition(fixture.thinkingChanges.count == 1 && fixture.thinkingChanges[0].1 == "high")
        precondition(client.sessions.first { $0.id == "a" }?.model == "new-model")
        client.setThinking(.low, for: "a")
        await settle { !client.configuringSessions.contains("a") }
        precondition(client.sessions.first { $0.id == "a" }?.thinking == "low")

        fixture.holdModelResponse = true
        client.setModel(target, for: "a")
        await settle { fixture.pendingModel != nil }
        fixture.pendingModel?.resume(throwing: WorkbenchError("setting failed")); fixture.pendingModel = nil
        await settle { !client.configuringSessions.contains("a") }
        precondition(client.actionError == "setting failed" && fixture.modelChanges.count == 1)
        precondition(fixture.thinkingChanges.count == 2)
        fixture.holdModelResponse = false
        client.setThinking(.high, for: "a")
        await settle { !client.configuringSessions.contains("a") }
        precondition(client.sessions.first { $0.id == "a" }?.thinking == "high")
        print("PASS: model and thinking changes are serialized, refreshed and unlocked after errors")
    }

    @MainActor
    static func checkQoderPermission() async throws {
        let fixture = TransportFixture()
        let client = NativeAgentConnection(host: SSHHost(name: "Qoder", destination: "fixture"), transport: fixture.request)
        let session = try await client.create(provider: .qoder, cwd: "/fixture", model: "", permissionMode: "acceptEdits")
        precondition(session.permission?.selected == "acceptEdits" && session.permission?.scope == .nextTurn)
        precondition(fixture.creates.first?.2 == "acceptEdits")
        fixture.sessions[session.id]?["busy"] = true
        try await client.refresh()
        client.setPermission("bypassPermissions", for: session.id)
        await settle {
            fixture.permissionChanges.count == 1
                && fixture.permissionChanges[0].0 == session.id
                && fixture.permissionChanges[0].1 == "bypassPermissions"
                && client.sessions.first { $0.id == session.id }?.permission?.selected == "bypassPermissions"
        }
        precondition(client.sessions.first { $0.id == session.id }?.permission?.selected == "bypassPermissions",
                     "Qoder permission changes must be saved while the current turn is busy")
        client.disconnect()
        print("PASS: Qoder permission selection applies to the next turn while busy")
    }

    @MainActor
    static func checkClaudePermission() async throws {
        let fixture = TransportFixture()
        let client = NativeAgentConnection(host: SSHHost(name: "Claude", destination: "fixture"), transport: fixture.request)
        let session = try await client.create(provider: .claude, cwd: "/fixture", model: "", permissionMode: "acceptEdits")
        precondition(session.permission?.selected == "acceptEdits" && session.permission?.scope == .nextTurn)
        precondition(fixture.creates.first?.2 == "acceptEdits")
        fixture.sessions[session.id]?["busy"] = true
        try await client.refresh()
        client.setPermission("plan", for: session.id)
        await settle {
            fixture.permissionChanges.count == 1
                && fixture.permissionChanges[0].0 == session.id
                && fixture.permissionChanges[0].1 == "plan"
                && client.sessions.first { $0.id == session.id }?.permission?.selected == "plan"
        }
        precondition(client.sessions.first { $0.id == session.id }?.permission?.selected == "plan",
                     "Claude permission changes must be saved while the current turn is busy")
        // Qoder-only modes must not validate against the Claude catalog.
        client.setPermission("dontAsk", for: session.id)
        precondition(client.actionError != nil && fixture.permissionChanges.count == 1)
        client.disconnect()
        print("PASS: Claude permission selection applies to the next turn while busy")
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
