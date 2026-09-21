import Foundation
import WorkbenchCore

private final class LaunchProtocol: URLProtocol {
    static let lock = NSLock()
    static var failSnapshot = false
    static var failPrompt = false
    static var submissions: [(String, JSONValue)] = []
    static var creations = 0
    static var promptStatus = "running"
    static var failSteer = false
    static var steered: [String] = []
    static var accepted: [[String: Any]] = []
    static func reset(snapshotFailure: Bool = false, promptFailure: Bool = false, status: String = "running", steerFailure: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        failSnapshot = snapshotFailure; failPrompt = promptFailure
        submissions = []; creations = 0; accepted = []; steered = []
        promptStatus = status; failSteer = steerFailure
    }
    static var sent: [(String, JSONValue)] {
        lock.lock(); defer { lock.unlock() }; return submissions
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        let path = request.url!.path
        var status = 200
        var result: [String: Any] = [:]
        func session(_ id: String, updated: String) -> [String: Any] {
            ["id": id, "title": "", "updated_at": updated, "busy": Self.promptStatus == "queued",
             "metadata": ["cwd": "/fixture"], "agent_config": ["model": "fixture/model"]]
        }
        if path == "/api/v1/sessions" {
            Self.creations += 1
            result = session("new", updated: "created")
        } else if path.hasSuffix("/snapshot") {
            if Self.failSnapshot { status = 503 }
            let id = path.split(separator: "/")[3]
            result = ["as_of_seq": 0, "epoch": "fixture", "session": session(String(id), updated: "loaded"),
                      "messages": ["items": [], "has_more": false], "pending_approvals": [], "pending_questions": []]
        } else if path.hasSuffix(":steer") {
            Self.steered.append(path)
            if Self.failSteer { status = 503 }
            result = ["steered": true]
        } else if path.hasSuffix("/prompts") && request.httpMethod == "GET" {
            result = ["active": NSNull(), "queued": Self.steered.isEmpty || Self.failSteer ? Self.accepted : []]
        } else if path.hasSuffix("/prompts") {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try! JSONDecoder().decode(JSONValue.self, from: data)
            Self.submissions.append((path, body))
            result = ["prompt_id": body["prompt_id"].string!, "user_message_id": body["prompt_id"].string!,
                      "status": Self.promptStatus, "content": (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["content"]!]
            if Self.failPrompt { status = 503 } else { Self.accepted.append(result) }
        } else { preconditionFailure("Unexpected route: \(path)") }
        Self.lock.unlock()
        let envelope: [String: Any] = status == 200 ? ["code": 0, "data": result] : ["msg": "fixture unavailable"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: envelope))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
func checkKimiTaskLaunch() async throws {
    for mode in ["selection", "snapshot-failure", "prompt-failure"] {
        LaunchProtocol.reset(snapshotFailure: mode == "snapshot-failure", promptFailure: mode == "prompt-failure")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LaunchProtocol.self]
        let api = KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: configuration)
        let host = SSHHost(name: "Launch fixture", destination: "fixture")
        let connection = KimiConnection(host: host, api: api)
        // Match WorkbenchModel restoring its currently open tab on catalog changes.
        connection.onSessionsChanged = { [weak connection] in connection?.select("old") }
        connection.drafts["old"] = "Existing draft must not be sent"
        let created = try await connection.createSession(title: "", cwd: "/fixture", initialPrompt: "新任务只发送一次", model: "chosen/model")
        precondition(created.id == "new")
        // A selection/snapshot change must not retarget or suppress the launch.
        connection.select("old")
        await connection.sendPrompt(for: created.id)
        let sent = LaunchProtocol.sent
        precondition(sent.count == 1 && sent[0].0 == "/api/v1/sessions/new/prompts")
        precondition(sent[0].1["content"].array.first?["text"].string == "新任务只发送一次")
        precondition(sent[0].1["model"].string == "chosen/model")
        precondition(connection.drafts["old"] == "Existing draft must not be sent")
        precondition(LaunchProtocol.creations == 1)
        if mode == "prompt-failure" {
            precondition(connection.drafts["new"] == "新任务只发送一次")
            precondition(connection.actionError?.contains("草稿已保留") == true)
        } else { precondition(connection.drafts["new"] == "") }
        print("PASS: Kimi task launch \(mode), fixed destination, chosen model, draft retention")
        await ConnectionChecks.settle { !connection.loading }
        connection.disconnect()
        UserDefaults.standard.removeObject(forKey: "kimi.session.\(host.id)")
    }
}

@MainActor
func checkKimiSteering() async throws {
    for mode in ["steer", "next-turn", "steer-failure", "already-running"] {
        LaunchProtocol.reset(status: mode == "already-running" ? "running" : "queued", steerFailure: mode == "steer-failure")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LaunchProtocol.self]
        let api = KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: configuration)
        let client = KimiConnection(host: SSHHost(name: "Steer fixture", destination: "fixture"), api: api)
        client.drafts["active"] = "运行中补充"
        await client.sendPrompt(for: "active", mode: mode == "next-turn" ? .nextTurn : .steer)
        let sent = LaunchProtocol.sent
        precondition(sent.count == 1)
        let id = sent[0].1["prompt_id"].string!
        precondition(client.drafts["active"] == "")
        precondition(client.pendingPrompts["active"]?.first?.text == "运行中补充")
        if mode == "next-turn" || mode == "already-running" {
            precondition(LaunchProtocol.steered.isEmpty)
        } else {
            precondition(LaunchProtocol.steered == ["/api/v1/sessions/active/prompts/\(id):steer"])
            if mode == "steer-failure" {
                precondition(client.pendingPrompts["active"]?.first?.error?.contains("消息已接收") == true)
            } else { precondition(client.pendingPrompts["active"]?.first?.status == "steered") }
        }
        client.disconnect()
        print("PASS: Kimi \(mode), accepted id, visible message, no duplicate submission")
    }
}
