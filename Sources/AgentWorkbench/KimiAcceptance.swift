#if PERCH_ACCEPTANCE
import Foundation
import WorkbenchCore

/// Fixed HTTP responses through the production Kimi decoder, with no remote fallback.
final class KimiAcceptanceProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path
        let id = path.split(separator: "/").dropFirst(3).first.map(String.init) ?? "a"
        let session: [String: Any] = ["id": id, "title": "Kimi 输入隔离 \(id)", "updated_at": "fixture",
            "busy": true, "metadata": ["cwd": "/fixture"], "agent_config": ["model": "fixture/model"]]
        let result: Any
        if path.hasSuffix("/snapshot") {
            let messages: [[String: Any]] = (1...200).flatMap { turn in
                ["user", "assistant"].map { role in
                    ["id": "\(id)-\(role)-\(turn)", "role": role, "created_at": "\(turn)",
                     "content": [["type": "text", "text": "第 \(turn) 轮 · \(role)\n\n中文与 English **正文**和 `identifier`。\n\n" + String(repeating: "持续阅读，后台更新不打断输入。\n\n", count: 3)]]] as [String: Any]
                }
            }
            result = ["as_of_seq": 10, "epoch": "fixture", "session": session,
                "messages": ["items": messages, "has_more": false],
                "in_flight_turn": ["turn_id": 201, "assistant_text": "", "thinking_text": "", "running_tools": []],
                "pending_approvals": [], "pending_questions": []]
        } else if path.hasSuffix("/prompts") { result = ["active": NSNull(), "queued": []] }
        else if path.hasSuffix("/tasks") || path.hasSuffix("/models") { result = ["items": []] }
        else if path.hasSuffix("/goal") { result = NSNull() }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": result])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    @MainActor static func connection(host: SSHHost) -> KimiConnection {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return KimiConnection(host: host, api: KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: configuration))
    }
}
#endif
