import AppKit
import SwiftUI
import WorkbenchCore

/// The real Kimi task-panel path, using in-process HTTP records and no saved hosts.
private final class TaskSummaryProtocol: URLProtocol {
    static let command = "cd /project && swift build -c release > /tmp/build.log 2>&1"
    static let session: [String: Any] = ["id": "summary", "title": "任务摘要与辅助文字", "updated_at": "fixture",
        "busy": true, "metadata": ["cwd": "/project"], "agent_config": ["model": "fixture/model"]]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path
        let value: [String: Any]
        if path == "/api/v1/sessions" { value = ["items": [Self.session], "has_more": false] }
        else if path.hasSuffix("/snapshot") {
            value = ["epoch": "fixture", "as_of_seq": 0, "session": Self.session,
                     "messages": ["items": [], "has_more": false], "pending_approvals": [], "pending_questions": []]
        } else if path.hasSuffix("/tasks") {
            value = ["items": [
                ["id": "build", "kind": "bash", "description": "Bash: " + Self.command,
                 "command": Self.command, "status": "running"],
                ["id": "failure", "kind": "bash", "description": "核对测试失败原因", "command": "pytest -q", "status": "failed"],
                ["id": "unknown", "kind": "subagent", "description": "核对远端连接状态", "status": "unknown"],
                ["id": "done", "kind": "bash", "description": "整理构建报告", "command": "cat /tmp/build.log", "status": "completed"],
                ["id": "cancelled", "kind": "bash", "description": "旧版本校验", "status": "cancelled"]
            ]]
        } else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["code": 0, "data": value]))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor func checkTaskSummary() async throws {
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    AppLanguage.applyToSystem(.zhHans)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TaskSummaryProtocol.self]
    let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "摘要预览", destination: "")
    let api = KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: configuration)
    let kimi = KimiConnection(host: host, api: api)
    try await kimi.refreshSessions()
    let model = WorkbenchModel()
    defer { model.taskContextWindow.close(); model.shutdown(); api.invalidate() }
    model.connections = [HostConnection(host: host)]
    model.registerEnvironment(kimi: kimi, native: NativeAgentConnection(setupHost: host))
    let reference = SessionReference(hostID: host.id, terminalID: "summary", kind: .kimi)
    let snapshot = try await model.readTaskContext(reference)
    precondition(snapshot.tasks.count == 5 && snapshot.tasks.first?.displayTitle == "构建项目 · swift build")
    model.taskContextWindow.locked = reference
    model.taskContextWindow.show(model: model)
    let window = model.taskContextWindow.window!
    window.setContentSize(NSSize(width: 360, height: 720))
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        UserDefaults.standard.set(name == .aqua ? AppAppearance.light.rawValue : AppAppearance.dark.rawValue,
                                  forKey: AppAppearance.defaultsKey)
        window.appearance = NSAppearance(named: name)
        try await Task.sleep(for: .milliseconds(400))
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(window.isVisible && abs(window.contentView!.bounds.width - 360) < 1)
    }
    print("PASS: production Kimi task panel, compact Bash summary, preserved command, failed/unknown tasks and folded history fixture")
    if CommandLine.arguments.contains("preview") {
        UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: AppAppearance.defaultsKey)
        window.appearance = NSAppearance(named: .aqua)
        while window.isVisible { try await Task.sleep(for: .seconds(1)) }
    }
}
