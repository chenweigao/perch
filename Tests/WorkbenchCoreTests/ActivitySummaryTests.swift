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

    let initial = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
                                       tools: [read0, read1], closed: false)
    precondition(initial.shouldRequest(after: nil), "The first external refinement starts at two completed tools")
    precondition(!initial.shouldRequest(after: initial), "Repeated observation must not incur another request")
    let plusThree = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
                                         tools: [read0, read1, read2, read3, tool("read4")], closed: false)
    precondition(!plusThree.shouldRequest(after: initial))
    let plusFour = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
                                        tools: [read0, read1, read2, read3, tool("read4"), tool("read5")], closed: false)
    precondition(plusFour.shouldRequest(after: initial), "The same stage refreshes after four more completions")
    let closed = ActivitySummaryBatch(groupID: "stage", phase: .exploring,
                                      tools: [read0, read1], closed: true)
    precondition(closed.shouldRequest(after: initial), "Closing a stage gets one final refresh")
    let corrected = ActivitySummaryBatch(groupID: "stage", phase: .blocked,
        tools: [tool("read0", status: .failed), read1], closed: false)
    precondition(corrected.shouldRequest(after: initial), "An authoritative status correction invalidates the prior batch")
    let nextStage = ActivitySummaryBatch(groupID: "next-stage", phase: .editing,
                                         tools: [edit0, edit1], closed: false)
    precondition(nextStage.shouldRequest(after: initial), "A new semantic stage has its own threshold")
    let oneTool = ActivitySummaryBatch(groupID: "one", tools: [read0], closed: true)
    precondition(!oneTool.shouldRequest(after: nil))

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
    precondition(requestBatch?.userRequest.count == 400 && requestBatch?.userRequest.contains("\n") == false)
    precondition(requestBatch?.userRequest.contains("PRIVATE_REQUEST_CONTEXT") == false,
                 "Runtime context must not enter the request excerpt")

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
    let bodyText = String(decoding: request.httpBody!, as: UTF8.self)
    precondition(!bodyText.contains(sensitiveCommand) && !bodyText.contains("PRIVATE_TOOL_OUTPUT"))
    precondition(!bodyText.contains("test-token"))
    precondition(body["tools"] == nil && body["stream"] as? Bool == false && body["max_tokens"] as? Int == 180)
    precondition((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
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
