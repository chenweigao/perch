import Foundation
import WorkbenchCore

/// Hold only the requests involved in a session switch; no SSH or real history.
private final class SelectionProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var held: Set<String> = []
    private static var failed: Set<String> = []
    private static var pending: [String: SelectionProtocol] = [:]
    private static var counts: [String: Int] = [:]
    private static var bodies: [String: [JSONValue]] = [:]
    private static var sequence = 10
    private static var busy = false
    private static var goalActive = true
    private static var recoveredPromptStatus: String?
    private var stopped = false

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        held = []; failed = []; pending = [:]; counts = [:]; bodies = [:]; sequence = 10; busy = false; goalActive = true; recoveredPromptStatus = nil
    }
    static func setRecoveredPrompt(_ status: String) {
        lock.lock(); defer { lock.unlock() }; recoveredPromptStatus = status; busy = true
    }
    static func setSequence(_ value: Int) { lock.lock(); defer { lock.unlock() }; sequence = value }
    static func setBusy(_ value: Bool) { lock.lock(); defer { lock.unlock() }; busy = value; sequence += 1 }
    static func setGoal(_ value: Bool) { lock.lock(); defer { lock.unlock() }; goalActive = value }
    static func hold(_ path: String) { lock.lock(); defer { lock.unlock() }; held.insert(path) }
    static func fail(_ path: String, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if value { failed.insert(path) } else { failed.remove(path) }
    }
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
    static func submitted(_ path: String) -> [JSONValue] { lock.lock(); defer { lock.unlock() }; return bodies[path] ?? [] }
    static func release(_ path: String) {
        lock.lock(); held.remove(path); let request = pending.removeValue(forKey: path); lock.unlock()
        request?.respond()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
    override func startLoading() {
        let path = request.url!.path
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        Self.counts[path, default: 0] += 1
        if !data.isEmpty { Self.bodies[path, default: []].append(try! JSONDecoder().decode(JSONValue.self, from: data)) }
        let hold = Self.held.contains(path)
        if hold { Self.pending[path] = self }
        Self.lock.unlock()
        if !hold { respond() }
    }
    private func respond() {
        let path = request.url!.path
        Self.lock.lock(); let cancelled = stopped; let fail = Self.failed.contains(path); let sequence = Self.sequence; let busy = Self.busy; let goalOn = Self.goalActive; let promptStatus = Self.recoveredPromptStatus; Self.lock.unlock()
        guard !cancelled else { return }
        func session(_ id: String, _ updated: String) -> [String: Any] {
            ["id": id, "title": id, "updated_at": updated, "busy": busy,
             "metadata": ["cwd": "/fixture"], "agent_config": ["model": "fixture/model"]]
        }
        func message(_ id: String) -> [String: Any] {
            ["id": id, "role": "user", "created_at": "1", "content": [["type": "text", "text": id]]]
        }
        func task(_ id: String, kind: String, _ description: String, status: String, output: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["id": id, "session_id": "fixture", "kind": kind, "description": description,
                                        "status": status, "created_at": "2026-09-23T08:00:00.000Z",
                                        "run_in_background": true]
            if kind == "bash" { value["command"] = "npm test" }
            if let output { value["output_preview"] = output; value["output_bytes"] = output.utf8.count }
            return value
        }
        func turn(_ id: String, _ ordinal: Int) -> [String: Any] {
            ["kind": "turn", "turnId": id, "ordinal": ordinal, "state": "completed", "prompt": "fixture \(id)",
             "steps": [["kind": "step", "stepId": "\(id).1", "turnId": id, "ordinal": 1, "state": "completed",
                        "frames": [["kind": "text", "frameId": "\(id).1.f1", "role": "assistant", "text": "fixture text"]]]]]
        }
        let result: Any
        if path == "/api/v1/sessions" {
            result = ["items": [session("a", "catalog"), session("b", "catalog")], "has_more": false]
        } else {
            let id = String(path.split(separator: "/")[3])
            if path.hasSuffix("/snapshot") {
                result = ["as_of_seq": sequence, "epoch": "fixture", "session": session(id, "snapshot"),
                          "messages": ["items": [message(id + "-latest")], "has_more": true],
                          "pending_approvals": [], "pending_questions": []]
            } else if path.hasSuffix("/prompts") {
                if request.httpMethod == "POST" {
                    let body = Self.submitted(path).last!
                    let content = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(body["content"]))
                    result = ["prompt_id": body["prompt_id"].string!, "status": "running", "content": content]
                } else if let promptStatus {
                    let prompt: [String: Any] = ["prompt_id": id + "-prompt", "user_message_id": id + "-older",
                                               "status": promptStatus, "content": [["type": "text", "text": "original task"]]]
                    result = ["active": promptStatus == "running" ? prompt as Any : NSNull(),
                              "queued": promptStatus == "running" ? [] : [prompt]]
                } else { result = ["active": NSNull(), "queued": []] }
            } else if path.hasSuffix(":compact") || path.hasSuffix("/profile") {
                result = [String: Any]()
            } else if path.hasSuffix("/goal") {
                result = goalOn ? ["objective": "Fixture goal", "status": "paused", "turnsUsed": 2, "tokensUsed": 42] as [String: Any] : NSNull()
            } else if path.hasSuffix("/messages") {
                result = ["items": [message(id + "-older")], "has_more": false]
            } else if path.hasSuffix("/tasks") {
                result = ["items": [task("task_1", kind: "bash", "运行测试", status: "running"),
                                    task("task_2", kind: "subagent", "定位输入问题", status: "completed")]]
            } else if path.hasSuffix("/transcript") {
                let older = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains { $0.name == "before_turn" } == true
                result = ["agent_id": "agent_01", "has_more": !older, "seq": older ? 39 : 41,
                          "items": older ? [turn("t0", 0)] : [turn("t1", 1), turn("t2", 2)]]
            } else if path.hasSuffix(":cancel") {
                result = ["cancelled": true]
            } else if path.contains("/tasks/") {
                result = task("task_1", kind: "bash", "运行测试", status: "running", output: "PASS: fixture")
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
func selectionClient() -> KimiConnection {
    SelectionProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SelectionProtocol.self]
    return KimiConnection(host: SSHHost(name: "Selection fixture", destination: "fixture"),
                          api: KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: configuration))
}

@MainActor
func checkKimiSelectionIsolation() async throws {
    var failures: [String] = []
    for scenario in ["catalog callback", "cached retry", "manual refresh", "older snapshot", "older history", "full history", "send failure", "commands", "command isolation", "goal starter failure", "goal status", "task board", "subagent transcript", "disconnect"] {
        let client = selectionClient()
        defer {
            client.disconnect()
            UserDefaults.standard.removeObject(forKey: "kimi.session.\(client.host.id)")
        }
        do {
            switch scenario {
            case "commands":
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                let base = "/api/v1/sessions/a"
                for draft in ["/compact keep APIs", "/goal status", "/goal pause", "/goal resume", "/goal cancel", "/plan on", "/help"] {
                    client.drafts["a"] = draft
                    await client.sendPrompt(for: "a")
                    precondition(client.drafts["a"] == "" && client.actionError == nil && client.commandFeedback["a"] != nil)
                }
                precondition(SelectionProtocol.submitted(base + ":compact").first?["instruction"].string == "keep APIs")
                precondition(SelectionProtocol.submitted(base + "/profile").map { $0["agent_config"] } == [
                    .object(["goal_control": .string("pause")]), .object(["goal_control": .string("resume")]),
                    .object(["goal_control": .string("cancel")]), .object(["plan_mode": .bool(true)])])
                precondition(SelectionProtocol.submitted(base + "/prompts").isEmpty, "Controls must never become chat prompts")
                client.drafts["a"] = "/goal 修复滚动\n保留历史"
                await client.sendPrompt(for: "a")
                precondition(client.drafts["a"] == "" && client.actionError == nil)
                precondition(SelectionProtocol.submitted(base + "/profile").last?["agent_config"]["goal_objective"].string == "修复滚动\n保留历史")
                precondition(SelectionProtocol.submitted(base + "/prompts").last?["content"].array.first?["text"].string == "修复滚动\n保留历史")
                client.drafts["a"] = "/compact"
                client.attachments["a"] = [URL(fileURLWithPath: "/fixture/image.png")]
                await client.sendPrompt(for: "a")
                precondition(client.drafts["a"] == "/compact" && client.attachments["a"]?.count == 1 && client.actionError != nil)
                precondition(SelectionProtocol.submitted(base + ":compact").count == 1)
                client.attachments["a"] = []
                SelectionProtocol.setBusy(true)
                client.reloadSelected()
                await ConnectionChecks.settle { !client.loading && client.snapshotReady }
                await client.sendPrompt(for: "a")
                precondition(client.drafts["a"] == "/compact" && client.actionError != nil)
                precondition(SelectionProtocol.submitted(base + ":compact").count == 1, "Compaction must not interrupt a busy session")
                client.drafts["a"] = "/goal pause"
                await client.sendPrompt(for: "a")
                precondition(client.drafts["a"] == "" && client.actionError == nil, "Goal pause remains available during a turn")
            case "command isolation":
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                let path = "/api/v1/sessions/a:compact"
                SelectionProtocol.hold(path); SelectionProtocol.fail(path, true)
                client.drafts["a"] = "/compact"
                let command = Task { await client.sendPrompt(for: "a") }
                await ConnectionChecks.settle { SelectionProtocol.count(path) == 1 }
                client.select("b")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                client.actionError = "B's feedback"
                SelectionProtocol.release(path)
                await command.value
                precondition(client.actionError == "B's feedback" && client.drafts["a"] == "/compact")
                precondition(client.commandErrors["a"] != nil && client.commandErrors["b"] == nil)
                SelectionProtocol.fail(path, false); SelectionProtocol.hold(path)
                let success = Task { await client.sendPrompt(for: "a") }
                await ConnectionChecks.settle { SelectionProtocol.count(path) == 2 }
                client.drafts["a"] = "New draft while the command runs"
                SelectionProtocol.release(path)
                await success.value
                precondition(client.drafts["a"] == "New draft while the command runs" && client.actionError == "B's feedback")
                precondition(client.commandErrors["a"] == nil)
            case "goal starter failure":
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && !client.loading }
                let path = "/api/v1/sessions/a/prompts"
                SelectionProtocol.fail(path, true)
                client.drafts["a"] = "/goal fix scrolling"
                await client.sendPrompt(for: "a")
                precondition(client.drafts["a"] == "fix scrolling", "A created goal must not be created again when retrying its starter")
                precondition(client.actionError != nil && client.pendingPrompts["a"]?.first?.status == "unknown")
                precondition(SelectionProtocol.submitted("/api/v1/sessions/a/profile").count == 1)
            case "goal status":
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && client.goal != nil }
                let goalPath = "/api/v1/sessions/a/goal"
                precondition(client.goal == KimiGoal(objective: "Fixture goal", status: "paused", turnsUsed: 2, tokensUsed: 42),
                             "Selecting a session loads its goal for the indicator")
                precondition(SelectionProtocol.count(goalPath) == 1, "Selecting a session reads its goal once")
                client.drafts["a"] = "/goal pause"
                await client.sendPrompt(for: "a")
                precondition(SelectionProtocol.count(goalPath) == 2, "A goal control refreshes the indicator")
                precondition(client.goal?.status == "paused" && client.actionError == nil)
                client.select("b")
                await ConnectionChecks.settle { client.snapshotReady && client.goal != nil }
                precondition(SelectionProtocol.count("/api/v1/sessions/b/goal") == 1,
                             "Switching sessions reloads that session's goal")
                client.select("a")
                await ConnectionChecks.settle { client.snapshotReady && client.goal != nil }
                SelectionProtocol.setGoal(false)
                client.drafts["a"] = "/goal cancel"
                await client.sendPrompt(for: "a")
                precondition(client.goal == nil, "A removed goal leaves the indicator")
                SelectionProtocol.fail(goalPath, true)
                await client.refreshGoal()
                precondition(client.goal == nil && client.actionError == nil,
                             "A failed goal read stays silent and keeps the last known value")
            case "task board":
                client.select("a")
                let list = "/api/v1/sessions/a/tasks"
                await ConnectionChecks.settle { client.conversation?.tasks.background.count == 2 }
                precondition(SelectionProtocol.count(list) == 1, "Selecting a session reads its task list once")
                precondition(client.conversation?.tasks.background.map(\.id) == ["task_1", "task_2"])
                precondition(client.conversation?.tasks.backgroundTasks.first?.command == "npm test")
                precondition(client.conversation?.tasks.runningCount == 1)
                guard let task = client.conversation?.tasks.background.first else {
                    throw WorkbenchError("The task list stayed empty")
                }
                client.loadTaskOutput(task)
                await ConnectionChecks.settle { client.conversation?.tasks.outputs["task_1"] != nil }
                precondition(client.conversation?.tasks.output(of: task) == "PASS: fixture")
                precondition(SelectionProtocol.count(list + "/task_1") == 1)
                client.reloadSelected()
                await ConnectionChecks.settle { SelectionProtocol.count(list) == 2 }
                precondition(client.conversation?.tasks.outputs["task_1"] == "PASS: fixture",
                             "A snapshot refresh keeps the tail already read")
                client.cancelTask(task)
                await ConnectionChecks.settle { SelectionProtocol.count(list) == 3 && client.stoppingTasks.isEmpty }
                precondition(SelectionProtocol.submitted(list + "/task_1:cancel").count == 1)
                precondition(client.stoppingTasks.isEmpty && client.taskListError == nil && client.actionError == nil)
                precondition(client.conversation?.tasks.background.map(\.id) == ["task_1", "task_2"],
                             "The list, not the acknowledgement, reports the task state")
                SelectionProtocol.fail(list, true)
                await client.refreshTasks()
                precondition(client.taskListError != nil && client.actionError == nil,
                             "A failed task read stays out of the session error banner")
                precondition(client.conversation?.tasks.background.count == 2, "A failed read keeps the last known list")
                SelectionProtocol.fail(list, false)
                await client.refreshTasks()
                precondition(client.taskListError == nil)
            case "subagent transcript":
                client.select("a")
                await ConnectionChecks.settle { client.conversation?.tasks.background.count == 2 }
                await client.openSubagentTranscript("agent_01")
                precondition(client.subagentTranscript?.turns.map(\.turnId) == ["t1", "t2"])
                precondition(client.subagentTranscript?.seq == 41 && client.subagentTranscript?.hasMoreOlder == true)
                precondition(!client.loadingSubagentTranscript && client.subagentTranscriptError == nil)
                precondition(SelectionProtocol.count("/api/v1/sessions/a/transcript") == 1)
                precondition(client.subagentTranscript?.turns.first?.steps?.first?.frames?.first?.text == "fixture text")
                await client.loadOlderSubagentTurns()
                precondition(client.subagentTranscript?.turns.map(\.turnId) == ["t0", "t1", "t2"], "Older turns are prepended")
                precondition(client.subagentTranscript?.seq == 41, "An older page must not move the watermark back")
                precondition(client.subagentTranscript?.hasMoreOlder == false)
                await client.loadOlderSubagentTurns()
                precondition(SelectionProtocol.count("/api/v1/sessions/a/transcript") == 2, "No further page means no further read")
                client.closeSubagentTranscript()
                precondition(client.subagentTranscript == nil)
                SelectionProtocol.fail("/api/v1/sessions/a/transcript", true)
                await client.openSubagentTranscript("agent_01")
                precondition(client.subagentTranscriptError != nil && client.actionError == nil,
                             "A failed transcript read stays out of the session error banner")
                precondition(client.subagentTranscript == nil)
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

@MainActor
func checkKimiPromptHistory() async throws {
    for status in ["running", "queued", "blocked"] {
        let client = selectionClient()
        defer {
            client.disconnect()
            UserDefaults.standard.removeObject(forKey: "kimi.session.\(client.host.id)")
        }
        SelectionProtocol.setRecoveredPrompt(status)
        client.select("a")
        await ConnectionChecks.settle { client.snapshotReady && !client.loading }
        precondition(client.conversation?.hasOlder == true)
        precondition(client.pendingPrompts["a"]?.count == (status == "running" ? 0 : 1),
                     "Cold open restores waiting prompts, not the external active turn")
        client.select("b")
        await ConnectionChecks.settle { client.snapshotReady && !client.loading }
        client.select("a")
        await ConnectionChecks.settle { client.snapshotReady && !client.loading }
        precondition(client.pendingPrompts["a"]?.count == (status == "running" ? 0 : 1))
        client.loadOlder()
        await ConnectionChecks.settle { !client.loadingOlder }
        precondition(client.conversation?.messages.first?.id == "a-older",
                     "The original task remains accessible in paginated history")
        precondition(client.pendingPrompts["a"]?.isEmpty == true,
                     "Loading the matching history retires the bubble immediately, without re-entering")
        client.reloadSelected()
        await ConnectionChecks.settle { client.snapshotReady && !client.loading }
        precondition(client.pendingPrompts["a"]?.isEmpty == true,
                     "A new tail snapshot must not recreate an echoed prompt")
        print("PASS: Kimi \(status) prompt cold open, cached re-entry and history reconciliation")
    }
}
