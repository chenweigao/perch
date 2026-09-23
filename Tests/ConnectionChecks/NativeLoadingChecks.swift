import Foundation
import WorkbenchCore

@MainActor private final class LoadingTransport {
    var paths: [String] = []
    var busy = false
    var holdHistory = false
    var holdDelta = false
    var revision = 1
    var changes: [Int: String] = [:]
    var pendingDelta: (CheckedContinuation<Data, Error>, Data)?
    var pending: (CheckedContinuation<Data, Error>, Data)?
    func request(_ path: String, _ body: JSONValue?) async throws -> Data {
        paths.append(path)
        let url = URLComponents(string: "http://fixture" + path)!
        let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value!) })
        func summary(_ id: String) -> [String: Any] {
            ["id": id, "provider": "omp", "title": id, "cwd": "/fixture", "busy": busy,
             "archived": false, "updated": 1, "completed": 0, "pending": 0, "model": "m", "revision": revision]
        }
        if url.path == "/sessions" { return try JSONSerialization.data(withJSONObject: ["sessions": [summary("a"), summary("b")]]) }
        let id = String(url.path.split(separator: "/").last!)
        let end = Int(query["before"] ?? "240")!
        let start = Int(query["start"] ?? "") ?? max(0, end - 100)
        var value = summary(id)
        let delta = query["revision"].flatMap(Int.init)
        if delta == revision { return Data(#"{"unchanged":true}"#.utf8) }
        let indices = delta == nil ? Array(start..<end) : changes.keys.filter { $0 >= start }.sorted()
        value["messages"] = indices.map { i in
            ["id": "\(id)-\(i)", "role": i % 2 == 0 ? "user" : "assistant", "created_at": "0",
             "content": [["type": "text", "text": changes[i] ?? "Message \(i)"]]] as [String: Any]
        }
        value["interactions"] = []
        var history: [String: Any] = ["epoch": "one", "start": start, "end": end, "total": 240]
        if let delta { history["baseRevision"] = delta; history["indices"] = indices }
        value["history"] = history
        let data = try JSONSerialization.data(withJSONObject: value)
        if delta != nil && holdDelta {
            return try await withCheckedThrowingContinuation { pendingDelta = ($0, data) }
        }
        if query["before"] != nil && holdHistory {
            return try await withCheckedThrowingContinuation { pending = ($0, data) }
        }
        return data
    }
}

@MainActor func checkNativeLoading() async throws {
    let host = SSHHost(name: "Loading", destination: "fixture")
    for busy in [false, true] {
        let fixture = LoadingTransport(); fixture.busy = busy
        let client = NativeAgentConnection(host: host, transport: fixture.request)
        let start = Date(timeIntervalSince1970: 1000)
        for tick in 0..<50 { try await client.poll(now: start.addingTimeInterval(Double(tick) * 0.4)) }
        let count = fixture.paths.filter { $0 == "/sessions" }.count
        precondition(count == (busy ? 10 : 4), "Catalog refresh did not respect active/idle cadence")
        try await client.refresh()
        precondition(fixture.paths.filter { $0 == "/sessions" }.count == count + 1)
    }
    let fixture = LoadingTransport()
    let client = NativeAgentConnection(host: host, transport: fixture.request)
    try await client.refresh(); client.select("a")
    await ConnectionChecks.settle { client.snapshot?.id == "a" }
    precondition(client.snapshot?.messages.count == 100 && client.snapshot?.history?.start == 140)
    client.loadOlder(); client.loadOlder()
    await ConnectionChecks.settle { !client.loadingOlder }
    precondition(client.snapshot?.messages.count == 200 && client.snapshot?.history?.start == 40)
    precondition(fixture.paths.filter { $0.contains("before=") }.count == 1, "Overlapping pages were requested")
    client.select("b"); await ConnectionChecks.settle { client.snapshot?.id == "b" }
    client.select("a"); await ConnectionChecks.settle { client.snapshot?.id == "a" }
    precondition(client.snapshot?.history?.start == 40, "Returning to a session discarded its reading window")
    client.loadAllHistoryForSearch(); await ConnectionChecks.settle { !client.loadingOlder }
    precondition(client.snapshot?.messages.count == 240 && client.snapshot?.hasOlder == false)
    client.select("b"); await ConnectionChecks.settle { client.snapshot?.id == "b" }
    fixture.holdHistory = true; client.loadOlder()
    await ConnectionChecks.settle { fixture.pending != nil }
    client.select("a"); await ConnectionChecks.settle { client.snapshot?.id == "a" }
    let pending = fixture.pending!; fixture.pending = nil; pending.0.resume(returning: pending.1)
    for _ in 0..<20 { await Task.yield() }
    precondition(client.snapshot?.id == "a" && client.snapshot?.messages.count == 240 && !client.loadingOlder)
    client.disconnect()
    let racing = LoadingTransport()
    let raced = NativeAgentConnection(host: host, transport: racing.request)
    try await raced.refresh(); raced.select("a")
    await ConnectionChecks.settle { raced.snapshot?.id == "a" }
    racing.revision = 2; racing.changes[100] = "earlier edit"; racing.holdDelta = true
    let refresh = Task { try await raced.poll() }
    await ConnectionChecks.settle { racing.pendingDelta != nil }
    raced.loadOlder(); await ConnectionChecks.settle { !raced.loadingOlder }
    precondition(raced.snapshot?.history?.start == 40)
    racing.revision = 3; racing.changes[101] = "edit after page"
    let delayed = racing.pendingDelta!; racing.pendingDelta = nil; racing.holdDelta = false
    delayed.0.resume(returning: delayed.1); try await refresh.value
    precondition(raced.snapshot?.revision == 1, "Old-window response skipped newly loaded history edits")
    try await raced.poll()
    precondition(raced.snapshot?.revision == 3 && raced.snapshot?.messages[61].content.first?.text == "edit after page")
    raced.disconnect()
    print("PASS: native catalog cadence, initial page, duplicate-load suppression, complete history, return window and stale page isolation")
}
