import Foundation

public enum WebSocketHeartbeat {
    public static func ping(using send: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = PendingPing(continuation)
            send { pending.complete(error: $0) }
        }
    }

    // A pong callback can arrive again during transport teardown. Each ping owns
    // its continuation and atomically consumes it before resuming the waiter.
    private final class PendingPing: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func complete(error: Error?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            guard let continuation else { return }
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}
