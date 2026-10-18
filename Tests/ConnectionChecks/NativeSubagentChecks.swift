import Foundation
import Observation
import WorkbenchCore

/// Bridge protocol 7 routes for sessions "a" and "b": the snapshot roster,
/// transcript windows, deltas by revision, older pages and the stop route.
/// Answers are computed when a request arrives; held ones return late.
@MainActor private final class SubagentTransport {
    var provider = "claude"
    var busy = true
    /// nil models a bridge before protocol 7: snapshots carry no `subagents`.
    var roster: [[String: Any]]? = [SubagentTransport.entry("toolu_live", status: "running", canStop: true),
                                    SubagentTransport.entry("toolu_done", status: "completed", canStop: false)]
    var epoch = "e1"
    var revision = 1
    var messages: [[String: Any]] = (0..<6).map { SubagentTransport.message("m\($0)") }
    var versions = [1, 1, 1, 1, 1, 1]
    var snapshotRevision = 1
    var holdTranscript = false
    var holdStop = false
    var stopFailure: String?
    var pendingTranscripts: [CheckedContinuation<Void, Never>] = []
    var pendingStops: [CheckedContinuation<Void, Never>] = []
    private(set) var transcriptPaths: [String] = []
    private(set) var stopPaths: [String] = []
    private(set) var stopBodies: [JSONValue?] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0

    nonisolated static func entry(_ id: String, status: String, canStop: Bool) -> [String: Any] {
        ["id": id, "kind": "claude", "taskId": "task-" + id, "toolUseIds": [id], "description": "检查 " + id,
         "subagentType": "Explore", "status": status, "canStop": canStop, "stopRequested": false,
         "startedAt": "2026-10-18T05:30:00.000Z", "updatedAt": "2026-10-18T05:30:10.000Z",
         "usage": ["totalTokens": 900, "toolUses": 2, "durationMs": 10000], "lastToolName": "Read"]
    }
    nonisolated static func message(_ id: String) -> [String: Any] {
        ["id": id, "role": "assistant", "created_at": "0", "content": [["type": "text", "text": "Message " + id]]]
    }
    /// An entry change: the next snapshot's roster and the next transcript read.
    func update(_ id: String, _ fields: [String: Any]) {
        guard let index = roster?.firstIndex(where: { $0["id"] as? String == id }) else { return }
        roster?[index].merge(fields) { _, new in new }
        revision += 1; snapshotRevision += 1
    }
    func append(_ id: String) {
        revision += 1
        messages.append(Self.message(id)); versions.append(revision)
    }
    func releaseTranscript() { pendingTranscripts.removeFirst().resume() }

    private func summary(_ id: String) -> [String: Any] {
        ["id": id, "provider": provider, "title": id, "cwd": "/fixture", "busy": busy, "archived": false,
         "updated": 1.0, "completed": 0, "pending": 0, "model": "fixture", "turnId": "turn-1"]
    }

    func request(_ path: String, _ body: JSONValue?) async throws -> Data {
        let url = URLComponents(string: "http://fixture" + path)!
        let parts = url.path.split(separator: "/").map(String.init)
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        if url.path == "/sessions" {
            return try JSONSerialization.data(withJSONObject: ["sessions": [summary("a"), summary("b")]])
        }
        if parts.count == 2 {
            var value = summary(parts[1])
            value["revision"] = snapshotRevision; value["messages"] = []; value["interactions"] = []
            if let roster { value["subagents"] = parts[1] == "a" ? roster : [] }
            return try JSONSerialization.data(withJSONObject: value)
        }
        if parts.count == 5, parts[2] == "subagents", parts[4] == "stop", body != nil {
            stopPaths.append(path); stopBodies.append(body)
            if holdStop { await withCheckedContinuation { pendingStops.append($0) } }
            if let stopFailure { throw WorkbenchError(stopFailure) }
            // The bridge marks the request and touches the session before answering.
            if let index = roster?.firstIndex(where: { $0["id"] as? String == parts[3] }) {
                roster?[index]["stopRequested"] = true
                roster?[index]["stopError"] = NSNull()
                snapshotRevision += 1
            }
            return Data(#"{"ok":true}"#.utf8)
        }
        guard parts.count == 4, parts[2] == "subagents", body == nil else { throw WorkbenchError("Unexpected route: \(path)") }
        guard let entry = roster?.first(where: { candidate in
            candidate["id"] as? String == parts[3] || (candidate["toolUseIds"] as? [String])?.contains(parts[3]) == true
        }) else { throw WorkbenchError("未找到该子 Agent") }
        transcriptPaths.append(path)
        inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        let count = messages.count
        var page: [String: Any] = ["entry": entry, "epoch": epoch, "revision": revision, "total": count, "truncated": 0]
        let data: Data
        if let before = query["before"].flatMap({ Int($0) }) {
            let end = min(max(0, before), count)
            let start = max(0, end - (query["limit"].flatMap({ Int($0) }) ?? 100))
            page["start"] = start; page["messages"] = Array(messages[start..<end])
            data = try JSONSerialization.data(withJSONObject: page)
        } else if query["epoch"] == epoch, let since = query["revision"].flatMap({ Int($0) }), since <= revision {
            if since == revision { data = Data(#"{"unchanged":true}"#.utf8) } else {
                page["changes"] = versions.indices.filter { versions[$0] > since }.map { index -> [String: Any] in
                    ["index": index, "message": messages[index]]
                }
                data = try JSONSerialization.data(withJSONObject: page)
            }
        } else {
            let start = max(0, count - 4)
            page["start"] = start; page["messages"] = Array(messages[start..<count])
            data = try JSONSerialization.data(withJSONObject: page)
        }
        if holdTranscript { await withCheckedContinuation { pendingTranscripts.append($0) } }
        return data
    }
}

/// Every pause of the follow loop records its seconds and waits for the check.
@MainActor private final class FollowClock {
    private(set) var pauses: [Double] = []
    private var waiting: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiting != nil }
    func sleep(_ seconds: Double) async throws {
        pauses.append(seconds)
        await withCheckedContinuation { waiting = $0 }
        try Task.checkCancellation()
    }
    func advance() {
        let next = waiting
        waiting = nil
        next?.resume()
    }
}

@MainActor private final class SleepLog { var slept: [Double] = [] }

private final class SubagentInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.lock(); changed = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

@MainActor private func subagentClient(_ fixture: SubagentTransport, clock: FollowClock) async throws -> NativeAgentConnection {
    let client = NativeAgentConnection(host: SSHHost(name: "Subagents", destination: "fixture"), transport: fixture.request)
    // One sleep per pause, so each pause shows its full length.
    client.subagents.cadence.slice = 100
    client.subagents.sleep = { try await clock.sleep($0) }
    try await client.refresh()
    client.select("a")
    await ConnectionChecks.settle { client.snapshot?.id == "a" }
    return client
}

private let liveSubject = NativeSubagentSubject(sessionID: "a", key: "toolu_live")

@MainActor func checkNativeSubagentConnection() async throws {
    try await checkSubagentFollow()
    try await checkSubagentLateReplies()
    try await checkSubagentOlderSerialization()
    try await checkSubagentStop()
    try await checkSubagentWithoutRoster()
}

/// Routes, the full-then-delta follow, the live and idle cadence, aliases, and
/// Observation isolation between the transcript and the snapshot's readers.
@MainActor private func checkSubagentFollow() async throws {
    let fixture = SubagentTransport(), clock = FollowClock()
    let client = try await subagentClient(fixture, clock: clock)
    precondition(client.snapshot?.subagents?.map(\.id) == ["toolu_live", "toolu_done"] && client.snapshot?.opensSubagents == true)
    // An alias opens the entry it names: here the task id.
    client.openSubagent("task-toolu_live", in: "a")
    precondition(client.subagents.presented == liveSubject, "Any alias opens the entry under its id")
    client.openSubagent("toolu_done", in: "b")
    precondition(client.subagents.presented == liveSubject, "Another session's request opens nothing")
    let follow = Task { await client.followSubagent(liveSubject) }
    await ConnectionChecks.settle { clock.isWaiting }
    precondition(fixture.transcriptPaths == ["/sessions/a/subagents/toolu_live"], "A follow starts with a full read")
    precondition(client.subagents.transcript?.messages.map(\.id) == ["m2", "m3", "m4", "m5"]
                 && client.subagents.transcript?.start == 2 && client.subagents.transcript?.hasOlder == true)
    precondition(!client.subagents.loading && client.subagents.error == nil)
    precondition(clock.pauses == [1], "A live entry is read again after one second")

    // An unchanged answer publishes nothing; a delta reaches only the transcript.
    let reader = SubagentInvalidation(), sheet = SubagentInvalidation()
    withObservationTracking {
        _ = client.snapshot; _ = client.selectedID; _ = client.subagents.presented
        _ = client.subagents.stopping; _ = client.subagents.stopErrors
    } onChange: { reader.mark() }
    withObservationTracking {
        _ = client.subagents.transcript; _ = client.subagents.loading; _ = client.subagents.error
    } onChange: { sheet.mark() }
    clock.advance()
    await ConnectionChecks.settle { clock.pauses.count == 2 }
    precondition(fixture.transcriptPaths.last == "/sessions/a/subagents/toolu_live?epoch=e1&revision=1")
    precondition(!sheet.value, "An unchanged follow read must not invalidate the sheet")
    fixture.append("m6")
    clock.advance()
    await ConnectionChecks.settle { clock.pauses.count == 3 }
    precondition(client.subagents.transcript?.messages.map(\.id) == ["m2", "m3", "m4", "m5", "m6"] && clock.pauses.last == 1)
    precondition(sheet.value && !reader.value, "Transcript reads must not invalidate the conversation's readers")

    // Once the entry finishes, reads slow to every four seconds.
    fixture.update("toolu_live", ["status": "completed", "canStop": false])
    clock.advance()
    await ConnectionChecks.settle { clock.pauses.count == 4 }
    precondition(client.subagents.transcript?.entry?.status == .completed && clock.pauses.last == 4)
    precondition(client.subagentEntry(for: liveSubject)?.status == .completed, "The sheet describes the transcript's entry")
    follow.cancel(); clock.advance(); await follow.value
    precondition(fixture.stopPaths.isEmpty, "Following never stops a subagent")

    // A Claude call the snapshot no longer lists is still read under its alias;
    // a runtime whose subagents the bridge does not record opens nothing.
    client.openSubagent("toolu_earlier", in: "a")
    precondition(client.subagents.presented == NativeSubagentSubject(sessionID: "a", key: "toolu_earlier"))
    client.subagents.present(nil)
    fixture.provider = "omp"
    client.select("b"); client.select("a")
    await ConnectionChecks.settle { client.snapshot?.id == "a" && client.snapshot?.provider == .omp }
    precondition(client.snapshot?.opensSubagents == false)
    client.openSubagent("toolu_earlier", in: "a")
    precondition(client.subagents.presented == nil)
    client.openSubagent("toolu_live", in: "a")
    precondition(client.subagents.presented == liveSubject, "A listed entry opens whatever the runtime")
    client.disconnect()
    print("PASS: native subagent follow: alias routes, full then delta reads, 1 s live / 4 s idle cadence, isolated invalidation")
}

/// Late replies after a selection change, an A-B-A reopen, a closed sheet and a
/// disconnect never land; none of them stops the subagent.
@MainActor private func checkSubagentLateReplies() async throws {
    let fixture = SubagentTransport(), clock = FollowClock()
    let client = try await subagentClient(fixture, clock: clock)
    fixture.holdTranscript = true

    client.openSubagent("toolu_live", in: "a")
    let switched = Task { await client.followSubagent(liveSubject) }
    await ConnectionChecks.settle { fixture.pendingTranscripts.count == 1 }
    precondition(client.subagents.loading, "The first read shows progress")
    client.select("b")
    await ConnectionChecks.settle { client.snapshot?.id == "b" }
    precondition(client.subagents.presented == nil, "Switching sessions closes the sheet")
    fixture.releaseTranscript(); await switched.value
    precondition(client.subagents.transcript == nil && client.subagents.error == nil && !client.subagents.loading,
                 "A reply after the selection changed must not land")

    // A-B-A: a stale reply of a new epoch must not reset the reopened sheet.
    client.select("a")
    await ConnectionChecks.settle { client.snapshot?.id == "a" }
    client.openSubagent("toolu_live", in: "a")
    let stale = Task { await client.followSubagent(liveSubject) }
    await ConnectionChecks.settle { fixture.pendingTranscripts.count == 1 }
    client.subagents.present(nil)
    client.openSubagent("toolu_live", in: "a")
    fixture.epoch = "e2"; fixture.append("m6")
    let current = Task { await client.followSubagent(liveSubject) }
    await ConnectionChecks.settle { fixture.pendingTranscripts.count == 2 }
    fixture.holdTranscript = false
    fixture.pendingTranscripts.removeLast().resume()
    await ConnectionChecks.settle { clock.isWaiting }
    precondition(client.subagents.transcript?.epoch == "e2" && client.subagents.transcript?.messages.last?.id == "m6")
    fixture.releaseTranscript(); await stale.value
    precondition(client.subagents.transcript?.epoch == "e2" && client.subagents.transcript?.messages.last?.id == "m6",
                 "A replaced follower's reply must not land in the reopened sheet")
    current.cancel(); clock.advance(); await current.value

    // Closing the sheet cancels its read.
    fixture.holdTranscript = true
    client.subagents.present(nil)
    client.openSubagent("toolu_live", in: "a")
    let closed = Task { await client.followSubagent(liveSubject) }
    await ConnectionChecks.settle { fixture.pendingTranscripts.count == 1 }
    client.subagents.present(nil); closed.cancel()
    fixture.releaseTranscript(); await closed.value
    precondition(client.subagents.transcript == nil && client.subagents.error == nil)

    // Disconnecting cancels the reads and closes the sheet.
    client.openSubagent("toolu_live", in: "a")
    let dropped = Task { await client.followSubagent(liveSubject) }
    await ConnectionChecks.settle { fixture.pendingTranscripts.count == 1 }
    client.disconnect()
    precondition(client.subagents.presented == nil && !client.online)
    fixture.releaseTranscript(); await dropped.value
    precondition(client.subagents.transcript == nil && client.subagents.error == nil)
    precondition(fixture.stopPaths.isEmpty, "Closing, switching and disconnecting never stop a subagent")
    print("PASS: native subagent late replies after selection change, A-B-A reopen, close and disconnect are dropped; nothing stops the agent")
}

/// An older page asked for during a follow read waits for it, skips the pause
/// and never overlaps another read of the same transcript.
@MainActor private func checkSubagentOlderSerialization() async throws {
    let fixture = SubagentTransport(), clock = FollowClock()
    let client = try await subagentClient(fixture, clock: clock)
    client.openSubagent("toolu_live", in: "a")
    let follow = Task { await client.followSubagent(liveSubject) }
    await ConnectionChecks.settle { clock.isWaiting }
    fixture.holdTranscript = true
    clock.advance()
    await ConnectionChecks.settle { fixture.pendingTranscripts.count == 1 }
    client.loadOlderSubagent(); client.loadOlderSubagent()
    precondition(client.subagents.loadingOlder)
    for _ in 0..<50 { await Task.yield() }
    precondition(!fixture.transcriptPaths.contains { $0.contains("before=") }, "The older page waits for the read in flight")
    fixture.releaseTranscript()
    await ConnectionChecks.settle { fixture.pendingTranscripts.count == 1 }
    precondition(fixture.transcriptPaths.last == "/sessions/a/subagents/toolu_live?epoch=e1&before=2&limit=100")
    precondition(clock.pauses.count == 1, "An asked-for page does not wait out the pause")
    fixture.holdTranscript = false
    fixture.releaseTranscript()
    await ConnectionChecks.settle { clock.isWaiting && !client.subagents.loadingOlder }
    precondition(client.subagents.transcript?.messages.map(\.id) == ["m0", "m1", "m2", "m3", "m4", "m5"]
                 && client.subagents.transcript?.hasOlder == false)
    precondition(fixture.maxInFlight == 1, "Reads of one transcript never overlap")
    precondition(fixture.transcriptPaths.filter { $0.contains("before=") }.count == 1, "A repeated request reads one page")
    follow.cancel(); clock.advance(); await follow.value
    client.disconnect()

    // The pause ends early only for a page that will be read; offline, the loop
    // drops the request, so the pause waits instead of spinning.
    let state = NativeSubagentState()
    let log = SleepLog()
    state.sleep = { log.slept.append($0) }
    let subject = NativeSubagentSubject(sessionID: "a", key: "k")
    state.present(subject)
    guard let token = state.beginFollowing(subject) else { preconditionFailure("The presented subject follows") }
    let window = #"{"epoch":"e1","revision":1,"total":6,"truncated":0,"start":2,"messages":[{"id":"m2","role":"assistant","created_at":"0","content":[{"type":"text","text":"two"}]}]}"#
    state.apply(try NativeAgentWire.decode(NativeSubagentPage.self, from: Data(window.utf8)), follower: token)
    precondition(state.transcript?.hasOlder == true && !state.loading)
    try await state.pause(1, follower: token)
    precondition(!log.slept.isEmpty && abs(log.slept.reduce(0, +) - 1) < 1e-9, "A pause waits its full length in slices")
    log.slept = []
    state.requestOlder()
    try await state.pause(1, follower: token)
    precondition(log.slept.isEmpty && state.loadingOlder, "An asked-for page ends the pause")
    state.cancelOlder()
    try await state.pause(1, follower: token)
    precondition(!log.slept.isEmpty && !state.loadingOlder, "A dropped page no longer ends the pause")
    precondition(state.takeOlderQuery(token) == nil)
    print("PASS: native subagent older pages are serialized with follow reads, skip the pause and prepend once")
}

/// One subagent stops on its own: one request, 停止中 until the roster shows an
/// outcome, request and worker failures, a read issued before acceptance, and the timeout.
@MainActor private func checkSubagentStop() async throws {
    let fixture = SubagentTransport(), clock = FollowClock()
    let client = try await subagentClient(fixture, clock: clock)
    client.stopSubagent("toolu_done", in: "a")
    client.stopSubagent("toolu_live", in: "b")
    client.stopSubagent("missing", in: "a")
    precondition(fixture.stopPaths.isEmpty && client.subagents.stopping.isEmpty,
                 "Finished entries, other sessions and unknown keys send nothing")

    fixture.holdStop = true
    fixture.update("toolu_live", ["stopError": "earlier attempt failed"])
    try await client.poll()
    client.stopSubagent("task-toolu_live", in: "a"); client.stopSubagent("toolu_live", in: "a")
    precondition(client.subagents.stopping == ["toolu_live"])
    await ConnectionChecks.settle { fixture.pendingStops.count == 1 }
    precondition(fixture.stopPaths == ["/sessions/a/subagents/toolu_live/stop"] && fixture.stopBodies == [.object([:])])
    try await client.poll()
    precondition(client.subagents.stopping == ["toolu_live"], "A roster read issued before acceptance cannot settle the stop")
    precondition(client.subagentStopErrors(in: client.snapshot!).isEmpty, "No error shows while a stop is pending")
    fixture.pendingStops.removeFirst().resume()
    await ConnectionChecks.settle { client.subagents.isStopAccepted("toolu_live") }
    try await client.poll()
    precondition(client.subagents.stopping == ["toolu_live"], "Acceptance alone is not an outcome")
    fixture.update("toolu_live", ["status": "stopped", "canStop": false])
    try await client.poll()
    precondition(client.subagents.stopping.isEmpty && client.subagentStopErrors(in: client.snapshot!).isEmpty)
    client.disconnect()

    // The worker reports a failure: the row offers stop again with the bridge's reason.
    let worker = SubagentTransport(), workerClock = FollowClock()
    let reported = try await subagentClient(worker, clock: workerClock)
    reported.stopSubagent("toolu_live", in: "a")
    await ConnectionChecks.settle { reported.subagents.isStopAccepted("toolu_live") }
    worker.update("toolu_live", ["stopRequested": false, "stopError": "Query.stopTask failed"])
    try await reported.poll()
    precondition(reported.subagents.stopping.isEmpty)
    precondition(reported.subagentStopErrors(in: reported.snapshot!) == ["toolu_live": "Query.stopTask failed"])
    reported.disconnect()

    // The request itself fails.
    let refused = SubagentTransport(), refusedClock = FollowClock()
    refused.stopFailure = "该子 Agent 当前无法单独停止"
    let rejected = try await subagentClient(refused, clock: refusedClock)
    rejected.stopSubagent("toolu_live", in: "a")
    await ConnectionChecks.settle { rejected.subagents.stopping.isEmpty }
    precondition(rejected.subagentStopErrors(in: rejected.snapshot!) == ["toolu_live": "该子 Agent 当前无法单独停止"])
    refused.stopFailure = nil
    rejected.stopSubagent("toolu_live", in: "a")
    precondition(rejected.subagentStopErrors(in: rejected.snapshot!).isEmpty, "A new attempt clears the last error")
    await ConnectionChecks.settle { rejected.subagents.isStopAccepted("toolu_live") }
    rejected.disconnect()
    precondition(rejected.subagents.stopping.isEmpty, "Disconnecting forgets pending stops")

    // No outcome within the timeout offers stop again, without an error.
    let silent = SubagentTransport(), silentClock = FollowClock()
    let waiting = try await subagentClient(silent, clock: silentClock)
    waiting.subagents.stopTimeout = 0.05
    waiting.stopSubagent("toolu_live", in: "a")
    await ConnectionChecks.settle { waiting.subagents.isStopAccepted("toolu_live") }
    try? await Task.sleep(for: .milliseconds(300))
    precondition(waiting.subagents.stopping.isEmpty && waiting.subagents.stopErrors.isEmpty)
    precondition(silent.stopPaths.count == 1)
    waiting.disconnect()
    print("PASS: native subagent stop: one request, pending until the roster settles it, request/worker failures, early reads and timeout")
}

/// A bridge before protocol 7 reports no roster: nothing new opens or stops.
@MainActor private func checkSubagentWithoutRoster() async throws {
    let fixture = SubagentTransport(), clock = FollowClock()
    fixture.roster = nil
    let client = try await subagentClient(fixture, clock: clock)
    precondition(client.snapshot?.subagents == nil && client.snapshot?.opensSubagents == false)
    client.openSubagent("toolu_live", in: "a")
    client.stopSubagent("toolu_live", in: "a")
    client.loadOlderSubagent()
    precondition(client.subagents.presented == nil && client.subagents.stopping.isEmpty)
    precondition(client.subagentStopErrors(in: client.snapshot!).isEmpty)
    for _ in 0..<20 { await Task.yield() }
    precondition(fixture.transcriptPaths.isEmpty && fixture.stopPaths.isEmpty)
    client.disconnect()
    print("PASS: native snapshot without subagents opens, reads and stops nothing")
}
