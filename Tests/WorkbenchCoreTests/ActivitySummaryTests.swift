import Foundation
import WorkbenchCore

func checkActivitySummaries() throws {
    func messages(_ value: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: value))
    }
    func read(_ index: Int, name: String = "Read") -> [String: Any] {
        ["id": "m\(index)", "role": "assistant", "created_at": "", "content": [
            ["type": "tool_use", "tool_call_id": "call\(index)", "tool_name": name,
             "input": ["path": "/project/Sources/File\(index).swift"]]]]
    }
    let sources = try messages((0..<11).map { read($0, name: $0 < 8 ? "Read" : "Grep") })
    let grouped = ConversationTimelineEntry.make(sources, isRunning: true)
    precondition(grouped.count == 1 && grouped[0].messages.count == 11)
    precondition(grouped[0].messages.flatMap(\.content).compactMap(\.toolCallId) == (0..<11).map { "call\($0)" })
    let first = ConversationTimelineEntry.make(Array(sources.prefix(1)), isRunning: true)
    precondition(grouped[0].id == first[0].id, "Appending calls must retain the reading/expansion anchor")
    let boundary: [String: Any] = ["id": "guidance", "role": "user", "created_at": "", "content": [["type": "text", "text": "Check the UI too"]]]
    let separated = ConversationTimelineEntry.make(try messages([read(0), boundary, read(1), read(2, name: "Edit"), read(3)]), isRunning: true)
    precondition(separated.filter(\.activity).count == 2 && separated.last?.messages.count == 3, "User guidance splits stages; edits retain their place inside the next stage")
    let commentary: [String: Any] = ["id": "progress", "role": "assistant", "created_at": "", "content": [["type": "text", "text": "Checking the next file"]]]
    let withCommentary = ConversationTimelineEntry.make(try messages([read(0), commentary, read(1)]), isRunning: true)
    precondition(withCommentary.count == 3)
    let long = ConversationTimelineEntry.make(try messages((0..<50).map { read($0) }), isRunning: true)
    precondition(long.map { $0.messages.count } == [24, 24, 2], "Expanded groups must remain bounded")

    let raw: [[String: Any]] = [read(0), read(1), ["id": "result", "role": "tool", "created_at": "", "content": [
        ["type": "tool_result", "tool_call_id": "call0", "output": "could not read", "is_error": true]]]]
    let visible = ToolVisibilityProjection().update(try messages(raw), sessionID: "s", running: ["call1"])
    let entries = ConversationTimelineEntry.make(visible.messages, isRunning: true)
    let calls = entries[0].messages.flatMap(\.content).compactMap { visible.tools[$0.toolCallId ?? ""] }
    precondition(calls.count == 2 && calls.allSatisfy(\.staysVisible))
    precondition(calls[0].status == .failed && calls[1].status == .running, "Grouping must not turn errors into success or hide running tools")

    func tool(_ index: Int, status: VisibleTool.Status = .returned) -> VisibleTool {
        VisibleTool(id: "call\(index)", name: "Read", input: .object(["path": .string("/private-project/File\(index).swift")]),
                    output: .string("PRIVATE_SOURCE_CONTENT"), status: status)
    }
    let available = Dictionary(uniqueKeysWithValues: (0..<50).map { ("call\($0)", tool($0)) })
    let thought: [String: Any] = ["id": "thought", "role": "assistant", "created_at": "", "content": [
        ["type": "thinking", "thinking": "PRIVATE_REASONING"]]]
    let context: [String: Any] = ["id": "context", "role": "user", "created_at": "", "content": [
        ["type": "text", "text": "<skill-loaded name='fixture'>PRIVATE_CONTEXT</skill-loaded>"]]]
    let interleaved = try messages([thought, read(10, name: "Bash"), thought.merging(["id": "thought2"]) { _, new in new },
        read(11, name: "TodoList"), read(0), read(1), read(2), context, read(3), read(4), read(5)])
    let stage = ConversationTimelineEntry.make(interleaved, isRunning: true)
    precondition(stage.count == 1 && stage[0].activity && !stage[0].isExploration)
    precondition(stage.flatMap(\.messages).flatMap(\.content) == interleaved.flatMap(\.content))
    let preview = ConversationTimelineEntry.make(Array(interleaved.prefix(1)), isRunning: true)
    precondition(stage[0].id == preview[0].id, "The live thought anchor survives folding into a process stage")
    var stageTools = available
    stageTools["call10"] = VisibleTool(id: "call10", name: "Bash", input: .object(["command": .string("git status")]), status: .returned)
    stageTools["call11"] = VisibleTool(id: "call11", name: "TodoList", input: nil, status: .returned)
    let stageBatch = ActivitySummaryBatch.latest(in: stage, tools: stageTools, isRunning: true, enabled: true)
    precondition(stageBatch?.completedCount == 8 && stageBatch?.shouldRequest(after: nil) == true,
                 "Two groups of three reads separated by thoughts/context/other tools share a summary threshold")
    let liveThought = try messages([thought.merging(["id": "live-thought"]) { _, new in new }])
    let withLiveThought = ConversationTimelineEntry.make(interleaved + liveThought, isRunning: true)
    precondition(withLiveThought.last?.presentation == .thinkingPreview)
    precondition(ActivitySummaryBatch.latest(in: withLiveThought, tools: stageTools, isRunning: true, enabled: true)?.closed == false,
                 "A live thought preview must not prematurely close the activity stage")
    let withBoundary = ConversationTimelineEntry.make(interleaved + (try messages([commentary])) + liveThought, isRunning: true)
    precondition(ActivitySummaryBatch.latest(in: withBoundary, tools: stageTools, isRunning: true, enabled: true)?.closed == true,
                 "Visible commentary closes the preceding stage even when a new thought follows")
    var incomplete = available
    for index in [3, 4, 5, 10] { incomplete["call\(index)"] = tool(index, status: .running) }
    precondition(ActivitySummaryBatch.latest(in: stage, tools: incomplete, isRunning: true, enabled: true) == nil,
                 "Thought/context records and unfinished tools never count as completed activity")
    let shell = VisibleTool(id: "shell", name: "Bash", input: .object([
        "command": .string("git worktree add /private-project/worktree && echo PRIVATE_SCRIPT")]), status: .failed)
    precondition(ToolPresentation.compactTarget(shell) == "git worktree")
    precondition(ToolPresentation.summaryTarget(shell) == "Bash", "Collapsed targets remain concise")
    precondition(ToolPresentation.recentTargets([tool(0), tool(0), tool(0)]) == "File0.swift")
    precondition(ToolPresentation.recentTargets([tool(0), shell, tool(1)]) == "File0.swift · File1.swift")
    let pathComponent = String(repeating: "p", count: 100)
    let longPath = "/private-project/\(pathComponent)/\(pathComponent)/\(pathComponent)/Summary.swift"
    let longCommand = "python3 -c " + String(repeating: "PRIVATE_SCRIPT", count: 30)
    let bounded = VisibleTool(id: "bounded", name: "Edit", input: .object([
        "path": .string(longPath), "command": .string(longCommand), "content": .string("PRIVATE_EDIT_CONTENT")]),
        output: .string("PRIVATE_SOURCE_CONTENT"), status: .returned)
    let privateBatch = ActivitySummaryBatch(groupID: "private", tools: [bounded], closed: true)
    let privateInput = String(decoding: try JSONEncoder().encode(privateBatch.records), as: UTF8.self)
    precondition(privateBatch.records[0].target.count == 240 && privateBatch.records[0].context?.count == 240)
    precondition(privateInput.contains("PRIVATE_SCRIPT"), "Bounded command context should inform the semantic model")
    precondition(!privateInput.contains("PRIVATE_SOURCE_CONTENT") && !privateInput.contains("PRIVATE_EDIT_CONTENT"),
                 "Tool output and edit bodies must stay out of summary requests")
    precondition(ActivitySummaryBatch.latest(in: long, tools: available, isRunning: true, enabled: false) == nil)
    let latest = ActivitySummaryBatch.latest(in: long, tools: available, isRunning: true, enabled: true)
    precondition(latest?.groupID == long[1].id && latest?.completedCount == 24 && latest?.closed == true,
                 "A short live tail must select the preceding eligible group in the same turn")
    let active = ActivitySummaryBatch.latest(in: grouped, tools: available, isRunning: true, enabled: true)
    precondition(active?.groupID == grouped[0].id && active?.closed == false)
    let ended = ActivitySummaryBatch.latest(in: grouped, tools: available, isRunning: false, enabled: true)
    precondition(ended?.closed == true)
    let nextTurn = ConversationTimelineEntry.make(sources + (try messages([boundary, read(12)])), isRunning: true)
    precondition(ActivitySummaryBatch.latest(in: nextTurn, tools: available, isRunning: true, enabled: true) == nil,
                 "Reverse lookup must not summarize the preceding user turn")
    let earlierBoundary: [String: Any] = ["id": "earlier", "role": "user", "created_at": "", "content": [
        ["type": "text", "text": "Earlier request"]]]
    let twoTurns = ConversationTimelineEntry.make(try messages(
        [earlierBoundary] + (0..<6).map { read($0) } + [boundary] + (6..<12).map { read($0) }), isRunning: true)
    let currentTurn = ActivitySummaryBatch.latest(in: twoTurns, tools: available, isRunning: true, enabled: true)
    precondition(currentTurn?.userRequest == "Check the UI too", "Only the current turn request should be sent")
    let longBoundary: [String: Any] = ["id": "long-request", "role": "user", "created_at": "", "content": [
        // The excerpt prefixes 480 raw chars before normalizing; a 6-char unit
        // like "word \n" divides 480 exactly, lands on a token boundary and
        // normalizes to 399 chars, so truncation to 400 never engages.
        ["type": "text", "text": String(repeating: "words \n", count: 120)]]]
    let longRequestTurn = ConversationTimelineEntry.make(try messages(
        [longBoundary] + (12..<18).map { read($0) }), isRunning: true)
    let requestExcerpt = ActivitySummaryBatch.latest(in: longRequestTurn, tools: available, isRunning: true, enabled: true)?.userRequest
    precondition(requestExcerpt?.count == 400 && requestExcerpt?.contains("\n") == false,
                 "The request excerpt must normalize whitespace and stay bounded")

    let batch = ActivitySummaryBatch(groupID: "group", tools: (0..<6).map { tool($0) }, closed: false,
                                     userRequest: "Improve summary intelligence")
    precondition(batch.shouldRequest(after: nil))
    precondition(!batch.shouldRequest(after: batch), "Repeated polling cannot incur additional cost")
    let short = ActivitySummaryBatch(groupID: "group", tools: (0..<5).map { tool($0) }, closed: true)
    precondition(!short.shouldRequest(after: nil))
    let oneMore = ActivitySummaryBatch(groupID: "group", tools: (0..<7).map { tool($0) }, closed: false)
    precondition(!oneMore.shouldRequest(after: batch))
    let closed = ActivitySummaryBatch(groupID: "group", tools: (0..<7).map { tool($0) }, closed: true)
    precondition(closed.shouldRequest(after: batch), "Closing a changed group gets one final update")
    let corrected = ActivitySummaryBatch(groupID: "group", tools: (0..<6).map { tool($0, status: $0 == 0 ? .failed : .returned) }, closed: false)
    precondition(corrected.shouldRequest(after: batch), "An authoritative status correction invalidates an old summary")
    let large = ActivitySummaryBatch(groupID: "large", tools: (0..<50).map { tool($0) }, closed: false)
    precondition(large.records.count == 12 && large.completedCount == 50)
    precondition(large.records.first?.id == "call38")

    let client = ActivitySummaryClient()
    var config = ActivitySummaryConfiguration()
    precondition(!config.enabled && config.baseURL.isEmpty && config.model.isEmpty)
    config.baseURL = "http://localhost:8000/v1/"; config.model = "summary-model"
    precondition(config.endpoint?.absoluteString == "http://localhost:8000/v1/chat/completions")
    do {
        _ = try client.request(configuration: config, apiKey: "", batch: batch, language: "zh-Hans")
        preconditionFailure("Disabled summaries must not produce a request")
    } catch ActivitySummaryError.configuration {}
    config.enabled = true; config.disableThinking = true
    let previous = ActivitySummaryResult(subject: "Activity summaries", phase: "exploring",
        summary: "Inspecting the existing summary flow.", evidenceIDs: ["call0"], shouldUpdate: true)
    let request = try client.request(configuration: config, apiKey: "test-token", batch: batch,
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
    precondition(prompt["current_request"] as? String == "Improve summary intelligence")
    precondition(prompt["group_closed"] as? Bool == false && activities.count == 6)
    precondition(previousPrompt["subject"] as? String == "Activity summaries"
                 && previousPrompt["phase"] as? String == "exploring"
                 && previousPrompt["evidence_ids"] as? [String] == ["call0"])
    let content = String(decoding: request.httpBody!, as: UTF8.self)
    precondition(content.contains("private-project/File0.swift"), "Bounded paths should give the model semantic context")
    precondition(!content.contains("PRIVATE_SOURCE_CONTENT") && !content.contains("test-token"))
    precondition(body["tools"] == nil && body["stream"] as? Bool == false && body["max_tokens"] as? Int == 180)
    precondition((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    config.disableThinking = false
    let standard = try client.request(configuration: config, apiKey: "", batch: batch, language: "en")
    let standardBody = try JSONSerialization.jsonObject(with: standard.httpBody!) as! [String: Any]
    precondition(standardBody["chat_template_kwargs"] == nil && standard.value(forHTTPHeaderField: "Authorization") == nil)
    config.baseURL = "http://user:password@localhost:8000/v1"
    precondition(!config.isValid, "Credentials must not be persisted inside the endpoint URL")

    func completion(_ text: String, finishReason: String = "stop") throws -> Data {
        let message: [String: Any] = ["content": text, "reasoning_content": "PRIVATE_REASONING"]
        let choice: [String: Any] = ["message": message, "finish_reason": finishReason]
        return try JSONSerialization.data(withJSONObject: ["choices": [choice]])
    }
    let response = try completion(" Read two files. ")
    let responseText = try ActivitySummaryClient.responseText(response)
    precondition(responseText == "Read two files.", "Session naming must retain plain-text response parsing")
    let semantic = try ActivitySummaryClient.responseResult(try completion(#"{"subject":"Activity summaries","phase":"editing","summary":"Reworked the summary protocol.","evidence_ids":["call0","call0","missing","call1","call2","call3"],"should_update":false}"#),
        evidenceIDs: Set(batch.records.map(\.id)))
    precondition(semantic.subject == "Activity summaries" && semantic.phase == "editing")
    precondition(semantic.summary == "Reworked the summary protocol." && semantic.shouldUpdate == false)
    precondition(semantic.evidenceIDs == ["call0", "call1", "call2"],
                 "Evidence must reference known records and remain bounded")
    let fenced = try ActivitySummaryClient.responseResult(try completion("""
        ```json
        {"subject":"Tests","phase":"validating","summary":"Validated the response parser.","evidence_ids":["call0"],"should_update":true}
        ```
        """), evidenceIDs: Set(["call0"]))
    precondition(fenced.phase == "validating" && fenced.evidenceIDs == ["call0"])
    let plain = try ActivitySummaryClient.responseResult(try completion(" Kept a compatible plain-text summary. "),
        evidenceIDs: [])
    precondition(plain.subject.isEmpty && plain.phase.isEmpty
                 && plain.summary == "Kept a compatible plain-text summary." && plain.shouldUpdate)
    do {
        _ = try ActivitySummaryClient.responseResult(try completion(#"{"summary": }"#), evidenceIDs: [])
        preconditionFailure("Malformed structured output must not replace a valid summary")
    } catch ActivitySummaryError.invalidResponse {}
    do {
        _ = try ActivitySummaryClient.responseText(try completion("Read", finishReason: "length"))
        preconditionFailure("Do not publish a sentence truncated by the token limit")
    } catch ActivitySummaryError.truncated {}
    print("PASS: activity grouping, bounded semantic context, structured summaries and Qwen non-thinking option")
}
