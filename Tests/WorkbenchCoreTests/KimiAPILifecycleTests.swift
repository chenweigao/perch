import Foundation
import WorkbenchCore

private final class PendingKimiRequest: URLProtocol {
    private static let lock = NSLock()
    private static var requestStarted = false

    static var started: Bool {
        lock.lock(); defer { lock.unlock() }
        return requestStarted
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requestStarted = true; Self.lock.unlock()
    }
    override func stopLoading() {}
}

func checkKimiAPILifecycle() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PendingKimiRequest.self]
    let api = KimiAPI(baseURL: URL(string: "http://fixture.invalid")!, token: "fixture", configuration: configuration)
    let pending = Task { try await api.request("/api/v1/sessions") }
    for _ in 0..<100 where !PendingKimiRequest.started {
        try await Task.sleep(for: .milliseconds(10))
    }
    precondition(PendingKimiRequest.started, "The request fixture did not start")
    api.invalidate()
    do {
        _ = try await pending.value
        preconditionFailure("Closing the API must cancel its pending request")
    } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {}
    do {
        _ = try await api.request("/api/v1/sessions")
        preconditionFailure("A closed API must reject a late polling request")
    } catch is CancellationError {}
    print("PASS: Kimi API closes with a pending request and rejects late polling")
}
