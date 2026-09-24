import Foundation
import WorkbenchCore

func checkTaskRecaps() throws {
    func decode(_ rows: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self,
                                      from: JSONSerialization.data(withJSONObject: rows))
    }
    func user(_ index: Int) -> [String: Any] {
        ["id": "u\(index)", "role": "user", "created_at": "\(index)",
         "content": [["type": "text", "text": "Request \(index)"]]]
    }
    func answer(_ index: Int) -> [String: Any] {
        ["id": "a\(index)", "role": "assistant", "created_at": "\(index)",
         "content": [["type": "text", "text": "Answer \(index)"]]]
    }
    func completion(_ text: String, finishReason: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": text], "finish_reason": finishReason]]
        ])
    }

    let longHistory = try decode((0..<14).flatMap { [user($0), answer($0)] })
    let bounded = TaskRecapInput.make(messages: longHistory)!
    precondition(bounded.turns.count == 12 && bounded.omittedTurnCount == 2)
    precondition(bounded.turns.first?.request == "Request 0")
    precondition(bounded.turns[1].request == "Request 3" && bounded.turns.last?.response == "Answer 13")

    let privateOutput = String(repeating: "PRIVATE_TOOL_OUTPUT", count: 80) + "FINAL_OUTPUT"
    let sensitiveRows: [[String: Any]] = [
        ["id": "u", "role": "user", "created_at": "1", "content": [
            ["type": "text", "text": "Implement a recap"],
            ["type": "text", "text": "<system-reminder>PRIVATE_RUNTIME_CONTEXT</system-reminder>"]
        ]],
        ["id": "compaction", "role": "user", "created_at": "2",
         "metadata": ["origin": ["kind": "compaction_summary"]],
         "content": [["type": "text", "text": "PRIVATE_COMPACTION_SUMMARY"]]],
        ["id": "thinking", "role": "assistant", "created_at": "3",
         "content": [["type": "thinking", "thinking": "PRIVATE_REASONING"]]],
        ["id": "read-call", "role": "assistant", "created_at": "4", "content": [[
            "type": "tool_use", "tool_call_id": "read", "tool_name": "Read",
            "input": ["path": "/fixture/private/project/Secrets.swift"]
        ]]],
        ["id": "read-result", "role": "tool", "created_at": "5", "content": [[
            "type": "tool_result", "tool_call_id": "read", "output": "PRIVATE_READ_OUTPUT", "is_error": false
        ]]],
        ["id": "todo-call", "role": "assistant", "created_at": "6", "content": [[
            "type": "tool_use", "tool_call_id": "todo", "tool_name": "TodoList", "input": ["todos": [
                ["title": "Add Recap UI", "status": "done"],
                ["title": "Validate privacy boundary", "status": "in_progress"]
            ]]
        ]]],
        ["id": "todo-result", "role": "tool", "created_at": "7", "content": [[
            "type": "tool_result", "tool_call_id": "todo", "output": "PRIVATE_TODO_OUTPUT", "is_error": false
        ]]],
        ["id": "edit-call", "role": "assistant", "created_at": "8", "content": [[
            "type": "tool_use", "tool_call_id": "edit", "tool_name": "Edit", "input": [
                "path": "/fixture/private/project/Sources/TaskRecap.swift",
                "old_string": "PRIVATE_OLD_EDIT_BODY", "new_string": "PRIVATE_NEW_EDIT_BODY"
            ]
        ]]],
        ["id": "edit-result", "role": "tool", "created_at": "9", "content": [[
            "type": "tool_result", "tool_call_id": "edit", "output": [
                "exit_code": 0, "output": privateOutput
            ], "is_error": false
        ]]],
        ["id": "test-call", "role": "assistant", "created_at": "10", "content": [[
            "type": "tool_use", "tool_call_id": "test", "tool_name": "Bash", "input": [
                "command": "swift test --filter PRIVATE_COMMAND_ARGUMENT"
            ]
        ]]],
        ["id": "test-result", "role": "tool", "created_at": "11", "content": [[
            "type": "tool_result", "tool_call_id": "test", "output": [
                "exit_code": 0, "output": privateOutput
            ], "is_error": false
        ]]],
        ["id": "answer", "role": "assistant", "created_at": "12", "content": [[
            "type": "text", "text": "Implemented Recap and validated the fixture."
        ]]]
    ]
    let sensitiveMessages = try decode(sensitiveRows)
    let privateInput = TaskRecapInput.make(messages: sensitiveMessages)!
    let privateJSON = String(decoding: try JSONEncoder().encode(privateInput), as: UTF8.self)
    precondition(privateInput.turns.count == 1 && privateInput.steps.map(\.title) == ["Add Recap UI", "Validate privacy boundary"])
    precondition(privateInput.evidence.map(\.tool) == ["Edit", "Bash"], "Reads and TodoList must not become recap evidence")
    precondition(privateInput.evidence[0].target == "private/project/Sources/TaskRecap.swift")
    precondition(privateInput.evidence.allSatisfy { $0.outputExcerpt == nil })
    for secret in ["PRIVATE_RUNTIME_CONTEXT", "PRIVATE_COMPACTION_SUMMARY", "PRIVATE_REASONING",
                   "PRIVATE_OLD_EDIT_BODY", "PRIVATE_NEW_EDIT_BODY", "PRIVATE_COMMAND_ARGUMENT",
                   "PRIVATE_TOOL_OUTPUT", "PRIVATE_READ_OUTPUT", "PRIVATE_TODO_OUTPUT", "/fixture"] {
        precondition(!privateJSON.contains(secret), "Recap input leaked \(secret)")
    }
    let optedIn = TaskRecapInput.make(messages: sensitiveMessages, includeToolOutput: true)!
    precondition(optedIn.evidence.compactMap(\.outputExcerpt).count == 2)
    precondition(optedIn.evidence.compactMap(\.outputExcerpt).allSatisfy { $0.count == 600 })
    precondition(optedIn.evidence.compactMap(\.outputExcerpt).allSatisfy { $0.hasSuffix("FINAL_OUTPUT") })

    var config = ActivitySummaryConfiguration()
    config.enabled = true
    config.baseURL = "http://localhost:8000/v1"
    config.model = "recap-model"
    config.disableThinking = true
    let client = TaskRecapClient()
    let request = try client.request(configuration: config, apiKey: "recap-secret",
                                     input: privateInput, language: "zh-Hans")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let bodyText = String(decoding: request.httpBody!, as: UTF8.self)
    precondition(body["tools"] == nil && body["stream"] as? Bool == false && body["max_tokens"] as? Int == 1_200)
    precondition((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer recap-secret")
    precondition(!bodyText.contains("recap-secret") && !bodyText.contains("PRIVATE_RUNTIME_CONTEXT"))
    config.disableThinking = false
    let standard = try client.request(configuration: config, apiKey: "", input: privateInput, language: "en")
    let standardBody = try JSONSerialization.jsonObject(with: standard.httpBody!) as! [String: Any]
    precondition(standardBody["chat_template_kwargs"] == nil && standard.value(forHTTPHeaderField: "Authorization") == nil)

    let result = try TaskRecapClient.responseResult(try completion("""
    ```json
    {"outcome":"Completed the recap feature.","changes":["Added UI"],"validation":["Checks passed"],"remaining":[],"next_steps":["Review"]}
    ```
    """))
    precondition(result.outcome == "Completed the recap feature." && result.changes == ["Added UI"])
    do {
        _ = try TaskRecapClient.responseResult(try completion(
            #"{"outcome":"","changes":[],"validation":[],"remaining":[],"next_steps":[]}"#))
        preconditionFailure("An empty outcome must be rejected")
    } catch ActivitySummaryError.invalidResponse {}
    do {
        _ = try TaskRecapClient.responseResult(try completion(#"{"outcome": }"#))
        preconditionFailure("Malformed recap JSON must be rejected")
    } catch ActivitySummaryError.invalidResponse {}
    do {
        _ = try TaskRecapClient.responseResult(try completion(
            #"{"outcome":"Truncated","changes":[],"validation":[],"remaining":[],"next_steps":[]}"#,
            finishReason: "length"))
        preconditionFailure("A truncated recap must not be published")
    } catch ActivitySummaryError.truncated {}

    var cache = TaskRecapCache()
    for index in 0..<130 {
        cache.store(TaskRecapResult(outcome: "Result \(index)"), for: "key-\(index)",
                    at: Date(timeIntervalSince1970: TimeInterval(index)))
    }
    precondition(cache.entries.count == 128 && cache.result(for: "key-0") == nil)
    precondition(cache.result(for: "key-129")?.outcome == "Result 129")
    cache.store(TaskRecapResult(outcome: "Updated"), for: "key-129")
    precondition(cache.entries.count == 128 && cache.result(for: "key-129")?.outcome == "Updated")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("perch-recaps-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = TaskRecapFile(url: folder.appendingPathComponent("task-recaps.json"))
    try file.flush(cache)
    let loadedCache = try file.load()
    precondition(loadedCache == cache)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
    precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    let revision = TaskRecapInput.revision(in: sensitiveMessages)
    precondition(revision != nil && revision == TaskRecapInput.revision(in: sensitiveMessages))
    var changedRows = sensitiveRows
    changedRows[changedRows.count - 1] = ["id": "answer", "role": "assistant", "created_at": "12",
        "content": [["type": "text", "text": "A revised final answer."]]]
    let changedAnswerMessages = try decode(changedRows)
    precondition(TaskRecapInput.revision(in: changedAnswerMessages) != revision)
    changedRows = sensitiveRows
    changedRows[8] = ["id": "edit-result", "role": "tool", "created_at": "9", "content": [[
        "type": "tool_result", "tool_call_id": "edit", "output": ["exit_code": 1, "output": "changed"],
        "is_error": true
    ]]]
    let changedResultMessages = try decode(changedRows)
    precondition(TaskRecapInput.revision(in: changedResultMessages) != revision)

    print("PASS: bounded task Recap input, privacy boundary, request/response contract, stable cache")
}
