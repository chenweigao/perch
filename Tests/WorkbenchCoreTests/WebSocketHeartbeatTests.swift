import Foundation
import WorkbenchCore

private enum PingFailure: Error { case disconnected, cancelled }

func checkWebSocketHeartbeat() async throws {
    // A pong followed by teardown errors must keep the successful result.
    try await WebSocketHeartbeat.ping { complete in
        complete(nil)
        complete(nil)
        complete(PingFailure.disconnected)
    }

    // Repeated failures (or a late pong) must preserve the first failure.
    do {
        try await WebSocketHeartbeat.ping { complete in
            complete(PingFailure.disconnected)
            complete(PingFailure.cancelled)
            complete(nil)
        }
        fatalError("Expected the first ping failure")
    } catch PingFailure.disconnected { }

    // Exercise the lock with competing callbacks, including success/error races.
    for _ in 0..<100 {
        do {
            try await WebSocketHeartbeat.ping { complete in
                DispatchQueue.concurrentPerform(iterations: 20) { index in
                    complete(index.isMultiple(of: 2) ? nil : PingFailure.disconnected)
                }
            }
        } catch PingFailure.disconnected { }
    }

    // An old socket's delayed callback must not complete a newer ping.
    var oldCallback: (@Sendable (Error?) -> Void)?
    try await WebSocketHeartbeat.ping { complete in
        oldCallback = complete
        complete(nil)
    }
    do {
        try await WebSocketHeartbeat.ping { complete in
            oldCallback?(nil)
            oldCallback?(PingFailure.cancelled)
            complete(PingFailure.disconnected)
        }
        fatalError("Old callback completed a new ping")
    } catch PingFailure.disconnected { }
    print("PASS: WebSocket heartbeat duplicate, concurrent and late callbacks; first result preserved")
}
