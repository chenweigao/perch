import Darwin
import Foundation
import WorkbenchCore

/// A real Unix peer. It withholds its reply until an async consumer observes the
/// request, so a single cooperative worker blocked in read cannot pass this test.
private struct JSONSocketPeer {
    enum Event { case request(Data), closed }
    let path = "/tmp/perch-socket-\(UUID().uuidString.prefix(12))"
    let events: AsyncStream<Event>
    let reply = DispatchSemaphore(value: 0)

    init(chunks: [Data]) throws {
        let socketPath = path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            _ = socketPath.withCString { strlcpy(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), $0, bytes.count) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && Darwin.listen(fd, 1) == 0)
        let pair = AsyncStream<Event>.makeStream()
        events = pair.stream
        let reply = reply
        DispatchQueue(label: "perch.tests.socket-peer").async {
            defer { Darwin.close(fd); unlink(socketPath); pair.continuation.finish() }
            let client = Darwin.accept(fd, nil, nil)
            precondition(client >= 0)
            defer { Darwin.close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var bytes = [UInt8](repeating: 0, count: 1024)
            var request = Data()
            while !request.contains(10) {
                let count = Darwin.read(client, &bytes, bytes.count)
                precondition(count > 0)
                request.append(contentsOf: bytes[..<count])
            }
            pair.continuation.yield(.request(request))
            // This wait belongs to the test peer's Dispatch thread, not a Task.
            precondition(reply.wait(timeout: .now() + 5) == .success,
                         "Cooperative executor could not resume while JSONSocket awaited its peer")
            for chunk in chunks {
                chunk.withUnsafeBytes { buffer in
                    precondition(Darwin.write(client, buffer.baseAddress, buffer.count) == buffer.count)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if !chunks.isEmpty {
                precondition(Darwin.read(client, &bytes, bytes.count) == 0, "Client must close its socket after a reply")
            }
            pair.continuation.yield(.closed)
        }
    }
}

func checkJSONSocket() async throws {
    for cancelled in [false, true] {
        let peer = try JSONSocketPeer(chunks: [Data("{\"ok\":".utf8), Data("true}\nignored".utf8)])
        let request = Task { try await JSONSocket.request(path: peer.path, method: "fixture", params: ["value": 42]) }
        var events = peer.events.makeAsyncIterator()
        guard case .request(let packet) = await events.next() else { preconditionFailure("Missing request") }
        let object = try JSONSerialization.jsonObject(with: packet) as! [String: Any]
        precondition(object["method"] as? String == "fixture" && object["id"] is String)
        precondition((object["params"] as? [String: Int])?["value"] == 42)
        if cancelled { request.cancel() }
        peer.reply.signal()
        do {
            let data = try await request.value
            precondition(!cancelled && data == Data("{\"ok\":true}".utf8))
        } catch is CancellationError { precondition(cancelled) }
        guard case .closed = await events.next() else { preconditionFailure("Missing close") }
    }
    let closedPeer = try JSONSocketPeer(chunks: [])
    let failed = Task { try await JSONSocket.request(path: closedPeer.path, method: "fixture") }
    var events = closedPeer.events.makeAsyncIterator()
    guard case .request = await events.next() else { preconditionFailure("Missing request") }
    closedPeer.reply.signal()
    do { _ = try await failed.value; preconditionFailure("EOF must fail") }
    catch is WorkbenchError { }

    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await JSONSocket.request(path: "/no-such-perch-socket", method: "fixture")
    }
    do { _ = try await cancelled.value; preconditionFailure("Cancelled request must fail before connecting") }
    catch is CancellationError { }
    print("PASS: async Unix socket framing, executor progress, cancellation, peer EOF and descriptor cleanup")
}
