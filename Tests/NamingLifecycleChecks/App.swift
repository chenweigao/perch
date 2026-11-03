import AppKit
import Foundation
import WorkbenchCore

private final class KimiNamingProtocol: URLProtocol {
    static let prompt = "Fix the login redirect loop in the sample app"
    static let createdID = "kimi-created"
    static let namedTitle = "Login redirect diagnosis"
    private static let lock = NSLock()
    private static var acceptsPrompts = false
    private static var acceptedPrompt: [String: Any]?
    private static var remoteTitle = prompt
    static func allowPrompts() {
        lock.lock(); defer { lock.unlock() }
        acceptsPrompts = true
    }
    static func nameRemotely() {
        lock.lock(); defer { lock.unlock() }
        remoteTitle = namedTitle
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let path = request.url!.path
        let id = path.split(separator: "/").dropFirst(3).first.map(String.init) ?? Self.createdID
        let empty = id == Self.createdID && Self.acceptedPrompt == nil
        let title = empty ? "" : id == "kimi-titled" ? Self.namedTitle : id == "kimi-remote-title" ? Self.remoteTitle : Self.prompt
        func session() -> [String: Any] {
            ["id": id, "title": title, "updated_at": "fixture", "busy": !empty,
             "metadata": ["cwd": "/fixture"], "agent_config": ["model": "fixture/model"]]
        }
        var status = 200
        let value: Any
        if path == "/api/v1/sessions" { value = session() }
        else if path.hasSuffix("/snapshot") {
            let content = id == Self.createdID ? Self.acceptedPrompt?["content"] ?? [] : [["type": "text", "text": Self.prompt]]
            let messages: [[String: Any]] = empty ? [] : [["id": id == Self.createdID ? Self.acceptedPrompt!["user_message_id"]! : "user-" + id,
                "role": "user", "created_at": "", "content": content]]
            value = ["epoch": "fixture", "as_of_seq": 10, "session": session(),
                     "messages": ["items": messages, "has_more": false],
                     "pending_approvals": [], "pending_questions": []] as [String: Any]
        } else if path.hasSuffix("/prompts"), request.httpMethod == "POST" {
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
            let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            let accepted: [String: Any] = ["prompt_id": body["prompt_id"]!, "user_message_id": body["prompt_id"]!,
                                          "status": "running", "content": body["content"]!]
            if Self.acceptsPrompts { Self.acceptedPrompt = accepted } else { status = 503 }
            value = accepted
        } else if path.hasSuffix("/prompts") { value = ["active": NSNull(), "queued": []] }
        else if path.hasSuffix("/tasks") { value = ["items": []] }
        else if path.hasSuffix("/goal") { value = NSNull() }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let envelope: [String: Any] = status == 200 ? ["code": 0, "data": value] : ["msg": "Fixture prompt rejected"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: envelope))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct NamingLifecycleChecks {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Naming lifecycle timed out")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        precondition(Bundle.main.bundleIdentifier!.hasPrefix("dev.agentworkbench.namingqa."))
        let host = SSHHost(name: "Naming fixture", destination: "fixture.invalid", enabledAgents: [.omp])
        UserDefaults.standard.set(try JSONEncoder().encode([host]), forKey: "hosts")
        let model = WorkbenchModel()
        let settings = ActivitySummarySettings.shared
        var config = ActivitySummaryConfiguration()
        config.baseURL = ProcessInfo.processInfo.environment["PERCH_NAMING_FIXTURE_URL"]!
        config.model = "fixture"; config.nameSessions = true
        try settings.updateConfiguration(config)
        let firstMessage = KimiNamingProtocol.prompt
        let native = NativeAgentConnection(host: host) { path, _ in
            let id = String(path.split(separator: "?")[0].split(separator: "/").last!)
            var snapshot: [String: Any] = ["id": id, "provider": "omp", "title": firstMessage,
                "cwd": "/fixture", "busy": id == "native-running", "revision": 1,
                "completed": id == "native-running" ? 0 : 1, "model": "fixture",
                "messages": [["id": "user-" + id, "role": "user", "created_at": "", "content": [["type": "text", "text": firstMessage]]]],
                "interactions": []]
            if id == "partial" { snapshot["history"] = ["epoch": "fixture", "start": 20, "end": 21, "total": 21] }
            return try JSONSerialization.data(withJSONObject: snapshot)
        }
        model.registerEnvironment(kimi: KimiConnection(setupHost: host), native: native)
        model.activateAgentEnvironment(host.id)
        var calls = 0
        model.sessionNamer = { _, excerpt, _ in
            calls += 1
            precondition(excerpt == firstMessage)
            return "修复登录跳转"
        }
        func reference(_ id: String) -> SessionReference { SessionReference(hostID: host.id, terminalID: id, kind: .omp) }
        native.select("first")
        try await until { native.snapshot?.id == "first" }
        precondition(calls == 0, "Disabled external summaries must gate naming")
        config.enabled = true
        try settings.updateConfiguration(config)
        try await until { model.workspace.autoNamedSessions.contains(reference("first").id) }
        precondition(calls == 1 && model.workspace.sessionTitles[reference("first").id] == "修复登录跳转")
        precondition(!model.namingInProgress.contains(reference("first").id))
        print("PASS: enabling naming rechecks the loaded session and saves its generated local title")
        native.select("native-running")
        try await until { model.workspace.autoNamedSessions.contains(reference("native-running").id) }
        precondition(native.snapshot?.busy == true && native.snapshot?.completed == 0)
        print("PASS: native sessions still name their first message while the turn runs")

        let kimiConfiguration = URLSessionConfiguration.ephemeral
        kimiConfiguration.protocolClasses = [KimiNamingProtocol.self]
        let kimi = KimiConnection(host: host, api: KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: kimiConfiguration))
        kimi.select("kimi-loaded")
        try await until { kimi.snapshotReady && !kimi.loading }
        model.registerEnvironment(kimi: kimi, native: native)
        model.activateAgentEnvironment(host.id)
        func kimiReference(_ id: String) -> SessionReference { SessionReference(hostID: host.id, terminalID: id, kind: .kimi) }
        try await until { model.workspace.autoNamedSessions.contains(kimiReference("kimi-loaded").id) }
        kimi.select("kimi-next")
        try await until { model.workspace.autoNamedSessions.contains(kimiReference("kimi-next").id) }
        precondition(model.workspace.sessionTitles[kimiReference("kimi-loaded").id] == "修复登录跳转")
        precondition(model.workspace.sessionTitles[kimiReference("kimi-next").id] == "修复登录跳转")
        precondition(kimi.conversation?.snapshot.session.isTurnRunning == true && kimi.conversation?.snapshot.session.lastTurnReason == nil)
        print("PASS: Kimi naming catches up loaded and subsequent conversations without waiting for completion")

        let beforeProtected = calls
        kimi.select("kimi-titled")
        try await until { kimi.snapshotReady && !kimi.loading }
        model.workspace.rename(kimiReference("kimi-manual"), title: "User chosen Kimi name")
        kimi.select("kimi-manual")
        try await until { kimi.snapshotReady && !kimi.loading }
        try await Task.sleep(for: .milliseconds(30))
        precondition(calls == beforeProtected && model.workspace.sessionTitles[kimiReference("kimi-titled").id] == nil)
        precondition(model.workspace.sessionTitles[kimiReference("kimi-manual").id] == "User chosen Kimi name")
        print("PASS: existing remote and manual Kimi titles do not start naming requests")

        var namingStart: CheckedContinuation<Void, Error>?
        model.sessionNamer = { configuration, excerpt, language in
            calls += 1
            precondition(excerpt == firstMessage)
            try await withCheckedThrowingContinuation { namingStart = $0 }
            return try await SessionNamingClient().name(configuration: configuration, apiKey: "fixture", excerpt: excerpt, language: language)
        }
        let beforeLaunch = calls
        let created = try await kimi.createSession(title: "", cwd: "/fixture", initialPrompt: firstMessage)
        let createdReference = kimiReference(created.id)
        model.newKimiCreated(created)
        try await until { kimi.snapshotReady && !kimi.loading }
        precondition(calls == beforeLaunch && kimi.conversation?.messages.isEmpty == true)
        await kimi.sendPrompt(for: created.id)
        kimi.reloadSelected()
        try await until { kimi.snapshotReady && !kimi.loading }
        precondition(kimi.pendingPrompts[created.id]?.contains(where: { $0.status == "unknown" }) == true)
        precondition(calls == beforeLaunch && namingStart == nil && model.workspace.sessionTitles[createdReference.id] == nil)
        print("PASS: empty sessions, drafts and unconfirmed first sends do not trigger naming")

        KimiNamingProtocol.allowPrompts()
        await kimi.sendPrompt(for: created.id)
        precondition(kimi.drafts[created.id] == "")
        kimi.reloadSelected()
        try await until { namingStart != nil }
        precondition(kimi.conversation?.snapshot.session.isTurnRunning == true && kimi.conversation?.snapshot.session.lastTurnReason == nil)
        precondition(calls == beforeLaunch + 1 && model.namingInProgress.contains(createdReference.id))
        precondition(model.workspace.sessionTitles[createdReference.id] == nil)
        kimi.reloadSelected()
        try await until { kimi.snapshotReady && !kimi.loading }
        precondition(calls == beforeLaunch + 1)
        namingStart!.resume(returning: ()); namingStart = nil
        try await until { model.workspace.autoNamedSessions.contains(createdReference.id) || model.namingErrors[createdReference.id] != nil }
        precondition(model.namingErrors[createdReference.id] == nil, model.namingErrors[createdReference.id] ?? "Naming failed")
        precondition(model.selectedItem?.title == "修复登录跳转")
        precondition(kimi.conversation?.snapshot.session.title == firstMessage && kimi.conversation?.snapshot.session.isTurnRunning == true)
        kimi.reloadSelected()
        try await until { kimi.snapshotReady && !kimi.loading }
        precondition(calls == beforeLaunch + 1)
        print("PASS: first accepted Kimi prompt starts one asynchronous HTTP naming request while its turn is running")

        var pending: CheckedContinuation<String, Error>?
        model.sessionNamer = { _, _, _ in
            calls += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        kimi.select("kimi-remote-title")
        try await until { pending != nil }
        KimiNamingProtocol.nameRemotely()
        kimi.reloadSelected()
        try await until { kimi.snapshotReady && !kimi.loading && kimi.conversation?.snapshot.session.title == KimiNamingProtocol.namedTitle }
        pending!.resume(returning: "Should not replace the agent"); pending = nil
        try await until { !model.namingInProgress.contains(kimiReference("kimi-remote-title").id) }
        precondition(model.workspace.sessionTitles[kimiReference("kimi-remote-title").id] == nil)
        precondition(!model.workspace.autoNamedSessions.contains(kimiReference("kimi-remote-title").id))
        print("PASS: a remote Kimi title arriving during naming is not replaced")

        native.select("manual")
        try await until { pending != nil }
        model.workspace.rename(reference("manual"), title: "User chosen name")
        pending!.resume(returning: "Should not replace the user"); pending = nil
        try await until { !model.namingInProgress.contains(reference("manual").id) }
        precondition(model.workspace.sessionTitles[reference("manual").id] == "User chosen name")
        precondition(!model.workspace.autoNamedSessions.contains(reference("manual").id))
        print("PASS: an in-flight automatic result cannot replace a manual name")

        model.sessionNamer = { _, _, _ in calls += 1; throw WorkbenchError("Fixture service unavailable") }
        native.select("failed")
        try await until { model.namingErrors[reference("failed").id] != nil }
        precondition(model.automaticNamingStatus(for: reference("failed")).contains("Fixture service unavailable"))
        let failedCalls = calls
        native.select("first")
        try await until { native.snapshot?.id == "first" }
        native.select("failed")
        try await until { native.snapshot?.id == "failed" }
        try await Task.sleep(for: .milliseconds(30))
        precondition(calls == failedCalls, "Repeated observations must not silently retry a failed request")
        model.sessionNamer = { _, _, _ in calls += 1; return "Recovered name" }
        try settings.updateConfiguration(config)
        try await until { model.workspace.autoNamedSessions.contains(reference("failed").id) }
        precondition(calls == failedCalls + 1 && model.namingErrors[reference("failed").id] == nil)
        print("PASS: failures are visible; saving settings allows exactly one new attempt")

        native.select("partial")
        try await until { native.snapshot?.id == "partial" }
        try await Task.sleep(for: .milliseconds(30))
        precondition(calls == failedCalls + 1 && model.namingExcerpt(for: reference("partial")) == nil)
        print("PASS: partial history cannot name a session from a later prompt")

        model.sessionNamer = { _, _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        native.select("disabled-in-flight")
        try await until { pending != nil }
        settings.disable()
        pending!.resume(returning: "Must not be applied"); pending = nil
        try await until { !model.namingInProgress.contains(reference("disabled-in-flight").id) }
        precondition(model.workspace.sessionTitles[reference("disabled-in-flight").id] == nil)
        model.shutdown()
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier!).appendingPathComponent("workspace.json")
        let saved = try WorkspaceFile.load(from: url)
        precondition(saved.sessionTitles[reference("first").id] == "修复登录跳转")
        precondition(saved.autoNamedSessions.contains(reference("first").id))
        precondition(saved.sessionTitles[createdReference.id] == "修复登录跳转")
        precondition(saved.autoNamedSessions.contains(createdReference.id))
        print("PASS: disabling cancels application of an old result; generated titles persist to disk")
        fflush(stdout)
        exit(0)
    }
}
