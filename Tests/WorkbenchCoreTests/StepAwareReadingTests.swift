import Foundation
import WorkbenchCore

func checkStepAwareReading() throws {
    let source = """
    [{"id":"u","role":"user","created_at":"1","content":[{"type":"text","text":"修复"}]},
     {"id":"a","role":"assistant","created_at":"2","content":[
       {"type":"thinking","thinking":"检查"},
       {"type":"tool_use","tool_call_id":"r","tool_name":"read","input":{"path":"a.swift"}},
       {"type":"tool_use","tool_call_id":"s","tool_name":"search","input":{"pattern":"foo"}},
       {"type":"text","text":"修改两次"},
       {"type":"tool_use","tool_call_id":"e1","tool_name":"edit","input":{"path":"a.swift","old_string":"old","new_string":"first"}},
       {"type":"tool_use","tool_call_id":"e2","tool_name":"edit","input":{"path":"a.swift","old_string":"first","new_string":"second"}}]},
     {"id":"result","role":"tool","created_at":"3","content":[
       {"type":"tool_result","tool_call_id":"e1","output":"ok","is_error":false},
       {"type":"tool_result","tool_call_id":"e2","output":"rejected","is_error":true}]},
     {"id":"final","role":"assistant","created_at":"4","content":[{"type":"text","text":"完成"}]}]
    """
    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: Data(source.utf8))
    let live = ConversationTimelineEntry.make(messages, isRunning: true)
    let done = ConversationTimelineEntry.make(messages, isRunning: false)
    precondition(live.map(\.id) == done.map(\.id), "Completion preserves every step's reading anchor")
    precondition(done.filter(\.isExploration).count == 1)
    precondition(done.first(where: \.isExploration)?.messages.count == 3)
    precondition(done.filter(\.activity).map(\.id) == ["thinking:a:0", "activity:tool:e1", "activity:tool:e2"])
    precondition(done.flatMap(\.messages).flatMap(\.content) == messages.filter { $0.role != "tool" }.flatMap(\.content))
    let projected = ToolVisibilityProjection().update(messages, sessionID: "step-tests")
    let first = projected.tools["e1"]!, failed = projected.tools["e2"]!
    precondition(first.status == .succeeded && failed.status == .failed)
    let record = ConversationEditRecord(step: first, messages: messages)
    precondition(record.hasTurn && record.turn.map(\.id) == ["e1", "e2"])
    precondition(record.appliedTotal == SessionEditStat(additions: 1, deletions: 1), "Failed edits cannot add to applied churn")
    precondition(ToolInlineDiff.derive(from: record.step)?.lines.contains { $0.text == "+ first" } == true)
    let later = ConversationEditRecord(step: failed, messages: messages)
    precondition(later.step.id == "e2" && record.step.input?["new_string"].string == "first", "Later selection cannot mutate the earlier record")
    let repeated = try KimiWire.decoder().decode([KimiMessage].self, from: Data(source.replacingOccurrences(of: "\"id\":\"a\"", with: "\"id\":\"later-a\"").utf8))
    let laterTurn = ConversationEditRecord(step: first, messages: messages + repeated, messageID: "later-a")
    precondition(laterTurn.turn.count == 2 && laterTurn.hasTurn, "Message anchors select the right turn even when a provider reuses tool IDs")
    let missing = ConversationEditRecord(step: first, messages: [])
    precondition(!missing.hasTurn && missing.turn == [first], "Missing history remains explicitly partial")
    for status in [VisibleTool.Status.running, .awaitingApproval, .missingResult, .disconnected, .failed] {
        let pending = VisibleTool(id: "pending", name: "edit", input: first.input, status: status)
        precondition(ConversationEditRecord(step: pending, messages: []).appliedTotal == .init(additions: 0, deletions: 0))
    }
    let model = ConversationPresentationModel(key: "step-tests")
    let snapshot = model.update(.init(messages: messages, isRunning: false, language: "en"))
    let shown = snapshot.presented(activity: [:], foldsProcess: false, isRunning: false)
    precondition(shown.rows.contains { $0.entry.id == "activity:tool:e1" })
    precondition(shown.rows.contains { $0.entry.id == "activity:tool:e2" })
    print("PASS: step reading preserves order, edit identities, historical patches and outcome-aware churn")
}

func checkPhaseReading() throws {
    func message(_ id: String, _ content: [[String: Any]], role: String = "assistant") -> [String: Any] {
        ["id": id, "role": role, "created_at": "1", "content": content]
    }
    func call(_ id: String, _ command: String) -> [String: Any] {
        message(id, [["type": "tool_use", "tool_call_id": id, "tool_name": "Bash", "input": ["command": command]]])
    }
    func thought(_ id: String) -> [String: Any] { message(id, [["type": "thinking", "thinking": "continue " + id]]) }
    func decode(_ source: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: source))
    }
    var source = [message("u", [["type": "text", "text": "inspect"]], role: "user"), thought("first")]
    let commands = ["grep provider src.swift", "ls Sources", "find Sources -name '*.swift'", "rg runtime Sources", "cat README.md", "grep context README.md", "rg compact Sources", "[ -f AGENTS.md ]"]
    for (index, command) in commands.enumerated() {
        source.append(call("shell\(index)", command))
        if index % 2 == 0 { source.append(thought("t\(index)")) }
    }
    let liveMessages = try decode(source)
    let live = ConversationTimelineEntry.make(liveMessages, isRunning: true)
    precondition(live.count == 2 && live[1].isExploration, "Eight shell calls and intervening thoughts occupy one stage")
    precondition(live[1].messages.flatMap(\.content).filter { $0.type == "tool_use" }.count == 8)
    let firstAnchor = ConversationTimelineEntry.make(Array(liveMessages.prefix(2)), isRunning: true).last!.id
    precondition(live[1].id == firstAnchor, "A thought becoming a phase retains its reading anchor")
    source += [message("progress", [["type": "text", "text": "now edit"]])]
    for id in ["edit-a", "edit-b"] {
        source.append(message(id, [["type": "tool_use", "tool_call_id": id, "tool_name": "edit", "input": ["path": "a.swift", "old_string": "old", "new_string": "new"]]]))
    }
    source += [call("test", "swift test"), thought("test-thought"), call("build", "swift build"),
               call("mixed", "rg foo src; rm scratch"), thought("mixed-thought"),
               call("unknown", "custom-task --run"), message("answer", [["type": "text", "text": "done"]])]
    let messages = try decode(source)
    let done = ConversationTimelineEntry.make(messages)
    precondition(done.filter(\.activity).map(\.processPhase) == [.exploring, nil, nil, .validating, .mixed])
    precondition(done.filter(\.activity).filter { $0.processPhase == nil }.map(\.id) == ["activity:tool:edit-a", "activity:tool:edit-b"])
    precondition(done.flatMap(\.messages).flatMap(\.content) == messages.flatMap(\.content), "Grouping retains exact chronology and every source part")
    precondition(done.map(\.id) == ConversationTimelineEntry.make(messages, isRunning: true).map(\.id), "Completion cannot reshuffle phases")
    for command in ["grep x a > output", "find . -delete", "sed -i '' s/a/b/ a", "rg x a | custom", "cat $(custom)", "if [ -f a ]; then rm a; fi"] {
        let rows = ConversationTimelineEntry.make(try decode([call("complex", command)]), isRunning: true)
        precondition(rows.first?.processPhase == .mixed, "A complex command cannot borrow a read label: \(command)")
    }
    let mixedStage = ConversationTimelineEntry.make(try decode([call("read-first", "rg foo src"), thought("bridge"), call("compound", "SDK=$(find /tmp -name sdk.d.ts); echo $SDK"), call("read-last", "cat README.md")]), isRunning: true)
    precondition(mixedStage.count == 1 && mixedStage[0].processPhase == .mixed, "Uncertain shell syntax cannot fragment one continuous stage or inherit its exploration label")
    let labels: [(String, String)] = [("SDK=$(find /tmp -name sdk.d.ts); echo $SDK", "执行命令"), ("Q=$(readlink -f /tmp/bin); echo $Q", "执行命令"), ("-f path", "执行命令"), ("test -f file", "检查条件"),
        ("[ -f file ]", "检查条件"), ("env -u TOKEN git -C /tmp status", "git status"),
        ("bash -lc 'git -C /tmp diff'", "git diff"), ("npm run test", "npm run test")]
    for (command, expected) in labels {
        let tool = VisibleTool(id: "label", name: "Bash", input: .object(["command": .string(command)]), status: .succeeded)
        precondition(ToolPresentation.compactTarget(tool) == L(key: expected), "Useful command summary for \(command): \(ToolPresentation.compactTarget(tool))")
    }
    let failed = message("failed", [["type": "tool_result", "tool_call_id": "shell0", "is_error": true, "output": "failed"]], role: "tool")
    let snapshot = ConversationPresentationModel(key: "phase-reading").update(.init(messages: try decode(source + [failed]), language: "zh-Hans"))
    let visible = snapshot.presented(activity: [:], foldsProcess: false, isRunning: false)
    precondition(visible.rows.first { $0.entry.isExploration }?.tools["shell0"]?.status == .failed, "A folded stage retains failed tool status for the visible failure summary")
    let error = VisibleTool(id: "error", name: "shell", input: nil, status: .failed)
    precondition(!ToolPresentation.showsResultOutsideStage(error, isLive: false, lastPartToolID: "error"), "Historical failures remain in the stage summary, not permanent extra rows")
    precondition(!ToolPresentation.showsResultOutsideStage(error, isLive: true, lastPartToolID: "next"), "A subsequent call makes a returned failure historical without changing its status")
    precondition(ToolPresentation.showsResultOutsideStage(error, isLive: true, lastPartToolID: "error"), "The current failed call remains directly readable")
    for state in [VisibleTool.Status.awaitingApproval, .missingResult, .disconnected] {
        let unresolved = VisibleTool(id: "pending", name: "shell", input: nil, status: state)
        precondition(ToolPresentation.showsResultOutsideStage(unresolved, isLive: false, lastPartToolID: "later"), "Later work cannot hide authorization or missing evidence")
    }
    let described = VisibleTool(id: "description", name: "shell", input: .object(["command": .string("custom"), "description": .string("核对失败参数")]), status: .failed)
    precondition(ToolPresentation.phaseTitle(.mixed, tools: [described]) == "核对失败参数", "Use supplied work descriptions without inventing success")
    let script = VisibleTool(id: "script", name: "shell", input: .object(["command": .string("/bin/bash -lc 'PYTHONPATH=src .venv/bin/python /tmp/profile_scalar.py --limit 60'")]), status: .failed)
    precondition(ToolPresentation.phaseTitle(.mixed, tools: [script]).contains("profile_scalar.py"), "The actual script identifies the stage despite shell and environment wrappers")
    let incidental = VisibleTool(id: "incidental", name: "shell", input: .object(["command": .string("readlink -f .venv")]), status: .succeeded)
    let read = VisibleTool(id: "read", name: "read", input: nil, status: .succeeded)
    let stageTitle = ToolPresentation.phaseTitle(.mixed, tools: [incidental, read, script])
    precondition(stageTitle.contains("profile_scalar.py") && !stageTitle.contains("readlink"), "Incidental commands must not displace the phase's identifiable work")
    for command in ["sed -i '' s/a/b/ file", "find . -delete"] {
        let mutation = VisibleTool(id: "mutation", name: "shell", input: .object(["command": .string(command)]), status: .succeeded)
        precondition(!ToolPresentation.phaseTitle(.mixed, tools: [mutation]).contains(L("查看文件与代码")), "Read-like executables can write; do not label them as reading")
    }
    let unknown = VisibleTool(id: "unknown", name: "shell", input: .object(["command": .string("$(choose_command) --run")]), status: .succeeded)
    precondition(ToolPresentation.phaseTitle(.mixed, tools: [unknown]) == L("执行命令"), "Unparsed commands retain a neutral summary")
    print("PASS: phase reading groups Bash and thoughts, preserves edit receipts, separates historical failures from pending work and uses grounded command labels")
}
