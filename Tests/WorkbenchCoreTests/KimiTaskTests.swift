import Foundation
import WorkbenchCore

func checkKimiTasks() throws {
    func require(_ value: Bool, _ message: String = "check failed") { precondition(value, message) }
    let session = #"{"id":"s1","title":"测试","updated_at":"2026-09-20","busy":true,"pending_interaction":"none","metadata":{"cwd":"/tmp"},"agent_config":{"model":"test/model"}}"#

    func snapshot(subagents: String, seq: Int = 10, epoch: String = "e1") throws -> KimiSnapshot {
        try KimiWire.decoder().decode(KimiSnapshot.self, from: Data("""
        {"as_of_seq":\(seq),"epoch":"\(epoch)","session":\(session),"messages":{"items":[],"has_more":false},"in_flight_turn":null,"pending_approvals":[],"pending_questions":[],"subagents":\(subagents)}
        """.utf8))
    }
    func event(_ type: String, _ payload: String, seq: Int, at timestamp: String = "2026-09-23T08:00:00.000Z") throws -> KimiEvent {
        try KimiWire.decoder().decode(KimiEvent.self, from: Data("""
        {"type":"\(type)","session_id":"s1","epoch":"e1","seq":\(seq),"timestamp":"\(timestamp)","payload":\(payload)}
        """.utf8))
    }
    let rosterEntry = #"{"id":"agent_01","session_id":"s1","kind":"subagent","description":"定位中文输入问题","status":"running","created_at":"2026-09-23T08:00:00.000Z","run_in_background":false,"subagent_phase":"working","subagent_type":"coder","parent_tool_call_id":"toolu_1","model":"kimi-k2","thinking_effort":"high","swarm_index":0}"#

    // The snapshot roster decodes with the same shape as the task list.
    let roster = try KimiWire.decoder().decode([KimiTask].self, from: Data("[\(rosterEntry)]".utf8))
    require(roster.count == 1 && roster[0].id == "agent_01")
    require(roster[0].subagentPhase == "working" && roster[0].subagentType == "coder")
    require(roster[0].model == "kimi-k2" && roster[0].thinkingEffort == "high" && roster[0].swarmIndex == 0)
    require(roster[0].runInBackground == false && roster[0].parentToolCallId == "toolu_1")
    require(KimiConversation(try snapshot(subagents: "[\(rosterEntry)]")).tasks.subagents.map(\.id) == ["agent_01"])

    // An unknown server value stays readable instead of failing the whole read.
    let future = try KimiWire.decode(KimiTask.self, from: Data(#"{"code":0,"data":{"id":"t","session_id":"s1","kind":"workflow","description":"d","status":"paused","created_at":"2026-09-23T08:00:00.000Z","run_in_background":true}}"#.utf8))
    require(future.kind == "workflow" && future.status == "paused" && future.statusLabel == "paused")
    require(future.kindLabel == "workflow" && future.phaseLabel == "paused")

    // Lifecycle events move the roster without a snapshot read.
    var board = KimiTaskBoard()
    let spawned = #"{"agentId":"main","subagentId":"agent_01","subagentName":"coder","parentToolCallId":"toolu_1","description":"定位中文输入问题","runInBackground":false,"model":"kimi-k2","thinkingEffort":"high","swarmIndex":2}"#
    require(board.apply(try event("subagent.spawned", spawned, seq: 11, at: "2026-09-23T08:00:01.000Z")))
    require(board.subagents.count == 1 && board.subagents[0].subagentPhase == "queued")
    require(board.subagents[0].createdAt == "2026-09-23T08:00:01.000Z" && board.subagents[0].startedDate != nil)
    require(board.subagents[0].kind == "subagent" && board.subagents[0].status == "running")
    require(board.apply(try event("subagent.started", #"{"agentId":"main","subagentId":"agent_01"}"#, seq: 12, at: "2026-09-23T08:00:02.000Z")))
    require(board.subagents[0].subagentPhase == "working" && board.subagents[0].startedAt == "2026-09-23T08:00:02.000Z")
    require(board.apply(try event("subagent.suspended", #"{"agentId":"main","subagentId":"agent_01","reason":"等待确认"}"#, seq: 13)))
    require(board.subagents[0].subagentPhase == "suspended" && board.subagents[0].suspendedReason == "等待确认")
    require(board.apply(try event("subagent.started", #"{"agentId":"main","subagentId":"agent_01"}"#, seq: 14)))
    require(board.subagents[0].suspendedReason == nil, "Resuming clears the suspension reason")
    require(board.subagents[0].startedAt == "2026-09-23T08:00:02.000Z", "Resuming keeps the first start time")
    require(board.apply(try event("subagent.completed", #"{"agentId":"main","subagentId":"agent_01","resultSummary":"找到 3 处竞态"}"#, seq: 15, at: "2026-09-23T08:00:31.000Z")))
    require(board.subagents[0].status == "completed" && board.subagents[0].subagentPhase == "completed")
    require(board.output(of: board.subagents[0]) == "找到 3 处竞态")
    require(board.subagents[0].elapsed(at: Date()) == 29, "A finished child keeps its own duration")

    // A repeated spawn replaces its row instead of adding a second one.
    require(board.apply(try event("subagent.spawned", spawned, seq: 16)))
    require(board.subagents.count == 1 && board.subagents[0].subagentPhase == "queued")

    // The server roster skips background children; the task list reports them.
    require(!board.apply(try event("subagent.spawned", #"{"agentId":"main","subagentId":"agent_02","subagentName":"coder","parentToolCallId":"","runInBackground":true}"#, seq: 17)))
    require(board.subagents.count == 1)
    // An event for a child this client never saw is not invented into a row.
    require(!board.apply(try event("subagent.completed", #"{"agentId":"main","subagentId":"agent_99","resultSummary":"x"}"#, seq: 18)))
    require(board.subagents.count == 1)

    // Failure keeps the server's error text as the only reported output.
    require(board.apply(try event("subagent.spawned", #"{"agentId":"main","subagentId":"agent_03","subagentName":"explore","parentToolCallId":"toolu_2","runInBackground":false}"#, seq: 19)))
    require(board.apply(try event("subagent.failed", #"{"agentId":"main","subagentId":"agent_03","error":"模型请求失败"}"#, seq: 20)))
    require(board.subagents.last?.status == "failed" && board.subagents.last?.isFailed == true)
    require(board.subagents.last.flatMap { board.output(of: $0) } == "模型请求失败")
    require(board.apply(try event("subagent.spawned", #"{"agentId":"main","subagentId":"agent_04","subagentName":"plan","parentToolCallId":"toolu_3","runInBackground":false}"#, seq: 21)))
    require(board.apply(try event("subagent.cancelled", #"{"agentId":"main","subagentId":"agent_04"}"#, seq: 22)))
    require(board.subagents.last?.status == "cancelled")

    // A new main turn drops the roster; a child's own turn does not.
    require(!board.apply(try event("turn.started", #"{"agentId":"agent_01","turnId":1}"#, seq: 23)))
    require(board.subagents.map(\.id) == ["agent_01", "agent_03", "agent_04"], "A child's own turn keeps the roster")
    require(board.apply(try event("turn.started", #"{"agentId":"main","turnId":2}"#, seq: 24)))
    require(board.subagents.isEmpty)
    require(!board.apply(try event("turn.started", #"{"agentId":"main","turnId":3}"#, seq: 25)), "Clearing an empty roster is not a change")

    // Only the persisted task list asks for a re-read, and its legacy alias does
    // not schedule a second one.
    require(KimiTaskBoard.changesTaskList("task.started") && KimiTaskBoard.changesTaskList("task.terminated"))
    require(!KimiTaskBoard.changesTaskList("background.task.started"))
    require(!KimiTaskBoard.changesTaskList("background.task.terminated"))
    require(!KimiTaskBoard.changesTaskList("tool.result") && !KimiTaskBoard.changesTaskList("subagent.spawned"))

    let listJSON = #"{"code":0,"data":{"items":[{"id":"task_1","session_id":"s1","kind":"bash","description":"运行测试","status":"running","command":"npm test","created_at":"2026-09-23T08:01:00.000Z","started_at":"2026-09-23T08:01:00.000Z","run_in_background":true},{"id":"task_2","session_id":"s1","kind":"subagent","description":"定位中文输入问题","status":"running","created_at":"2026-09-23T08:00:00.000Z","agent_id":"agent_01","subagent_type":"coder","run_in_background":false}]}}"#
    let list = try KimiWire.decode(KimiTaskList.self, from: Data(listJSON.utf8))
    require(list.items.count == 2 && list.items[0].command == "npm test" && list.items[0].kind == "bash")
    require(list.items[1].agentId == "agent_01" && list.items[1].runInBackground == false)
    var listed = KimiTaskBoard(subagents: roster)
    listed.reconcile(background: list.items)
    require(listed.background.count == 2 && listed.backgroundTasks.map(\.id) == ["task_1"],
            "A foreground child is reported once, by the roster")
    require(listed.runningCount == 2, "The roster child and the background process are both running")
    listed.reconcile(background: [])
    require(listed.backgroundTasks.isEmpty && listed.subagents.map(\.id) == ["agent_01"])

    // A snapshot replaces the roster but keeps the list and the tails already read.
    var conversation = try KimiConversation(snapshot(subagents: "[\(rosterEntry)]"))
    conversation.tasks.reconcile(background: list.items)
    conversation.tasks.store(output: "PASS: 12 tests", for: "task_1")
    require(conversation.tasks.output(of: list.items[0]) == "PASS: 12 tests")
    require(!conversation.apply(try event("subagent.spawned", spawned, seq: 11)), "A swarm must not re-read the snapshot per child")
    require(conversation.tasks.subagents.map(\.id) == ["agent_01"], "A repeated spawn updates the row the snapshot already reported")
    require(conversation.apply(try event("turn.started", #"{"agentId":"main","turnId":2}"#, seq: 12)), "A new main turn still refreshes the snapshot")
    require(conversation.tasks.subagents.isEmpty)
    conversation.reconcile(try snapshot(subagents: "[]", seq: 30))
    require(conversation.tasks.subagents.isEmpty, "The snapshot is authoritative for the roster")
    require(conversation.tasks.background.map(\.id) == ["task_1", "task_2"], "A snapshot refresh keeps the task list")
    require(conversation.tasks.outputs["task_1"] == "PASS: 12 tests")

    // A server without the roster reports no key at all, and the board stays empty.
    let withoutRoster = try KimiWire.decoder().decode(KimiSnapshot.self, from: Data("""
    {"as_of_seq":1,"epoch":"e1","session":\(session),"messages":{"items":[],"has_more":false},"in_flight_turn":null,"pending_approvals":[],"pending_questions":[]}
    """.utf8))
    require(withoutRoster.subagents == nil)
    require(KimiConversation(withoutRoster).tasks.isEmpty)

    // The single task read carries the tail the list omits.
    let detail = try KimiWire.decode(KimiTask.self, from: Data(#"{"code":0,"data":{"id":"task_1","session_id":"s1","kind":"bash","description":"运行测试","status":"completed","command":"npm test","created_at":"2026-09-23T08:01:00.000Z","started_at":"2026-09-23T08:01:00.000Z","completed_at":"2026-09-23T08:01:30.500Z","run_in_background":true,"output_preview":"PASS","output_bytes":4}}"#.utf8))
    require(detail.outputPreview == "PASS" && detail.outputBytes == 4 && detail.status == "completed")
    require(detail.elapsed(at: Date()) == 30.5)
    require(detail.startedDate == detail.completedDate?.addingTimeInterval(-30.5))
    let created = try KimiWire.decode(KimiTask.self, from: Data(#"{"code":0,"data":{"id":"task_3","session_id":"s1","kind":"tool","description":"等待回答","status":"running","created_at":"2026-09-23T08:02:00.000Z","run_in_background":true}}"#.utf8))
    require(created.startedAt == nil && created.startedDate != nil, "A task without a start time is timed from its creation")
    print("PASS: subagent roster decoding, lifecycle events, background task list, deduplication and snapshot boundaries")
}
