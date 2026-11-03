import Foundation
import WorkbenchCore

func checkTurnStatus() throws {
    func messages(_ json: String) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: Data(json.utf8))
    }
    let user = try messages(#"[{"id":"u","role":"user","created_at":"","content":[{"type":"text","text":"Fix the bar"}]}]"#)
    let plan = try messages(#"""
    [{"id":"plan","role":"assistant","created_at":"","content":[{"type":"tool_use","tool_call_id":"plan","tool_name":"TodoList","input":{"todos":[
       {"title":"Inspect","status":"done"},{"title":"Adjust the layout","status":"in_progress"},{"title":"Verify","status":"pending"}]}}]},
     {"id":"plan-result","role":"tool","created_at":"","content":[{"type":"tool_result","tool_call_id":"plan","is_error":false,"output":"ok"}]}]
    """#)
    let command = try messages(#"[{"id":"cmd","role":"assistant","created_at":"","content":[{"type":"tool_use","tool_call_id":"cmd","tool_name":"Bash","input":{"command":"swift build"}}]}]"#)
    let described = try messages(#"[{"id":"cmd","role":"assistant","created_at":"","content":[{"type":"tool_use","tool_call_id":"cmd","tool_name":"Bash","input":{"command":"swift build","description":"Build the app"}}]}]"#)
    let edit = try messages(#"""
    [{"id":"edit","role":"assistant","created_at":"","content":[{"type":"tool_use","tool_call_id":"edit","tool_name":"Edit","input":{"path":"/p/Bar.swift","old_string":"a\nb","new_string":"a\nc\nd"}}]},
     {"id":"edit-result","role":"tool","created_at":"","content":[{"type":"tool_result","tool_call_id":"edit","is_error":false,"output":"ok"}]}]
    """#)
    let earlierEdit = try messages(#"""
    [{"id":"u0","role":"user","created_at":"","content":[{"type":"text","text":"Earlier"}]},
     {"id":"old","role":"assistant","created_at":"","content":[{"type":"tool_use","tool_call_id":"old","tool_name":"Write","input":{"path":"/p/Old.swift","content":"1\n2\n3"}}]},
     {"id":"old-result","role":"tool","created_at":"","content":[{"type":"tool_result","tool_call_id":"old","is_error":false,"output":"ok"}]}]
    """#)
    let running = ["cmd"] as Set<String>

    // Running headlines, most specific first: the plan step, a short narrative,
    // the tool's description, the generic phase. The target is secondary text.
    let stepped = TurnStatus(activity: ConversationActivity(messages: user + plan + command, isRunning: true, running: running),
                             turn: SessionTurn(running: true), narrativeHeadline: "解冲突")
    precondition(stepped.state == .running && stepped.headline == "Adjust the layout" && stepped.source == .step)
    precondition(stepped.detail == "swift build" && stepped.progress?.done == 1 && stepped.progress?.total == 3)
    let narrated = TurnStatus(activity: ConversationActivity(messages: user + command, isRunning: true, running: running),
                              turn: SessionTurn(running: true), narrativeHeadline: "  解冲突  ")
    precondition(narrated.headline == "解冲突" && narrated.source == .narrative && narrated.detail == "swift build")
    let long = String(repeating: "长", count: TurnStatus.narrativeLimit + 1)
    let describedStatus = TurnStatus(activity: ConversationActivity(messages: user + described, isRunning: true, running: running),
                                     turn: SessionTurn(running: true), narrativeHeadline: long)
    precondition(describedStatus.headline == "Build the app" && describedStatus.source == .description,
                 "A narrative too long for one line yields to the tool's description")
    precondition(describedStatus.detail == nil, "A described tool already names its target")
    let phase = TurnStatus(activity: ConversationActivity(messages: user + command, isRunning: true, running: running), turn: SessionTurn(running: true))
    precondition(phase.source == .phase && phase.headline == "Running command…" && phase.detail == "swift build")
    let thinkingActivity = ConversationActivity(messages: user, isRunning: true, isThinking: true)
    let thinking = TurnStatus(activity: thinkingActivity, turn: SessionTurn(running: true))
    precondition(thinking.headline == "Thinking…" && thinking.detail == nil && thinking.shimmers && thinking.opensDetails)
    let commandActivity = ConversationActivity(messages: user + command, isRunning: true, running: running)
    let zh = Locale(identifier: "zh-Hans")
    let stalled = TurnStatus(activity: commandActivity, turn: SessionTurn(running: true), quiet: TurnStatus.Quiet(seconds: 240), locale: zh)
    precondition(stalled.state == .running && stalled.stalledMinutes == 4 && stalled.detail == "4 分钟没有新进展",
                 "A stall replaces the target and keeps the current action")
    precondition(!stalled.shimmers, "A suspected stall holds the title still")
    // Quiet for a minute: name the command being waited on, or say nothing arrived.
    let waitingOnTool = TurnStatus(activity: commandActivity, turn: SessionTurn(running: true),
                                   quiet: TurnStatus.Quiet(seconds: 75, toolSeconds: 150), locale: zh)
    precondition(waitingOnTool.detail == "swift build · 已运行 2分" && waitingOnTool.stalledMinutes == nil && waitingOnTool.shimmers,
                 "\(String(describing: waitingOnTool.detail))")
    precondition(TurnStatus(activity: commandActivity, turn: SessionTurn(running: true), quiet: TurnStatus.Quiet(seconds: 540, toolSeconds: 540),
                            locale: zh).stalledMinutes == nil, "A running tool may stay quiet for ten minutes")
    precondition(TurnStatus(activity: commandActivity, turn: SessionTurn(running: true), quiet: TurnStatus.Quiet(seconds: 600, toolSeconds: 600),
                            locale: zh).stalledMinutes == 10)
    let silent = TurnStatus(activity: thinkingActivity, turn: SessionTurn(running: true), quiet: TurnStatus.Quiet(seconds: 60), locale: zh)
    precondition(silent.detail == "1 分钟没有新输出" && silent.stalledMinutes == nil, "\(String(describing: silent.detail))")
    precondition(TurnStatus(activity: commandActivity, turn: SessionTurn(running: true), quiet: nil).detail == "swift build")

    // What the turn produced: numbers that only grow while output arrives, in English.
    let reply = try messages(#"[{"id":"t","role":"assistant","created_at":"","content":[{"type":"thinking","thinking":"想一想"},{"type":"text","text":"正在检查"}]}]"#)
    let producing = TurnStatus(activity: ConversationActivity(messages: user + reply + command, isRunning: true, running: running),
                               turn: SessionTurn(running: true))
    precondition(producing.output?.characters == 7 && producing.output?.toolCalls == 1)
    precondition(producing.output?.charactersLabel == "↓ 7 chars" && producing.output?.toolCallsLabel == "1 tool call")
    precondition(thinking.output?.charactersLabel == nil && thinking.output?.toolCallsLabel == nil, "Nothing yet, no zero counters")
    precondition(TurnStatus.compact(980) == "980" && TurnStatus.compact(3_200) == "3.2k" && TurnStatus.compact(3_000) == "3k"
                 && TurnStatus.compact(12_345) == "12k" && TurnStatus.compact(1_250_000) == "1.3M")

    // What the reader must do outranks progress.
    let pendingActivity = ConversationActivity(messages: user + command, isRunning: true, running: running, pendingCount: 2)
    let approval = TurnStatus(activity: pendingActivity, turn: SessionTurn(running: true, pending: true), pendingCount: 2,
                              request: TurnRequest(kind: .approval, text: "运行 rm -rf build"))
    precondition(approval.state == .waiting && approval.headline == "需要你确认：运行 rm -rf build" && approval.detail == "共 2 项")
    precondition(approval.isBlocking && !approval.opensDetails && !approval.shimmers && approval.changes == nil)
    let question = TurnStatus(activity: pendingActivity, turn: SessionTurn(running: true, pending: true), pendingCount: 1,
                              request: TurnRequest(kind: .question, text: "用哪个分支？"))
    precondition(question.headline == "需要你回答：用哪个分支？" && question.detail == nil)
    precondition(TurnStatus(activity: pendingActivity, turn: SessionTurn(running: true, pending: true), pendingCount: 2).headline == "等待你确认 · 2 项")
    let offline = TurnStatus(activity: ConversationActivity(messages: user + command, isRunning: true, online: false),
                             turn: SessionTurn(running: true, pending: true), online: false, pendingCount: 1)
    precondition(offline.state == .offline && offline.headline == "Connection lost" && !offline.opensDetails)
    let waitingFromCatalog = TurnStatus(activity: ConversationActivity(messages: user + command, isRunning: true, running: running),
                                        turn: SessionTurn(running: true, pending: true))
    precondition(waitingFromCatalog.state == .waiting && waitingFromCatalog.headline == "等你处理",
                 "Pending facts without listed requests still wait for the reader")
    let stopping = TurnStatus(activity: ConversationActivity(messages: user + command, isRunning: true, isStopping: true), turn: SessionTurn(running: true))
    precondition(stopping.state == .stopping && !stopping.shimmers && stopping.opensDetails)
    let editing = TurnStatus(activity: ConversationActivity(messages: user + edit + command, isRunning: true, running: running),
                             turn: SessionTurn(running: true))
    precondition(editing.changes?.files == 1 && editing.changes?.additions == 2,
                 "This turn's edits stay on the right while it runs, not only once it ends")

    // Ended turns: uncertain results first, then the result this client watched.
    let review = TurnStatus(activity: ConversationActivity(messages: user + command, isRunning: false), turn: SessionTurn())
    precondition(review.state == .review && review.attention == 1 && review.headline == "完成 · 1 项需要你看一下")
    var clocks = ConversationTimings()
    clocks.submitted("turn", at: Date().addingTimeInterval(-95))
    clocks.observe(sessionID: "s", turnID: "turn", requestID: "turn", running: true, waiting: false)
    let live = clocks.turns["s"]
    clocks.observe(sessionID: "s", running: false, waiting: false)
    let finished = clocks.turns["s"]
    let ended = ConversationActivity(messages: earlierEdit + user + edit, isRunning: false)
    precondition(ended.edits?.perFile.keys.sorted() == ["/p/Bar.swift"], "Edits count the latest turn only")
    let done = TurnStatus(activity: ended, turn: SessionTurn(completion: "done"), timing: finished)
    precondition(done.state == .done && done.headline == "完成" && done.opensDetails && !done.shimmers)
    precondition(done.changes?.files == 1 && done.changes?.additions == 2 && done.changes?.deletions == 1)
    precondition(abs((done.result?.duration ?? 0) - 95) < 2 && done.result?.observedOnly == false)
    precondition(TurnStatus(activity: ended, turn: SessionTurn(completion: "done"), timing: live).result?.duration == nil,
                 "The line holds while the end time is still on its way")
    precondition(TurnStatus(activity: ended, turn: SessionTurn(completion: "done"), timing: finished, resultDismissed: true).state == .hidden)
    precondition(TurnStatus(activity: ended, turn: SessionTurn(completion: "done")).state == .hidden,
                 "An idle session this client never watched run takes no space")
    let failed = TurnStatus(activity: ConversationActivity(messages: user + command, isRunning: false), turn: SessionTurn(failed: true),
                            timing: finished)
    precondition(failed.state == .failed && failed.headline == "本轮失败" && failed.needsReader && failed.result == nil,
                 "A failed turn outranks uncertain tools and the result line, like the sidebar's attention section")
    let unfinished = ConversationActivity(messages: user + plan, isRunning: false)
    precondition(TurnStatus(activity: unfinished, turn: SessionTurn()).state == .plan)

    // Progress: any visible change moves the signature; a re-evaluation does not.
    let base = ConversationActivity(messages: user + command, isRunning: true, running: running)
    precondition(base.progressSignature == ConversationActivity(messages: user + command, isRunning: true, running: running).progressSignature)
    let result = try messages(#"[{"id":"res","role":"tool","created_at":"","content":[{"type":"tool_result","tool_call_id":"cmd","is_error":false,"output":"ok"}]}]"#)
    precondition(base.progressSignature != ConversationActivity(messages: user + command + result, isRunning: true).progressSignature)
    let short = try messages(#"[{"id":"t","role":"assistant","created_at":"","content":[{"type":"text","text":"正在"}]}]"#)
    let longer = try messages(#"[{"id":"t","role":"assistant","created_at":"","content":[{"type":"text","text":"正在检查"}]}]"#)
    precondition(ConversationActivity(messages: user + short, isRunning: true).progressSignature
                 != ConversationActivity(messages: user + longer, isRunning: true).progressSignature, "Streaming text is progress")
    precondition(TurnStatus.stalledMinutes(quietFor: 179, toolRunning: false) == nil)
    precondition(TurnStatus.stalledMinutes(quietFor: 180, toolRunning: false) == 3)
    precondition(TurnStatus.stalledMinutes(quietFor: 599, toolRunning: true) == nil)
    precondition(TurnStatus.stalledMinutes(quietFor: 600, toolRunning: true) == 10)

    // Seconds for the first minute, then minutes.
    precondition(TurnStatus.clock(45, chinese: true) == "45秒" && TurnStatus.clock(45, chinese: false) == "45s")
    precondition(TurnStatus.clock(61, chinese: true) == "1分" && TurnStatus.clock(359, chinese: false) == "5m")
    precondition(TurnStatus.clock(3720, chinese: true) == "1小时2分" && TurnStatus.clock(3600, chinese: false) == "1h")
    precondition(abs(TurnStatus.nextClockChange(after: 30.25) - 0.75) < 0.001 && TurnStatus.nextClockChange(after: 90) == 30)

    // Requests in one line of the agent's words.
    let ask: JSONValue = .object(["name": .string("AskUserQuestion"),
                                  "input": .object(["questions": .array([.object(["question": .string("用哪个分支？")])])])])
    precondition(TurnRequest.native([ask]) == TurnRequest(kind: .question, text: "用哪个分支？"))
    let confirm: JSONValue = .object(["title": .string("\n  运行 swift test\n第二行"), "message": .string("ignored")])
    precondition(TurnRequest.native([confirm]) == TurnRequest(kind: .approval, text: "运行 swift test"))
    precondition(TurnRequest.native([.object(["title": .string(String(repeating: "x", count: 200))])])?.text.count == 120)
    precondition(TurnRequest.native([]) == nil)
    let approvals = try KimiWire.decoder().decode([KimiApproval].self, from: Data(#"""
    [{"approval_id":"a","tool_name":"Bash","action":"Run rm -rf build","tool_input_display":{},"agent_id":"main"}]
    """#.utf8))
    precondition(TurnRequest.kimi(approvals: approvals, questions: []) == TurnRequest(kind: .approval, text: "Run rm -rf build"))
    // The changes page marks the working tree's entries this turn edited.
    let marked = TurnEditPaths.relative(["/repo/app/Sources/A.swift", "Sources/B.swift", "../other/C.swift", "~/D.swift", "/elsewhere/E.swift"],
                                        directory: "/repo/app", root: "/repo")
    precondition(marked == ["app/Sources/A.swift", "app/Sources/B.swift", "other/C.swift"], "\(marked)")
    print("PASS: turn status headlines, requests, ended results, turn-scoped edits, stall thresholds, the minute clock and turn edit paths")
}
