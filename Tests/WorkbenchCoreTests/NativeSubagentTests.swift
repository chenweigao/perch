import Foundation
import WorkbenchCore

/// Bridge protocol 7 subagents: roster decoding, transcript paging, the
/// activity bar projection, subagent tool names and the shared transcript rows.
func checkNativeSubagents() throws {
    try checkSubagentEntryDecoding()
    try checkSubagentSnapshotRoster()
    try checkSubagentTranscriptPaging()
    try checkSubagentProjection()
    checkSubagentToolNames()
    try checkSubagentTranscriptRows()
}

/// Every key the bridge sends, as the protocol describes the entry. Fractions
/// of a second are binary-exact so elapsed times compare exactly.
private func subagentEntry(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var entry: [String: Any] = [
        "id": "toolu_01A", "kind": "claude", "taskId": "a1b2c3", "toolUseIds": ["toolu_01A"], "turnId": "req-1",
        "description": "定位中文输入问题", "subagentType": "Explore", "status": "running", "background": true,
        "startedAt": "2026-10-18T05:30:09.250Z", "updatedAt": "2026-10-18T05:30:19.250Z", "endedAt": NSNull(),
        "usage": ["totalTokens": 1200, "toolUses": 3, "durationMs": 10000], "lastToolName": "Grep",
        "summary": "找到 2 处竞态", "error": NSNull(), "canStop": true, "stopRequested": false, "stopError": NSNull(),
        "messageCount": 12, "revision": 3,
    ]
    entry.merge(overrides) { _, new in new }
    return entry
}

private func decodeSubagent(_ object: [String: Any]) throws -> NativeSubagent {
    try KimiWire.decoder().decode(NativeSubagent.self, from: JSONSerialization.data(withJSONObject: object))
}

private func decodeJSONValue(_ raw: String) throws -> JSONValue {
    try KimiWire.decoder().decode(JSONValue.self, from: Data(raw.utf8))
}

private func checkSubagentEntryDecoding() throws {
    let full = try decodeSubagent(subagentEntry())
    expectEqual(full.id, "toolu_01A")
    expectEqual(full.kind, "claude")
    expectEqual(full.taskId, "a1b2c3")
    expectEqual(full.toolUseIds, ["toolu_01A"])
    expectEqual(full.turnId, "req-1")
    expectEqual(full.description, "定位中文输入问题")
    expectEqual(full.subagentType, "Explore")
    expectEqual(full.status, .running)
    expectEqual(full.background, true)
    expectEqual(full.startedAt, "2026-10-18T05:30:09.250Z")
    expectEqual(full.updatedAt, "2026-10-18T05:30:19.250Z")
    expectEqual(full.endedAt, nil)
    expectEqual(full.usage, NativeSubagentUsage(totalTokens: 1200, toolUses: 3, durationMs: 10000))
    expectEqual(full.lastToolName, "Grep")
    expectEqual(full.summary, "找到 2 处竞态")
    expectEqual(full.error, nil)
    precondition(full.canStop && !full.stopRequested && full.stopError == nil)
    expectEqual(full.messageCount, 12)
    expectEqual(full.revision, 3)
    precondition(full.status.isLive)
    precondition(full.matches("toolu_01A") && full.matches("a1b2c3") && !full.matches("toolu_other"),
                 "Routes accept the key, the task id and any tool use id")

    for raw in ["queued", "running", "completed", "failed", "stopped", "unknown"] {
        expectEqual(try decodeSubagent(subagentEntry(["status": raw])).status.rawValue, raw)
    }
    let odd: [Any] = ["paused", "killed", "", 7, NSNull()]
    for value in odd {
        expectEqual(try decodeSubagent(subagentEntry(["status": value])).status, .unknown)
    }
    expectEqual(try decodeSubagent(["id": "toolu_00"]).status, .unknown)
    precondition(!NativeSubagentStatus.completed.isLive && NativeSubagentStatus.queued.isLive)

    // Every field but an identifier may be missing or carry the wrong type.
    let sparse = try decodeSubagent(["id": "toolu_02"])
    precondition(sparse.toolUseIds.isEmpty && sparse.taskId == nil && sparse.description == nil)
    precondition(!sparse.canStop && !sparse.stopRequested && sparse.usage == nil && sparse.revision == nil)
    let mistyped = try decodeSubagent(["id": "toolu_03", "usage": "n/a", "canStop": "yes", "toolUseIds": "toolu_03",
                                       "messageCount": "12", "description": 5, "background": NSNull()])
    precondition(mistyped.usage == nil && !mistyped.canStop && mistyped.toolUseIds.isEmpty)
    precondition(mistyped.messageCount == nil && mistyped.description == nil && mistyped.background == nil)
    let partialUsage = try decodeSubagent(["id": "toolu_04", "usage": ["totalTokens": 5, "toolUses": "x"] as [String: Any]])
    expectEqual(partialUsage.usage, NativeSubagentUsage(totalTokens: 5))
    expectEqual(try decodeSubagent(["id": NSNull(), "taskId": "task_5", "toolUseIds": ["toolu_05"]]).id, "task_5")
    expectEqual(try decodeSubagent(["toolUseIds": ["toolu_06", "toolu_07"]]).id, "toolu_06")
    expectThrows(try decodeSubagent(["description": "no identifier"]))

    // Interaction labels arrive inside the untyped interaction list.
    let interaction = try decodeJSONValue(#"{"id":"perm-1","type":"interaction","name":"Bash","subagent":{"id":"toolu_01A","agentId":"a1b2c3","title":"定位中文输入问题","type":"Explore"}}"#)
    guard let label = NativeSubagentLabel(interaction: interaction) else { preconditionFailure("A subagent interaction is labelled") }
    expectEqual(label, NativeSubagentLabel(id: "toolu_01A", agentId: "a1b2c3", title: "定位中文输入问题", type: "Explore"))
    expectEqual(label.name, "定位中文输入问题")
    let roster = [try decodeSubagent(subagentEntry(["id": "toolu_09", "taskId": "z9", "toolUseIds": ["toolu_09"]])), full]
    expectEqual(label.entry(in: roster)?.id, "toolu_01A")
    let unresolved = NativeSubagentLabel(interaction: try decodeJSONValue(#"{"id":"q","subagent":{"id":null,"agentId":"a1b2c3","title":"","type":"Explore"}}"#))
    precondition(unresolved != nil && unresolved?.id == nil && unresolved?.name == "Explore", "An empty title falls back to the type")
    expectEqual(unresolved?.entry(in: roster)?.id, "toolu_01A")
    precondition(NativeSubagentLabel(agentId: "elsewhere").entry(in: roster) == nil && NativeSubagentLabel().name == nil)
    precondition(NativeSubagentLabel(interaction: .object(["id": .string("main")])) == nil, "The main agent's request has no label")
    precondition(NativeSubagentLabel(interaction: .object(["subagent": .null])) == nil)
    let decodedLabel = try KimiWire.decoder().decode(NativeSubagentLabel.self, from: Data(#"{"id":"k","agentId":null,"title":5,"type":"Plan"}"#.utf8))
    expectEqual(decodedLabel, NativeSubagentLabel(id: "k", type: "Plan"))
    print("PASS: subagent entries decode every protocol 7 key, tolerate missing, mistyped and unknown values, and label interactions")
}

private func checkSubagentSnapshotRoster() throws {
    func snapshot(id: String = "s1", revision: Int, start: Int = 0, total: Int, texts: [String], indices: [Int]? = nil,
                  base: Int? = nil, end: Int? = nil, subagents: [[String: Any]]?) throws -> NativeAgentSnapshot {
        var history: [String: Any] = ["epoch": "e1", "start": start, "total": total, "end": end ?? total]
        if let indices { history["indices"] = indices }
        if let base { history["baseRevision"] = base }
        let messages = texts.map { ["id": $0, "role": "assistant", "created_at": "0", "content": [["type": "text", "text": $0]]] as [String: Any] }
        let label: [String: Any] = ["id": "toolu_01A", "agentId": "a1b2c3", "title": "定位", "type": "Explore"]
        let interaction: [String: Any] = ["id": "perm-1", "type": "interaction", "name": "Bash", "subagent": label]
        var value: [String: Any] = ["id": id, "provider": "claude", "title": "A", "cwd": "/fixture", "busy": true,
                                    "revision": revision, "completed": 0, "model": "m", "history": history,
                                    "messages": messages, "interactions": [interaction]]
        if let subagents { value["subagents"] = subagents }
        return try NativeAgentWire.decode(NativeAgentSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
    let first = try snapshot(revision: 1, start: 2, total: 4, texts: ["two", "three"],
                             subagents: [subagentEntry(), subagentEntry(["id": "toolu_02", "taskId": NSNull(), "toolUseIds": ["toolu_02"], "status": "queued"])])
    expectEqual(first.subagents?.map(\.id), ["toolu_01A", "toolu_02"])
    expectEqual(first.subagent(matching: "a1b2c3")?.id, "toolu_01A")
    expectEqual(first.subagent(matching: "toolu_02")?.status, .queued)
    precondition(first.subagent(matching: "missing") == nil)
    expectEqual(NativeSubagentLabel(interaction: first.interactions[0])?.entry(in: first.subagents ?? [])?.id, "toolu_01A")
    let legacy = try snapshot(revision: 1, total: 0, texts: [], subagents: nil)
    precondition(legacy.subagents == nil, "A bridge before protocol 7 reports no roster")

    // A delta that carries the key replaces the roster wholesale.
    let replaced = try snapshot(revision: 2, start: 2, total: 5, texts: ["four"], indices: [4], base: 1,
                                subagents: [subagentEntry(["status": "completed", "endedAt": "2026-10-18T05:31:00.000Z"])])
        .applying(to: first)
    expectEqual(replaced.subagents?.map(\.id), ["toolu_01A"])
    expectEqual(replaced.subagents?.first?.status, .completed)
    expectEqual(replaced.messages.map(\.id), ["two", "three", "four"])
    // One without the key keeps it, for deltas and full windows of the same session.
    let kept = try snapshot(revision: 3, start: 2, total: 5, texts: [], indices: [], base: 2, subagents: nil).applying(to: replaced)
    expectEqual(kept.subagents, replaced.subagents)
    expectEqual(kept.messages.map(\.id), ["two", "three", "four"])
    let keptFull = try snapshot(revision: 4, start: 0, total: 1, texts: ["zero"], subagents: nil).applying(to: kept)
    expectEqual(keptFull.subagents, replaced.subagents)
    let otherSession = try snapshot(id: "s2", revision: 1, total: 0, texts: [], subagents: nil).applying(to: kept)
    precondition(otherSession.subagents == nil, "Another session never inherits a roster")
    let emptied = try snapshot(revision: 5, start: 2, total: 5, texts: [], indices: [], base: 3, subagents: []).applying(to: kept)
    expectEqual(emptied.subagents, [])
    let unchanged = try NativeAgentWire.decode(NativeSnapshotResponse.self, from: Data(#"{"unchanged":true}"#.utf8))
    precondition(unchanged.snapshot == nil, "An unchanged answer leaves the held snapshot, roster included, to the caller")
    // An older page extends history only; the roster stays the one it extends.
    let page = try snapshot(revision: 9, start: 0, total: 5, texts: ["zero", "one"], end: 2, subagents: [])
    let expanded = try kept.prepending(page)
    expectEqual(expanded.subagents, kept.subagents)
    expectEqual(expanded.messages.map(\.id), ["zero", "one", "two", "three", "four"])

    struct Catalog: Decodable { let sessions: [NativeAgentSession] }
    let sessions = try NativeAgentWire.decode(Catalog.self, from: Data(#"""
    {"sessions":[
     {"id":"s1","provider":"claude","title":"A","cwd":"/tmp","busy":true,"archived":false,"updated":0,"completed":0,"pending":0,"model":"m","error":null,"runningSubagents":2},
     {"id":"s2","provider":"claude","title":"B","cwd":"/tmp","busy":false,"archived":false,"updated":0,"completed":0,"pending":0,"model":"m","error":null}]}
    """#.utf8)).sessions
    precondition(sessions[0].runningSubagents == 2 && sessions[1].runningSubagents == nil)
    print("PASS: snapshot roster decodes; deltas and full windows replace it only when they carry it; pages and other sessions keep their own")
}

private func checkSubagentTranscriptPaging() throws {
    func message(_ text: String) -> [String: Any] {
        // "m3=edited" is a new version of message "m3".
        ["id": text.components(separatedBy: "=")[0], "role": "assistant", "created_at": "0", "content": [["type": "text", "text": text]]]
    }
    func page(_ value: [String: Any]) throws -> NativeSubagentPage {
        try NativeAgentWire.decode(NativeSubagentPage.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func window(epoch: String = "e1", revision: Int, total: Int, start: Int, ids: [String], truncated: Int = 0,
                entry: [String: Any]? = subagentEntry()) throws -> NativeSubagentWindow {
        var value: [String: Any] = ["epoch": epoch, "revision": revision, "total": total, "truncated": truncated,
                                    "start": start, "messages": ids.map(message)]
        if let entry { value["entry"] = entry }
        return try NativeAgentWire.decode(NativeSubagentWindow.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func delta(epoch: String = "e1", revision: Int, total: Int, changes: [(Int, String)],
               entry: [String: Any]? = nil) throws -> NativeSubagentPage {
        var value: [String: Any] = ["epoch": epoch, "revision": revision, "total": total, "truncated": 0,
                                    "changes": changes.map { ["index": $0.0, "message": message($0.1)] as [String: Any] }]
        if let entry { value["entry"] = entry }
        return try page(value)
    }

    // Decoding tells the three follow answers apart; errors stay errors.
    expectEqual(try page(["unchanged": true]), .unchanged)
    guard case .delta(let decodedDelta) = try delta(revision: 4, total: 3, changes: [(2, "c")]) else { preconditionFailure("delta") }
    precondition(decodedDelta.changes.map(\.index) == [2] && decodedDelta.entry == nil && decodedDelta.truncated == 0)
    guard case .full(let decodedFull) = try page(["entry": subagentEntry(), "epoch": "e1", "revision": 3, "total": 5,
                                                  "truncated": 2, "start": 2, "messages": [message("m2")]]) else { preconditionFailure("full") }
    precondition(decodedFull.entry?.id == "toolu_01A" && decodedFull.truncated == 2 && decodedFull.messages.map(\.id) == ["m2"])
    expectThrows(try page(["error": "Unknown subagent"])) { expectEqual($0.localizedDescription, "Unknown subagent") }
    let lenient = try window(revision: 1, total: 1, start: 0, ids: ["m0"], entry: ["id": 5])
    precondition(lenient.entry == nil, "An unreadable entry does not fail the page")

    var transcript = NativeSubagentTranscript(key: "a1b2c3")
    precondition(transcript.followQuery == "" && !transcript.hasOlder && transcript.olderQuery() == nil && transcript.entry == nil)
    expectFalse(transcript.apply(.unchanged))
    expectFalse(transcript.apply(try delta(revision: 9, total: 1, changes: [(0, "m0")])))

    // The first read is the latest window; follow reads are deltas against it.
    let latest = try window(revision: 3, total: 5, start: 2, ids: ["m2", "m3", "m4"])
    expectTrue(transcript.apply(.full(latest)))
    precondition(transcript.epoch == "e1" && transcript.revision == 3 && transcript.total == 5 && transcript.start == 2)
    expectEqual(transcript.messages.map(\.id), ["m2", "m3", "m4"])
    expectEqual(transcript.entry?.id, "toolu_01A")
    expectEqual(transcript.followQuery, "?epoch=e1&revision=3")
    expectTrue(transcript.hasOlder)
    expectEqual(transcript.olderQuery(), "?epoch=e1&before=2&limit=100")
    expectEqual(transcript.olderQuery(limit: 500), "?epoch=e1&before=2&limit=200")
    expectEqual(transcript.olderQuery(limit: 0), "?epoch=e1&before=2&limit=1")
    expectFalse(transcript.apply(.unchanged))
    expectFalse(transcript.apply(.full(latest)))  // the same baseline read again

    // Changes apply by absolute index: replace, append, skip before the window.
    let finished = subagentEntry(["status": "completed", "revision": 5])
    expectTrue(transcript.apply(try delta(revision: 5, total: 6, changes: [(5, "m5"), (0, "m0=edited"), (3, "m3=edited")], entry: finished)))
    expectEqual(transcript.messages.map(\.id), ["m2", "m3", "m4", "m5"])
    expectEqual(transcript.messages[1].content.first?.text, "m3=edited")
    precondition(transcript.revision == 5 && transcript.total == 6 && transcript.entry?.status == .completed)
    let afterEdit = transcript
    expectFalse(transcript.apply(try delta(revision: 5, total: 7, changes: [(6, "m6")])))  // stale revision
    expectFalse(transcript.apply(try delta(revision: 4, total: 7, changes: [(6, "m6")])))
    expectFalse(transcript.apply(try delta(epoch: "e0", revision: 8, total: 7, changes: [(6, "m6")])))  // another epoch
    expectFalse(transcript.apply(.full(try window(revision: 4, total: 5, start: 2, ids: ["m2", "m3", "m4"]))))  // older full read
    precondition(transcript == afterEdit, "Ignored reads leave the transcript as it was")
    expectTrue(transcript.apply(try delta(revision: 6, total: 6, changes: [])))  // an entry-only change still advances
    precondition(transcript.revision == 6 && transcript.entry?.status == .completed, "A delta without an entry keeps the one held")

    // A delta that does not fit drops the baseline; the next follow read is full.
    let shown = transcript.messages
    expectTrue(transcript.apply(try delta(revision: 7, total: 9, changes: [(8, "m8")])))
    precondition(transcript.epoch == nil && transcript.followQuery == "" && !transcript.hasOlder && transcript.olderQuery() == nil)
    precondition(transcript.messages == shown, "The messages on screen stay while the full read is pending")
    expectFalse(transcript.apply(try delta(revision: 8, total: 9, changes: [(6, "m6"), (7, "m7"), (8, "m8")])))
    expectTrue(transcript.apply(.full(try window(revision: 7, total: 9, start: 4, ids: ["m4", "m5", "m6", "m7", "m8"]))))
    expectEqual(transcript.messages.map(\.id), ["m4", "m5", "m6", "m7", "m8"])
    var duplicate = transcript
    expectTrue(duplicate.apply(try delta(revision: 8, total: 9, changes: [(5, "m5=a"), (5, "m5=b")])))
    precondition(duplicate.epoch == nil, "Two changes for one index are not guessed between")
    var unsorted = transcript
    expectTrue(unsorted.apply(try delta(revision: 8, total: 10, changes: [(9, "m9"), (4, "m4=edited")])))
    expectEqual(unsorted.messages.map(\.id), ["m4", "m5", "m6", "m7", "m8", "m9"])
    expectEqual(unsorted.messages[0].content.first?.text, "m4=edited")

    // A new epoch resets, even at a lower revision: the bridge trimmed the front.
    expectTrue(transcript.apply(.full(try window(epoch: "e2", revision: 2, total: 4, start: 2, ids: ["n2", "n3"], truncated: 1500))))
    precondition(transcript.epoch == "e2" && transcript.revision == 2 && transcript.truncated == 1500 && transcript.start == 2)
    expectEqual(transcript.messages.map(\.id), ["n2", "n3"])

    // Older pages: same epoch, ending exactly at the held start.
    let older = try window(epoch: "e2", revision: 2, total: 4, start: 0, ids: ["n0", "n1"])
    expectFalse(transcript.apply(.older(older)))  // apply never takes an older page
    expectFalse(transcript.prepend(.full(older)))  // prepend only takes one
    expectFalse(transcript.prepend(.older(try window(epoch: "e1", revision: 2, total: 4, start: 0, ids: ["n0", "n1"]))))
    expectFalse(transcript.prepend(.older(try window(epoch: "e2", revision: 2, total: 4, start: 0, ids: ["n0"]))))
    var raced = transcript
    expectTrue(raced.apply(try delta(epoch: "e2", revision: 4, total: 4, changes: [])))
    expectTrue(raced.prepend(.older(older)))
    precondition(raced.revision == 2, "A page older than the baseline lowers the revision")
    expectEqual(raced.followQuery, "?epoch=e2&revision=2")
    expectTrue(transcript.prepend(.older(try window(epoch: "e2", revision: 3, total: 5, start: 0, ids: ["n0", "n1"]))))
    precondition(transcript.revision == 2 && transcript.total == 4 && transcript.start == 0 && !transcript.hasOlder)
    expectEqual(transcript.messages.map(\.id), ["n0", "n1", "n2", "n3"])
    expectEqual(transcript.olderQuery(), nil)
    expectFalse(transcript.prepend(.older(older)))  // the same page twice
    print("PASS: subagent transcript decoding, full reset, index deltas, stale revisions, epoch reset, resync and older pages")
}

private func checkSubagentProjection() throws {
    func task(_ overrides: [String: Any]) throws -> KimiTask { KimiTask(native: try decodeSubagent(subagentEntry(overrides))) }
    let expected: [(wire: String, status: String, phase: String, label: String)] = [
        ("queued", "running", "queued", L("排队中")), ("running", "running", "working", L("执行中")),
        ("completed", "completed", "completed", L("已完成")), ("failed", "failed", "failed", L("失败")),
        ("stopped", "cancelled", "cancelled", L("已取消")), ("unknown", "unknown", "unknown", L("状态未知")),
    ]
    for row in expected {
        let projected = try task(["status": row.wire])
        expectEqual(projected.status, row.status)
        expectEqual(projected.subagentPhase, row.phase)
        expectEqual(projected.phaseLabel, row.label)
        expectEqual(projected.isRunning, row.wire == "queued" || row.wire == "running")
        expectEqual(projected.isFailed, row.wire == "failed")
    }
    expectEqual(try task(["status": "unknown"]).statusLabel, L("状态未知"))

    let running = try task([:])
    precondition(running.id == "toolu_01A" && running.kind == "subagent" && running.kindLabel == L("子 Agent"))
    precondition(running.agentId == "a1b2c3" && running.parentToolCallId == "toolu_01A" && running.transcriptAgentId == "a1b2c3")
    precondition(running.description == "定位中文输入问题" && running.subagentType == "Explore" && running.runInBackground == true)
    precondition(running.tokenCount == 1200 && running.toolUseCount == 3 && running.latestActivity == "Grep" && running.stoppable == true)
    precondition(running.completedAt == nil && running.startedDate != nil, "A live entry keeps its clock running")
    expectEqual(running.elapsed(at: running.startedDate!.addingTimeInterval(42)), 42)
    expectEqual(running.outputPreview, "找到 2 处竞态")
    expectEqual(try task(["taskId": NSNull()]).transcriptAgentId, "toolu_01A")

    let failed = try task(["status": "failed", "endedAt": "2026-10-18T05:30:39.750Z", "error": "模型请求失败", "canStop": true])
    expectEqual(failed.elapsed(at: Date()), 30.5)
    expectEqual(failed.outputPreview, "找到 2 处竞态\n\n模型请求失败")
    expectEqual(failed.stoppable, false)  // a finished entry is never stoppable
    expectEqual(try task(["canStop": false]).stoppable, false)
    // A finished entry without an end time ends at its last update.
    let lost = try task(["status": "unknown", "summary": NSNull()])
    expectEqual(lost.completedAt, "2026-10-18T05:30:19.250Z")
    expectEqual(lost.elapsed(at: Date()), 10)
    expectEqual(lost.outputPreview, nil)
    expectEqual(try task(["description": NSNull()]).description, "Explore")
    expectEqual(try task(["description": " ", "subagentType": NSNull()]).description, "toolu_01A")

    let board = KimiTaskBoard(subagents: try ["queued", "running", "completed"].map { try task(["status": $0]) })
    expectEqual(board.runningCount, 2)

    // Kimi records still decode as before; the native extras stay unset.
    let kimi = try KimiWire.decoder().decode(KimiTask.self, from: Data(#"{"id":"agent_01","session_id":"s1","kind":"subagent","description":"d","status":"running","created_at":"2026-09-23T08:00:00.000Z","subagent_phase":"working"}"#.utf8))
    precondition(kimi.tokenCount == nil && kimi.toolUseCount == nil && kimi.latestActivity == nil && kimi.stoppable == nil)
    precondition(kimi.phaseLabel == L("执行中") && kimi.transcriptAgentId == "agent_01")
    print("PASS: native subagents project onto roster rows with Kimi's status, phase, clock, output and stop vocabulary")
}

private func checkSubagentToolNames() {
    for name in ["Agent", "Task", "agent", "TASK", "agent/spawnAgent"] {
        precondition(ToolPresentation.isSubagentCall(name: name), name)
        expectEqual(ToolPresentation.action(name), L("子 Agent"))
    }
    for name in ["Read", "Bash", "TaskCreate", "agent/sendInput", "agent/wait", "agents", ""] {
        precondition(!ToolPresentation.isSubagentCall(name: name), name)
    }
    expectEqual(ToolPresentation.action("Read"), L("读取"))
    expectEqual(ToolPresentation.action("agent/wait"), "agent/wait")
    print("PASS: Agent, Task and agent/spawnAgent read as subagent calls with the subagent action label")
}

private func checkSubagentTranscriptRows() throws {
    func tool(_ row: SubagentTranscriptRow) -> VisibleTool? {
        if case .tool(let value) = row.content { return value }
        return nil
    }
    let raw = #"""
    [
      {"id":"p","role":"user","created_at":"1","content":[{"type":"text","text":"列出临时目录"}]},
      {"id":"a1","role":"assistant","created_at":"2","content":[{"type":"thinking","thinking":"先看看"},{"type":"text","text":"开始"},{"type":"tool_use","tool_call_id":"t1","tool_name":"Glob","input":{"pattern":"*"}}]},
      {"id":"r1","role":"user","created_at":"3","content":[{"type":"tool_result","tool_call_id":"t1","output":"a.txt","is_error":false}]},
      {"id":"ctx","role":"user","created_at":"4","content":[{"type":"text","text":"<system-reminder>internal</system-reminder>"}]},
      {"id":"a2","role":"assistant","created_at":"5","content":[{"type":"tool_use","tool_call_id":"t2","tool_name":"Bash","input":{"command":"ls"}},{"type":"tool_use","tool_call_id":"t1","tool_name":"Glob","input":{"pattern":"*"}}]},
      {"id":"r3","role":"user","created_at":"6","content":[{"type":"tool_result","tool_call_id":"t3","output":"late","is_error":true}]},
      {"id":"a3","role":"assistant","created_at":"7","content":[{"type":"thinking","thinking":""},{"type":"text","text":"  "},{"type":"text","text":"完成"}]}
    ]
    """#
    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: Data(raw.utf8))
    let rows = SubagentTranscriptRow.rows(from: messages, isRunning: true)
    expectEqual(rows.map(\.id), ["text:p:0", "thinking:a1:0", "text:a1:1", "tool:t1", "tool:t2", "tool:t3", "text:a3:2"])
    expectEqual(rows[0].content, .text("列出临时目录", role: "user"))
    expectEqual(rows[1].content, .thinking("先看看"))
    expectEqual(rows[2].content, .text("开始", role: "assistant"))
    expectEqual(rows[6].content, .text("完成", role: "assistant"))
    precondition(tool(rows[3])?.name == "Glob" && tool(rows[3])?.status == .succeeded && tool(rows[3])?.output?.string == "a.txt")
    precondition(tool(rows[4])?.status == .running, "An unanswered call of a live subagent runs")
    precondition(tool(rows[5])?.status == .failed && tool(rows[5])?.hasCall == false, "A result without its call keeps a row")
    precondition(tool(SubagentTranscriptRow.rows(from: messages, isRunning: false)[4])?.status == .missingResult)
    precondition(tool(SubagentTranscriptRow.rows(from: messages, isRunning: true, online: false)[4])?.status == .disconnected)
    precondition(SubagentTranscriptRow.rows(from: [], isRunning: true).isEmpty)

    // Kimi: the builder must draw what KimiSubagentTranscriptSheet draws today.
    let pageJSON = #"""
    {"code":0,"data":{"agent_id":"agent_01","has_more":false,"seq":7,"items":[
      {"kind":"turn","turnId":"t1","ordinal":1,"state":"completed","steps":[
        {"kind":"step","stepId":"s1","frames":[
          {"kind":"thinking","frameId":"f1","text":"先看代码"},
          {"kind":"text","frameId":"f2","role":"assistant","text":"开始检查"},
          {"kind":"tool","frameId":"f3","toolCallId":"call_1","name":"Read","state":"done","input":{"path":"/fixture/A.swift"},"output":"struct A {}"},
          {"kind":"tool","frameId":"f4","name":"Read","state":"done"},
          {"kind":"thinking","frameId":"f5","text":""},
          {"kind":"notice","frameId":"f6","level":"warning","message":"重试一次"},
          {"kind":"text","frameId":"f7","role":"user","text":"继续"},
          {"kind":"summary","frameId":"f8","text":"新的帧类型"},
          {"kind":"notice","frameId":"f9","level":"error","message":""}]},
        {"kind":"step","stepId":"s2"}],"error":""},
      {"kind":"marker","markerId":"m1","marker":"compaction"},
      {"kind":"turn","turnId":"t2","ordinal":2,"state":"failed","error":"模型请求失败","steps":[
        {"kind":"step","stepId":"s3","frames":[
          {"kind":"tool","frameId":"f10","toolCallId":"call_2","name":"Bash","state":"error","input":{"command":"npm test"}},
          {"kind":"text","frameId":"f11","text":""},
          {"kind":"notice","frameId":"f12","level":"error","message":"进程退出"}]}]},
      {"kind":"turn","turnId":"t3","ordinal":3,"state":"running"}]}}
    """#
    var transcript = KimiSubagentTranscript(agentId: "agent_01")
    transcript.load(try KimiWire.decode(KimiTranscriptPage.self, from: Data(pageJSON.utf8)), prepend: false)
    let kimiRows = SubagentTranscriptRow.rows(from: transcript)
    let sheet = sheetRowsAsDrawnToday(transcript)
    expectEqual(kimiRows.map(\.id), sheet.map { $0.id })
    expectEqual(kimiRows.map(\.content), sheet.map { $0.content })
    expectEqual(kimiRows.map(\.id), ["turn:t1", "frame:f1", "frame:f2", "frame:f3", "frame:f6", "frame:f7", "frame:f8",
                                     "turn:t2", "frame:f10", "frame:f12", "error:t2", "turn:t3"])
    expectEqual(kimiRows[0].content, .turn(ordinal: 1, state: "completed"))
    expectEqual(kimiRows[4].content, .notice("重试一次", level: "warning"))
    expectEqual(kimiRows[5].content, .text("继续", role: "user"))
    expectEqual(kimiRows[6].content, .text("新的帧类型", role: nil))
    expectEqual(kimiRows[10].content, .error("模型请求失败"))
    precondition(tool(kimiRows[3])?.status == .succeeded && tool(kimiRows[8])?.status == .failed)
    precondition(Set(kimiRows.map(\.id)).count == kimiRows.count && Set(rows.map(\.id)).count == rows.count)
    print("PASS: shared subagent transcript rows for native messages and Kimi turns, matching the Kimi sheet's flattening")
}

/// KimiSubagentTranscriptSheet's `rows(in:)` and `frameContent(_:)` as of this
/// change, restated over Core types: one header per turn, its frames in step
/// order, then its error, keeping only the frames the sheet draws something for.
private func sheetRowsAsDrawnToday(_ transcript: KimiSubagentTranscript) -> [(id: String, content: SubagentTranscriptRow.Content)] {
    enum Row {
        case header(KimiTranscriptItem)
        case frame(KimiTranscriptFrame)
        case error(String, String)
    }
    let rows: [Row] = transcript.turns.flatMap { turn in
        var rows: [Row] = [.header(turn)]
        rows += (turn.steps ?? []).flatMap { ($0.frames ?? []).map(Row.frame) }
        if let error = turn.error, !error.isEmpty { rows.append(.error(turn.id, error)) }
        return rows
    }
    return rows.compactMap { row -> (id: String, content: SubagentTranscriptRow.Content)? in
        switch row {
        case .header(let turn): return ("turn:" + turn.id, .turn(ordinal: turn.ordinal, state: turn.state))
        case .error(let id, let text): return ("error:" + id, .error(text))
        case .frame(let frame):
            let id = "frame:" + frame.frameId
            switch frame.kind {
            case "tool":
                if let tool = frame.tool { return (id, .tool(tool)) }
            case "thinking":
                if let text = frame.text, !text.isEmpty { return (id, .thinking(text)) }
            case "notice":
                if let message = frame.message, !message.isEmpty { return (id, .notice(message, level: frame.level)) }
            default:
                if let text = frame.text, !text.isEmpty { return (id, .text(text, role: frame.role)) }
            }
            return nil
        }
    }
}
