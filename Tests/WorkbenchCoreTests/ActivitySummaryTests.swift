import Foundation
import WorkbenchCore

func checkActivitySummaries() throws {
    func messages(_ value: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: value))
    }
    func user(_ id: String = "request", _ text: String = "Improve activity narratives") -> [String: Any] {
        ["id": id, "role": "user", "created_at": "", "content": [["type": "text", "text": text]]]
    }
    func thought(_ id: String = "thought", source: [String: Any]? = nil) -> [String: Any] {
        var part: [String: Any] = ["type": "thinking", "thinking": "PRIVATE_REASONING"]
        if let source { part["source"] = source }
        return ["id": id, "role": "assistant", "created_at": "", "content": [part]]
    }
    func progress(_ id: String = "progress", _ text: String) -> [String: Any] {
        ["id": id, "role": "assistant", "created_at": "", "content": [["type": "text", "text": text]]]
    }
    func call(_ id: String, name: String = "Read", input: [String: Any]? = nil) -> [String: Any] {
        ["id": "message-\(id)", "role": "assistant", "created_at": "", "content": [[
            "type": "tool_use", "tool_call_id": id, "tool_name": name,
            "input": input ?? ["path": "/project/Sources/\(id).swift"]
        ]]]
    }
    func tool(_ id: String, name: String = "Read", status: VisibleTool.Status = .returned,
              input: JSONValue? = nil) -> VisibleTool {
        VisibleTool(id: id, name: name,
                    input: input ?? .object(["path": .string("/private-project/Sources/\(id).swift")]),
                    output: .string("PRIVATE_TOOL_OUTPUT"), status: status)
    }
    func timeline(_ raw: [[String: Any]], running: Bool = true) throws -> [ConversationTimelineEntry] {
        ConversationTimelineEntry.make(try messages(raw), isRunning: running)
    }

    let thinkingEntries = try timeline([user(), thought()])
    let thinkingNarrative = ActivityNarrativeProjection.make(entries: thinkingEntries, tools: [:], isRunning: true).current
    precondition(thinkingNarrative?.source == .local && thinkingNarrative?.phase == .exploring)
    precondition(thinkingNarrative?.headline.isEmpty == false, "The first thought must immediately have a stable local title")

    let firstToolEntries = try timeline([user(), call("read0")])
    let read0 = tool("read0")
    let firstToolNarrative = ActivityNarrativeProjection.make(
        entries: firstToolEntries, tools: [read0.id: read0], isRunning: true).current
    precondition(firstToolNarrative?.source == .local && firstToolNarrative?.phase == .exploring)
    precondition(firstToolNarrative?.headline.isEmpty == false, "The first tool must immediately have a local title")
    func shellNarrative(_ command: String, key: String = "command", description: String? = nil) throws -> ActivityNarrative {
        var input: [String: Any] = [key: command]
        if let description { input["description"] = description }
        let entries = try timeline([user(), call("shell", name: "Bash", input: input)])
        let parsed = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: input))
        return ActivityNarrativeProjection.make(entries: entries,
            tools: ["shell": tool("shell", name: "Bash", input: parsed)], isRunning: true).current!
    }
    let cdTest = try shellNarrative("cd '/project/tests with spaces' && swift test")
    precondition(cdTest.headline == L("运行测试") && cdTest.phase == .validating)
    let waiting = try shellNarrative("sleep 30")
    precondition(waiting.headline == L("等待任务继续") && waiting.phase == .mixed)
    let wrapped = try shellNarrative("bash -lc 'cd /project && env MODE=ci python3 -m pytest'", key: "cmd")
    precondition(wrapped.headline == L("运行测试"))
    let echoed = try shellNarrative("echo 'please test and build; git commit'")
    precondition(echoed.phase == .mixed && echoed.headline == L("执行命令"),
                 "Quoted text is not an executed test or build")
    let inspection = try shellNarrative("cd /project/test && git diff --check")
    precondition(inspection.phase == .exploring && !inspection.headline.contains("cd"))
    let described = try shellNarrative("cd /project && swift test", description: "检查会话恢复是否保留草稿")
    precondition(described.headline == "检查会话恢复是否保留草稿", "Descriptions must not gain a mechanical phase prefix")
    let setupOnly = try shellNarrative("cd /project")
    precondition(setupOnly.headline == L("准备命令环境"))

    let completeProgress = "Both foreign changes check out. " + String(repeating: "Keep the complete explanation visible. ", count: 12) + "END_OF_PROGRESS"
    let fullEntries = try timeline([user(), progress("long-progress", completeProgress), call("read0")])
    let fullNarrative = ActivityNarrativeProjection.make(entries: fullEntries, tools: [read0.id: read0], isRunning: true).current!
    precondition(fullNarrative.headline == completeProgress && fullNarrative.headline.hasSuffix("END_OF_PROGRESS"),
                 "The history anchor and expanded activity must keep the entire progress message")
    let longDetailEntries = try timeline([user(), progress("long-detail", "检查结果：" + completeProgress), call("read0")])
    let longDetail = ActivityNarrativeProjection.make(entries: longDetailEntries, tools: [read0.id: read0], isRunning: true).current!
    precondition(longDetail.headline == "检查结果" && longDetail.detail == completeProgress)
    let multiPartSource: [String: Any] = ["kind": "activity_summary", "itemId": "multi-summary",
        "summaryParts": ["First summary part.", completeProgress], "state": "final"]
    let multiPartEntries = try timeline([user(), thought("multi", source: multiPartSource), call("read0")])
    let multiPart = ActivityNarrativeProjection.make(entries: multiPartEntries, tools: [read0.id: read0], isRunning: true).current!
    precondition(multiPart.headline == "First summary part. " + completeProgress)

    let read1 = tool("read1")
    let secondToolEntries = try timeline([user(), call("read0"), call("read1")])
    let secondToolNarrative = ActivityNarrativeProjection.make(
        entries: secondToolEntries, tools: [read0.id: read0, read1.id: read1], isRunning: true).current
    precondition(secondToolNarrative?.stageID == firstToolNarrative?.stageID,
                 "Appending work in the same semantic phase must retain its stage identity")

    let longRaw = [user()] + (0..<50).map { call("read\($0)") }
    let longEntries = try timeline(longRaw)
    let activityRows = longEntries.filter(\.activity)
    precondition(activityRows.map { $0.messages.count } == [24, 24, 2], "Process rows must remain bounded")
    let longTools = Dictionary(uniqueKeysWithValues: (0..<50).map {
        let value = tool("read\($0)")
        return (value.id, value)
    })
    let longProjection = ActivityNarrativeProjection.make(entries: longEntries, tools: longTools, isRunning: true)
    precondition(longProjection.stages.count == 1)
    precondition(Set(activityRows.compactMap { longProjection.entryStageIDs[$0.id] }).count == 1,
                 "The 24-row presentation split must not split the semantic stage")
    precondition(longProjection.current?.stageID == firstToolNarrative?.stageID,
                 "Stage identity must derive from the turn and first evidence, not the UI row")

    let edit0 = tool("edit0", name: "Edit", input: .object(["path": .string("/project/Sources/App.swift")]))
    let phaseEntries = try timeline([user(), call("read0"), call("edit0", name: "Edit", input: ["path": "/project/Sources/App.swift"])])
    let phaseProjection = ActivityNarrativeProjection.make(
        entries: phaseEntries, tools: [read0.id: read0, edit0.id: edit0], isRunning: true)
    precondition(phaseProjection.stages.map { $0.narrative.phase } == [.exploring, .editing],
                 "A tool phase transition must create a new semantic stage")
    precondition(phaseProjection.stages[0].narrative.stageID != phaseProjection.stages[1].narrative.stageID)

    let commentaryEntries = try timeline([
        user(), progress("progress", "Inspecting the activity summary flow"), call("read0"), call("read1")
    ])
    let commentaryProjection = ActivityNarrativeProjection.make(
        entries: commentaryEntries, tools: [read0.id: read0, read1.id: read1], isRunning: true)
    precondition(commentaryProjection.current?.source == .commentary)
    precondition(commentaryProjection.current?.headline == "Inspecting the activity summary flow")
    let commentarySourceEntry = commentaryEntries.first { $0.presentation == .progress }!
    let commentaryEvidenceEntry = commentaryEntries.first { $0.presentation == .activity }!
    precondition(commentarySourceEntry.isNarrativeSource(for: commentaryProjection.current!))
    precondition(!commentaryEvidenceEntry.isNarrativeSource(for: commentaryProjection.current!))
    precondition(commentaryProjection.row(for: commentarySourceEntry.id)?.isAnchor == true)
    precondition(commentaryProjection.row(for: commentarySourceEntry.id)?.stageClosed == false)
    precondition(commentaryProjection.row(for: commentaryEvidenceEntry.id)?.isAnchor == false,
                 "Only the source entry owns the live stage anchor")
    precondition(ActivitySummaryBatch.latest(in: commentaryEntries,
        tools: [read0.id: read0, read1.id: read1], isRunning: true, enabled: true) == nil,
        "Explicit agent progress must suppress external summarization")

    let handoffRead = tool("handoff-read")
    let handoffRunningEntries = try timeline([
        user("handoff-request"),
        progress("handoff-progress", "解冲突：保留我的结构，吸收 main 的新文案："),
        call("handoff-read")
    ])
    let handoffRunning = ActivityNarrativeProjection.make(
        entries: handoffRunningEntries, tools: [handoffRead.id: handoffRead], isRunning: true)
    precondition(handoffRunning.current?.subject == "解冲突")
    precondition(handoffRunning.current?.headline == "解冲突")
    precondition(handoffRunning.current?.detail == "保留我的结构，吸收 main 的新文案")
    precondition(handoffRunning.current?.phase == .integrating)
    precondition(handoffRunning.rows.values.filter { $0.isAnchor && $0.stageClosed }.isEmpty,
                 "An open stage leaves its full headline to the activity bar")
    let handoffCheck = tool("handoff-check")
    let switchedEntries = try timeline([
        user("handoff-request"),
        progress("handoff-progress", "解冲突：保留我的结构，吸收 main 的新文案："),
        call("handoff-read"),
        progress("handoff-check-progress", "验证：运行回归测试"),
        call("handoff-check")
    ])
    let switchedProjection = ActivityNarrativeProjection.make(entries: switchedEntries,
        tools: [handoffRead.id: handoffRead, handoffCheck.id: handoffCheck], isRunning: true)
    precondition(switchedProjection.rows.values.filter { $0.isAnchor && $0.stageClosed }.count == 1)
    precondition(switchedProjection.rows.values.filter { $0.isAnchor && !$0.stageClosed }.count == 1,
                 "A new stage closes the prior anchor and owns one new live anchor")
    let handoffClosedEntries = try timeline([
        user("handoff-request"),
        progress("handoff-progress", "解冲突：保留我的结构，吸收 main 的新文案："),
        call("handoff-read"),
        ["id": "handoff-answer", "role": "assistant", "created_at": "",
         "content": [["type": "text", "text": "Resolved."]]]
    ], running: false)
    let handoffClosed = ActivityNarrativeProjection.make(
        entries: handoffClosedEntries, tools: [handoffRead.id: handoffRead], isRunning: false)
    let closedOwners = handoffClosed.rows.values.filter { $0.isAnchor && $0.stageClosed }
    precondition(closedOwners.count == 1 && closedOwners[0].narrative.stageID == handoffClosed.current?.stageID,
                 "A closed stage hands its headline to exactly one transcript anchor")
    let commentaryExternal = commentaryProjection.applying([
        commentaryProjection.current!.stageID: ActivitySummaryResult(
            subject: "Ignored", phase: .editing, summary: "External replacement")
    ])
    precondition(commentaryExternal.current?.source == .commentary,
                 "External text must not replace explicit commentary")

    let providerSource: [String: Any] = [
        "kind": "activity_summary", "provider": "codex", "itemId": "reasoning-1",
        "turnId": "provider-turn",
        "summaryParts": ["Inspecting the narrative pipeline: mapping provider ownership:"], "state": "final"
    ]
    let providerMessages = try messages([user(), thought("provider-thought", source: providerSource), call("read0"), call("read1")])
    let providerPart = providerMessages[1].content[0]
    precondition(providerPart.source?["kind"].string == "activity_summary")
    precondition(providerPart.source?["summaryParts"].array.compactMap(\.string)
        == ["Inspecting the narrative pipeline: mapping provider ownership:"])
    let providerEntries = ConversationTimelineEntry.make(providerMessages, isRunning: true)
    let providerProjection = ActivityNarrativeProjection.make(
        entries: providerEntries, tools: [read0.id: read0, read1.id: read1], isRunning: true)
    precondition(providerProjection.current?.source == .provider)
    precondition(providerProjection.current?.subject == "Inspecting the narrative pipeline")
    precondition(providerProjection.current?.headline == "Inspecting the narrative pipeline")
    precondition(providerProjection.current?.detail == "mapping provider ownership")
    precondition(providerProjection.current?.lifecycle == .final)
    let providerSourceEntry = providerEntries.first { entry in
        entry.messages.contains { $0.id == "provider-thought" }
    }!
    precondition(providerSourceEntry.isNarrativeSource(for: providerProjection.current!))
    precondition(providerProjection.row(for: providerSourceEntry.id)?.isAnchor == true)
    let providerEvidenceEntry = providerEntries.first { entry in
        entry.presentation == .activity && !entry.isNarrativeSource(for: providerProjection.current!)
    }!
    precondition(providerProjection.row(for: providerEvidenceEntry.id)?.isAnchor == false,
                 "Provider source removal must leave its tool evidence in a separate row")
    let privateThinkingEntry = thinkingEntries.first { $0.isProcess }!
    precondition(!privateThinkingEntry.isNarrativeSource(for: thinkingNarrative!),
                 "Private thinking must remain visible and cannot become a narrative source row")
    precondition(ActivitySummaryBatch.latest(in: providerEntries,
        tools: [read0.id: read0, read1.id: read1], isRunning: true, enabled: true) == nil,
        "Provider-native summaries must suppress external summarization")
    let providerExternal = providerProjection.applying([
        providerProjection.current!.stageID: ActivitySummaryResult(
            subject: "Ignored", phase: .editing, summary: "External replacement")
    ])
    precondition(providerExternal.current?.source == .provider,
                 "Provider summaries must outrank external and local narratives")
    precondition(providerExternal.current?.headline == "Inspecting the narrative pipeline")

    let localProjection = ActivityNarrativeProjection.make(
        entries: secondToolEntries, tools: [read0.id: read0, read1.id: read1], isRunning: true)
    let externalResult = ActivitySummaryResult(subject: "Narratives", phase: .exploring,
        summary: "Reviewing the activity narrative implementation.", evidenceIDs: ["read0", "missing"])
    let externalProjection = localProjection.applying([localProjection.current!.stageID: externalResult])
    precondition(externalProjection.current?.source == .external)
    precondition(externalProjection.current?.headline == "Reviewing the activity narrative implementation.")
    precondition(externalProjection.current?.evidenceIDs == ["read0"])

    let read2 = tool("read2")
    let read3 = tool("read3")
    let edit1 = tool("edit1", name: "Edit", input: .object(["path": .string("/project/Sources/One.swift")]))
    let edit2 = tool("edit2", name: "Edit", input: .object(["path": .string("/project/Sources/Two.swift")]))
    let currentStageEntries = try timeline([
        user(), call("read0"), call("read1"), call("edit1", name: "Edit"), call("edit2", name: "Edit")
    ])
    let currentTools = [read0, read1, edit1, edit2].reduce(into: [String: VisibleTool]()) { $0[$1.id] = $1 }
    let currentBatch = ActivitySummaryBatch.latest(in: currentStageEntries, tools: currentTools,
                                                   isRunning: true, enabled: true)
    precondition(currentBatch?.phase == .editing && currentBatch?.records.map(\.id) == ["edit1", "edit2"],
                 "External batches must use only the current semantic stage")
    precondition(ActivitySummaryBatch.latest(in: currentStageEntries, tools: currentTools,
                                             isRunning: true, enabled: false) == nil)

    let toolOnlyEnded = try timeline([user(), call("read0"), call("edit1", name: "Edit")], running: false)
    let endedNarrative = ActivityNarrativeProjection.make(entries: toolOnlyEnded,
        tools: currentTools, isRunning: false)
    precondition(endedNarrative.stages.count == 2 && endedNarrative.current?.phase == .editing,
        "The empty-output placeholder must not replay the first tool as another stage")
    precondition(Set(endedNarrative.stages.map { $0.narrative.stageID }).count == endedNarrative.stages.count)

    let initial = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
                                       tools: [read0, read1], closed: false)
    precondition(initial.shouldRequest(after: nil), "The first meaningful stage can be summarized immediately")
    precondition(!initial.shouldRequest(after: initial), "Repeated observation must not incur another request")
    let plusThree = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
                                         tools: [read0, read1, read2, read3, tool("read4")], closed: false)
    precondition(!plusThree.shouldRequest(after: initial))
    let plusFour = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
                                        tools: [read0, read1, read2, read3, tool("read4"), tool("read5")], closed: false)
    precondition(!plusFour.shouldRequest(after: initial), "Read counts alone must never refresh a stage")
    let closed = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
                                      tools: [read0, read1], closed: true)
    precondition(closed.shouldRequest(after: initial), "Closing a stage gets one final refresh")
    let corrected = ActivitySummaryBatch(groupID: "stage", phase: .blocked,
        tools: [tool("read0", status: .failed), read1], closed: false)
    precondition(corrected.shouldRequest(after: initial), "An authoritative status correction invalidates the prior batch")
    let nextStage = ActivitySummaryBatch(groupID: "next-stage", phase: .editing,
                                         tools: [edit0, edit1], closed: false)
    precondition(nextStage.shouldRequest(after: initial), "A new semantic stage triggers immediately")
    let oneTool = ActivitySummaryBatch(groupID: "one", tools: [read0], closed: true)
    precondition(oneTool.shouldRequest(after: nil), "Short tasks also get a summary")

    let sensitiveCommand = "swift test --filter PRIVATE_COMMAND_ARGUMENT"
    let sensitive = VisibleTool(id: "sensitive", name: "Bash", input: .object([
        "command": .string(sensitiveCommand), "description": .string("Run focused tests"),
        "content": .string("PRIVATE_EDIT_CONTENT"), "diff": .string("PRIVATE_DIFF"),
        "source": .string("PRIVATE_SOURCE"), "reasoning": .string("PRIVATE_REASONING"),
        "runtime_context": .string("PRIVATE_RUNTIME_CONTEXT")
    ]), output: .string("PRIVATE_TOOL_OUTPUT"), status: .returned)
    let pathComponent = String(repeating: "p", count: 100)
    let longPath = "/private-project/\(pathComponent)/\(pathComponent)/\(pathComponent)/Summary.swift"
    let bounded = VisibleTool(id: "bounded", name: "Edit", input: .object([
        "path": .string(longPath), "command": .string("echo PRIVATE_SECOND_COMMAND"),
        "content": .string("PRIVATE_SECOND_EDIT")
    ]), output: .string("PRIVATE_SECOND_OUTPUT"), status: .returned)
    let privateBatch = ActivitySummaryBatch(groupID: "private", phase: .validating,
                                            tools: [sensitive, bounded], closed: true)
    let privateInput = String(decoding: try JSONEncoder().encode(privateBatch.records), as: UTF8.self)
    precondition(privateBatch.records[1].target.count <= 240)
    precondition(privateInput.contains("Run focused tests") && privateInput.contains("test"),
                 "Descriptions and derived command categories may inform the external model")
    for secret in [sensitiveCommand, "PRIVATE_EDIT_CONTENT", "PRIVATE_DIFF", "PRIVATE_SOURCE",
                   "PRIVATE_REASONING", "PRIVATE_RUNTIME_CONTEXT", "PRIVATE_TOOL_OUTPUT",
                   "PRIVATE_SECOND_COMMAND", "PRIVATE_SECOND_EDIT", "PRIVATE_SECOND_OUTPUT"] {
        precondition(!privateInput.contains(secret), "External activity records leaked \(secret)")
    }
    let large = ActivitySummaryBatch(groupID: "large", tools: (0..<50).map { tool("read\($0)") }, closed: false)
    precondition(large.records.count == 12 && large.completedCount == 50)
    precondition(large.records.first?.id == "read38")

    let requestWithRuntime: [String: Any] = [
        "id": "bounded-request", "role": "user", "created_at": "", "content": [
            ["type": "text", "text": String(repeating: "abcdefghij \n", count: 100)],
            ["type": "text", "text": "<system-reminder>PRIVATE_REQUEST_CONTEXT</system-reminder>"]
        ]
    ]
    let requestEntries = try timeline([requestWithRuntime, call("read0"), call("read1")])
    let requestBatch = ActivitySummaryBatch.latest(in: requestEntries,
        tools: [read0.id: read0, read1.id: read1], isRunning: true, enabled: true)
    precondition(requestBatch?.userRequest == String(repeating: "abcdefghij \n", count: 100),
                 "The full current user request must survive, including its tail and line breaks")
    precondition(requestBatch?.userRequest.contains("PRIVATE_REQUEST_CONTEXT") == false,
                 "Runtime context must not enter the request excerpt")

    let longProgress = "A public progress update " + String(repeating: "detail ", count: 100)
    let progressEntries = try timeline([user("old", "Old request"), progress("old-progress", "OLD_PROGRESS"),
        user(), progress("p0", "Older current progress"), progress("p1", "Inspecting inputs"),
        progress("p2", longProgress), thought(), call("read0"), call("edit1", name: "Edit")])
    let contextBatch = ActivitySummaryBatch.latest(in: progressEntries,
        tools: [read0.id: read0, edit1.id: edit1], isRunning: true, enabled: true)!
    precondition(contextBatch.recentProgress == ["Older current progress", "Inspecting inputs", longProgress])
    precondition(!contextBatch.recentProgress.joined().contains("PRIVATE_REASONING"))
    let started = ActivitySummaryBatch(groupID: "test", phase: .validating,
        tools: [tool("test", name: "Bash", status: .running, input: .object(["command": .string("swift test")]))], closed: false)
    precondition(started.shouldRequest(after: nil) && started.records[0].status == "running")
    let passed = ActivitySummaryBatch(groupID: "test", phase: .validating,
        tools: [tool("test", name: "Bash", status: .succeeded, input: .object(["command": .string("swift test")]))], closed: false)
    precondition(passed.shouldRequest(after: started), "A single test result is a key event")
    let idleWait = VisibleTool(id: "wait", name: "Bash", input: .object(["command": .string("sleep 2")]),
        output: .object(["exit_code": .number(0)]), status: .succeeded)
    let poll = tool("poll", name: "write_stdin", input: .object(["chars": .string("")]))
    let justWaits = ActivitySummaryBatch(groupID: "waits", tools: [idleWait, poll], closed: false)
    precondition(!justWaits.shouldRequest(after: nil))
    let moreReadsAndWaits = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
        tools: [read0, read1, idleWait, poll] + (0..<30).map { tool("r\($0)") }, closed: false)
    precondition(!moreReadsAndWaits.shouldRequest(after: initial), "Polling and read-window eviction are not events")
    let failedWait = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
        tools: [read0, read1, tool("wait", name: "Bash", status: .failed,
        input: .object(["command": .string("sleep 2")]))], closed: false)
    precondition(failedWait.shouldRequest(after: initial), "Failures must not be hidden as waiting")
    let explicitResult = VisibleTool(id: "final-poll", name: "write_stdin", input: .object(["chars": .string("")]),
        output: .object(["exit_code": .number(1), "output": .string(String(repeating: "x", count: 1000) + "FINAL_ERROR")]), status: .returned)
    let outputBatch = ActivitySummaryBatch(groupID: "test", phase: .validating,
        tools: [explicitResult], closed: true, includeToolOutput: true)
    precondition(outputBatch.records[0].exitCode == 1 && outputBatch.records[0].status == "returned")
    precondition(outputBatch.records[0].outputExcerpt!.count == 600)
    precondition(outputBatch.records[0].outputExcerpt!.hasSuffix("FINAL_ERROR"))
    precondition(outputBatch.shouldRequest(after: passed), "A final poll with an exit code is a result, not idle polling")
    let retained = ActivitySummaryBatch(groupID: "test", tools: [explicitResult] + (0..<30).map { tool("r\($0)") }, closed: true)
    precondition(retained.records.count == 12 && retained.records.first?.id == "final-poll",
        "Key results must remain available even after many reads")
    let manyResults = (0..<2_000).map { index in
        VisibleTool(id: "edit-\(index)", name: "Edit", input: .object(["path": .string("/project/File.swift")]),
            output: .string(String(repeating: "result", count: 200)), status: .returned)
    }
    let longStage = ActivitySummaryBatch(groupID: "long-stage", tools: manyResults, closed: false, includeToolOutput: true)
    let repeatedLongStage = ActivitySummaryBatch(groupID: "long-stage", tools: manyResults + [read0, idleWait, poll],
        closed: false, includeToolOutput: true)
    precondition(longStage.records.count == 12 && repeatedLongStage.records.count == 12)
    precondition(!repeatedLongStage.shouldRequest(after: longStage),
        "Fingerprinting a long history must remain stable across reads and polling")
    var correctedResults = manyResults
    correctedResults[0] = VisibleTool(id: "edit-0", name: "Edit", input: manyResults[0].input, status: .failed)
    let correctedLongStage = ActivitySummaryBatch(groupID: "long-stage", tools: correctedResults,
        closed: false, includeToolOutput: true)
    precondition(correctedLongStage.shouldRequest(after: longStage),
        "An authoritative correction outside the recent window still invalidates the fingerprint")
    var revisedOutput = manyResults
    revisedOutput[1_999] = VisibleTool(id: "edit-1999", name: "Edit", input: manyResults.last!.input,
        output: .string("Updated result"), status: .returned)
    precondition(ActivitySummaryBatch(groupID: "long-stage", tools: revisedOutput, closed: false, includeToolOutput: true)
        .shouldRequest(after: longStage), "Recent result text corrections remain visible")

    var retainedCorrection = manyResults
    retainedCorrection[1_996] = VisibleTool(id: "edit-1996", name: "Edit", input: manyResults[1_996].input,
        output: .string("Corrected fourth-last result"), status: .returned)
    precondition(ActivitySummaryBatch(groupID: "long-stage", tools: retainedCorrection, closed: false, includeToolOutput: true)
        .shouldRequest(after: longStage), "Payload corrections inside the prompt but outside the last three results must refresh")
    let evictedKeys = ActivitySummaryBatch(groupID: "long-stage", tools: manyResults + (0..<30).map { tool("read-\($0)") },
        closed: false, includeToolOutput: true)
    precondition(!evictedKeys.shouldRequest(after: longStage), "Read-window eviction of older key results is not a correction")

    let legacyConfig = try JSONDecoder().decode(ActivitySummaryConfiguration.self, from: Data(#"{"enabled":true}"#.utf8))
    precondition(!legacyConfig.includeToolOutput, "Upgrades must not enable output sharing")

    let client = ActivitySummaryClient()
    var config = ActivitySummaryConfiguration()
    precondition(!config.enabled && config.baseURL.isEmpty && config.model.isEmpty)
    config.baseURL = "http://localhost:8000/v1/"
    config.model = "summary-model"
    precondition(config.endpoint?.absoluteString == "http://localhost:8000/v1/chat/completions")
    do {
        _ = try client.request(configuration: config, apiKey: "", batch: privateBatch, language: "zh-Hans")
        preconditionFailure("Disabled external summaries must not produce a request")
    } catch ActivitySummaryError.configuration {}
    config.enabled = true
    config.disableThinking = true
    let previous = ActivitySummaryResult(subject: "Activity narratives", phase: .exploring,
        summary: "Inspecting the existing narrative flow.", evidenceIDs: ["sensitive"], shouldUpdate: true)
    let request = try client.request(configuration: config, apiKey: "test-token", batch: privateBatch,
                                     language: "zh-Hans", previous: previous)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let requestMessages = body["messages"] as! [[String: Any]]
    let systemMessage = requestMessages[0]["content"] as! String
    precondition(systemMessage.contains("semantic observer") && systemMessage.contains("at most 100 characters"))
    precondition(systemMessage.contains("should_update") && systemMessage.contains("compact JSON object"))
    let promptText = requestMessages[1]["content"] as! String
    let prompt = try JSONSerialization.jsonObject(with: Data(promptText.utf8)) as! [String: Any]
    let previousPrompt = prompt["previous"] as! [String: Any]
    let activities = prompt["activities"] as! [[String: Any]]
    precondition(prompt["current_phase"] as? String == "validating")
    precondition(prompt["group_closed"] as? Bool == true && activities.count == 2)
    precondition(previousPrompt["phase"] as? String == "exploring")
    let contextRequest = try client.request(configuration: config, apiKey: "", batch: contextBatch, language: "en")
    let contextBody = String(decoding: contextRequest.httpBody!, as: UTF8.self)
    precondition(contextBody.contains("recent_progress") && contextBody.contains(longProgress))
    precondition(!contextBody.contains("OLD_PROGRESS") && !contextBody.contains("PRIVATE_REASONING"))
    let bodyText = String(decoding: request.httpBody!, as: UTF8.self)
    precondition(!bodyText.contains(sensitiveCommand) && !bodyText.contains("PRIVATE_TOOL_OUTPUT"))
    precondition(!bodyText.contains("test-token"))
    precondition(body["tools"] == nil && body["stream"] as? Bool == false && body["max_tokens"] as? Int == 512)
    precondition((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    let outputDisabled = try client.request(configuration: config, apiKey: "", batch: outputBatch, language: "en")
    precondition(!String(decoding: outputDisabled.httpBody!, as: UTF8.self).contains("FINAL_ERROR"),
        "The request boundary also enforces the output opt-in")
    config.includeToolOutput = true
    let outputEnabled = try client.request(configuration: config, apiKey: "", batch: outputBatch, language: "en")
    precondition(String(decoding: outputEnabled.httpBody!, as: UTF8.self).contains("FINAL_ERROR"))
    config.includeToolOutput = false
    config.disableThinking = false
    let standard = try client.request(configuration: config, apiKey: "", batch: privateBatch, language: "en")
    let standardBody = try JSONSerialization.jsonObject(with: standard.httpBody!) as! [String: Any]
    precondition(standardBody["chat_template_kwargs"] == nil && standard.value(forHTTPHeaderField: "Authorization") == nil)
    config.baseURL = "http://user:password@localhost:8000/v1"
    precondition(!config.isValid, "Credentials must not be persisted inside the endpoint URL")

    func completion(_ text: String, finishReason: String = "stop") throws -> Data {
        let message: [String: Any] = ["content": text, "reasoning_content": "PRIVATE_REASONING"]
        return try JSONSerialization.data(withJSONObject: [
            "choices": [["message": message, "finish_reason": finishReason]]
        ])
    }
    let plainResponse = try ActivitySummaryClient.responseText(completion(" Plain session name. "))
    precondition(plainResponse == "Plain session name.")
    let semantic = try ActivitySummaryClient.responseResult(try completion(
        #"{"subject":"Narratives","phase":"editing","summary":"Unified the activity narrative.","evidence_ids":["sensitive","sensitive","missing","bounded","extra"],"should_update":false}"#),
        evidenceIDs: Set(["sensitive", "bounded", "extra"]))
    precondition(semantic.subject == "Narratives" && semantic.phase == .editing)
    precondition(semantic.summary == "Unified the activity narrative." && semantic.shouldUpdate == false)
    precondition(semantic.evidenceIDs == ["sensitive", "bounded", "extra"],
                 "Evidence must reference known records, remain unique, and stay bounded")
    let fenced = try ActivitySummaryClient.responseResult(try completion("""
        ```json
        {"subject":"Tests","phase":"validating","summary":"Validated the response parser.","evidence_ids":["bounded"],"should_update":true}
        ```
        """), evidenceIDs: Set(["bounded"]))
    precondition(fenced.phase == .validating && fenced.evidenceIDs == ["bounded"])
    let plain = try ActivitySummaryClient.responseResult(
        try completion(" Kept a compatible plain-text summary. "), evidenceIDs: [])
    precondition(plain.subject.isEmpty && plain.phase == .mixed)
    precondition(plain.summary == "Kept a compatible plain-text summary." && plain.shouldUpdate)
    let sleepAfterProgress = tool("wait", name: "Bash", status: .running, input: .object(["command": .string("sleep 30")]))
    let progressThenWait = try timeline([user(), progress("wait-progress", "Checking the regression results"), call("read0"), call("wait", name: "Bash", input: ["command": "sleep 30"])])
    let waitingStage = ActivityNarrativeProjection.make(entries: progressThenWait,
        tools: [read0.id: read0, "wait": sleepAfterProgress], isRunning: true)
    precondition(waitingStage.current?.source == .commentary && waitingStage.current?.headline == "Checking the regression results",
                 "Polling and sleep must not displace meaningful agent progress")
    let fullExternal = try ActivitySummaryClient.responseResult(try completion(completeProgress), evidenceIDs: [])
    precondition(fullExternal.summary == completeProgress)
    precondition(localProjection.applying([localProjection.current!.stageID: fullExternal]).current?.headline == completeProgress)
    do {
        _ = try ActivitySummaryClient.responseResult(try completion(
            #"{"subject":"Bad","phase":"planning","summary":"Invalid phase"}"#), evidenceIDs: [])
        preconditionFailure("Unknown structured phases must be rejected")
    } catch ActivitySummaryError.invalidResponse {}
    do {
        _ = try ActivitySummaryClient.responseResult(try completion(#"{"summary": }"#), evidenceIDs: [])
        preconditionFailure("Malformed structured output must not replace a valid summary")
    } catch ActivitySummaryError.invalidResponse {}
    do {
        _ = try ActivitySummaryClient.responseText(try completion("Read", finishReason: "length"))
        preconditionFailure("Do not publish a sentence truncated by the token limit")
    } catch ActivitySummaryError.truncated {}

    print("PASS: unified activity narratives, source priority, bounded external refinement and Codex metadata")
}
