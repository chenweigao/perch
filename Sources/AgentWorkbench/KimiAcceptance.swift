#if PERCH_ACCEPTANCE
import Foundation
import WorkbenchCore

/// Fixed HTTP responses through the production Kimi decoder, with no remote fallback.
final class KimiAcceptanceProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private static let lock = NSLock()
    private static var loads: [String: Int] = [:]
    private var reply: DispatchWorkItem?
    override func stopLoading() { reply?.cancel() }
    override func startLoading() {
        let path = request.url!.path
        let id = path.split(separator: "/").dropFirst(3).first.map(String.init) ?? "a"
        let session: [String: Any] = ["id": id, "title": "Kimi 输入隔离 \(id)", "updated_at": "fixture",
            "busy": true, "metadata": ["cwd": "/fixture"], "agent_config": ["model": "fixture/model"]]
        let refresh = ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_MODE"] == "kimi-refresh"
        var revision = 10
        if refresh, path.hasSuffix("/snapshot") {
            Self.lock.lock()
            Self.loads[id, default: 0] += 1
            revision += Self.loads[id]!
            Self.lock.unlock()
        }
        let result: Any
        if path.hasSuffix("/snapshot") {
            let messages: [[String: Any]] = (1...200).flatMap { turn in
                ["user", "assistant"].map { role in
                    ["id": "\(id)-\(role)-\(turn)", "role": role, "created_at": "\(turn)",
                     "content": [["type": "text", "text": "第 \(turn) 轮 · \(role)\n\n中文与 English **正文**和 `identifier`。\n\n" + String(repeating: "持续阅读，后台更新不打断输入。\n\n", count: refresh && turn == 199 && role == "assistant" ? (revision % 2 == 1 ? 100 : 1) : 3)]]] as [String: Any]
                }
            }
            result = ["as_of_seq": revision, "epoch": "fixture", "session": session,
                "messages": ["items": messages, "has_more": false],
                "in_flight_turn": ["turn_id": 201, "assistant_text": "", "thinking_text": "", "running_tools": []],
                "pending_approvals": [], "pending_questions": []]
        } else if path.hasSuffix("/prompts") { result = ["active": NSNull(), "queued": []] }
        else if path.hasSuffix("/tasks") || path.hasSuffix("/models") { result = ["items": []] }
        else if path.hasSuffix("/goal") { result = NSNull() }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": result])
        let deliver = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        reply = deliver
        if refresh, path.hasSuffix("/snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: deliver)
        } else { deliver.perform() }
    }
    @MainActor static func connection(host: SSHHost) -> KimiConnection {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return KimiConnection(host: host, api: KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: configuration))
    }
}
#endif
