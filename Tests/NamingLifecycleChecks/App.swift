import AppKit
import Foundation
import WorkbenchCore

private final class KimiNamingProtocol: URLProtocol {
    static let prompt = "Fix the login redirect loop in the sample app"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path
        let id = String(path.split(separator: "/")[3])
        let value: Any
        if path.hasSuffix("/snapshot") {
            value = ["epoch": "fixture", "as_of_seq": 10,
                "session": ["id": id, "title": Self.prompt, "updated_at": "fixture", "busy": false,
                            "last_turn_reason": "completed", "metadata": ["cwd": "/fixture"], "agent_config": ["model": "fixture/model"]],
                "messages": ["items": [["id": "user-" + id, "role": "user", "created_at": "",
                                        "content": [["type": "text", "text": Self.prompt]]]], "has_more": false],
                "pending_approvals": [], "pending_questions": []] as [String: Any]
        } else if path.hasSuffix("/prompts") { value = ["active": NSNull(), "queued": []] }
        else if path.hasSuffix("/tasks") { value = ["items": []] }
        else if path.hasSuffix("/goal") { value = NSNull() }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["code": 0, "data": value]))
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
        config.baseURL = "http://localhost:8000/v1"; config.model = "fixture"; config.nameSessions = true
        try settings.updateConfiguration(config)
        let firstMessage = "Fix the login redirect loop in the sample app"
        let native = NativeAgentConnection(host: host) { path, _ in
            let id = String(path.split(separator: "?")[0].split(separator: "/").last!)
            var snapshot: [String: Any] = ["id": id, "provider": "omp", "title": firstMessage,
                "cwd": "/fixture", "busy": false, "revision": 1, "completed": 1, "model": "fixture",
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

        let kimiConfiguration = URLSessionConfiguration.ephemeral
        kimiConfiguration.protocolClasses = [KimiNamingProtocol.self]
        let kimi = KimiConnection(host: host, api: KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: kimiConfiguration))
        kimi.select("kimi-loaded")
        try await until { kimi.snapshotReady && !kimi.loading }
        model.registerEnvironment(kimi: kimi, native: native)
        func kimiReference(_ id: String) -> SessionReference { SessionReference(hostID: host.id, terminalID: id, kind: .kimi) }
        try await until { model.workspace.autoNamedSessions.contains(kimiReference("kimi-loaded").id) }
        kimi.select("kimi-next")
        try await until { model.workspace.autoNamedSessions.contains(kimiReference("kimi-next").id) }
        precondition(model.workspace.sessionTitles[kimiReference("kimi-loaded").id] == "修复登录跳转")
        precondition(model.workspace.sessionTitles[kimiReference("kimi-next").id] == "修复登录跳转")
        print("PASS: Kimi naming bridge catches up a loaded conversation and receives later snapshots")

        var pending: CheckedContinuation<String, Error>?
        model.sessionNamer = { _, _, _ in
            calls += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
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
        print("PASS: disabling cancels application of an old result; generated titles persist to disk")
        fflush(stdout)
        exit(0)
    }
}
