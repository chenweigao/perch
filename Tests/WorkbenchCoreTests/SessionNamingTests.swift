import Foundation
import WorkbenchCore

func checkSessionNaming() throws {
    func messages(_ value: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: value))
    }
    func user(_ id: String, _ text: String) -> [String: Any] {
        ["id": id, "role": "user", "created_at": "", "content": [["type": "text", "text": text]]]
    }

    // Endpoint preferences saved before the naming toggle existed must still decode.
    let legacy = Data(#"{"enabled":true,"baseURL":"http://localhost:8000/v1","model":"summary-model","disableThinking":true}"#.utf8)
    let migrated = try JSONDecoder().decode(ActivitySummaryConfiguration.self, from: legacy)
    precondition(migrated.enabled && migrated.disableThinking && !migrated.nameSessions && migrated.isValid)
    var toggled = migrated
    toggled.nameSessions = true
    let roundTrip = try JSONDecoder().decode(ActivitySummaryConfiguration.self, from: JSONEncoder().encode(toggled))
    precondition(roundTrip.nameSessions)

    let contextOnly: [String: Any] = ["id": "context", "role": "user", "created_at": "", "content": [
        ["type": "text", "text": "<system-reminder>PRIVATE_CONTEXT</system-reminder>"]]]
    let assistant: [String: Any] = ["id": "reply", "role": "assistant", "created_at": "", "content": [["type": "text", "text": "Working on it"]]]
    let prompt = "  Fix the login redirect loop in the mobile app  "
    let conversation = try messages([contextOnly, user("first", prompt), assistant])
    precondition(SessionNaming.excerpt(from: conversation) == prompt.trimmingCharacters(in: .whitespacesAndNewlines))
    precondition(SessionNaming.excerpt(from: conversation, hasOlder: true) == nil,
                 "A partial history must never rename a session using a later user message")
    let contextConversation = try messages([contextOnly, assistant])
    precondition(SessionNaming.excerpt(from: contextConversation) == nil,
                 "Assistant text and runtime context never become a naming candidate")
    let longPrompt = String(repeating: "长", count: 500)
    let longConversation = try messages([user("long", longPrompt)])
    precondition(SessionNaming.excerpt(from: longConversation)?.count == 400)

    precondition(SessionNaming.isPlaceholder("", kind: .kimi, firstUserText: prompt))
    precondition(SessionNaming.isPlaceholder("  ", kind: .kimi, firstUserText: prompt))
    precondition(!SessionNaming.isPlaceholder("登录问题排查", kind: .kimi, firstUserText: prompt))
    precondition(!SessionNaming.isPlaceholder("", kind: .terminal, firstUserText: prompt),
                 "Terminal titles come from the shell and are never named")
    for kind in [SessionKind.omp, .qoder, .dsh, .codex, .claude] {
        precondition(SessionNaming.isPlaceholder("", kind: kind, firstUserText: prompt))
        precondition(SessionNaming.isPlaceholder("新对话", kind: kind, firstUserText: prompt))
        let bridgeTitle = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        precondition(SessionNaming.isPlaceholder(bridgeTitle, kind: kind, firstUserText: bridgeTitle + " tail"),
                     "The bridge's text[:60] default reads as raw input, not a name")
        precondition(!SessionNaming.isPlaceholder("A deliberate session name", kind: kind, firstUserText: prompt))
        precondition(!SessionNaming.isPlaceholder(String(repeating: "x", count: 61), kind: kind,
                                                  firstUserText: String(repeating: "x", count: 200)),
                     "A user title longer than the bridge rule must not be mistaken for it")
    }

    precondition(SessionNaming.sanitize(" \"Fix login bug\"\nignored second line ") == "Fix login bug")
    precondition(SessionNaming.sanitize("「排查登录重定向」") == "排查登录重定向")
    precondition(SessionNaming.sanitize("\"\"") == "")
    precondition(SessionNaming.sanitize("   ") == "")
    precondition(SessionNaming.sanitize(String(repeating: "a", count: 80)).count == 40)

    let client = SessionNamingClient()
    var config = ActivitySummaryConfiguration()
    config.baseURL = "http://localhost:8000/v1/"; config.model = "naming-model"
    let excerpt = "Fix the login redirect loop"
    do {
        _ = try client.request(configuration: config, apiKey: "", excerpt: excerpt, language: "zh-Hans")
        preconditionFailure("Naming without the master switch must not produce a request")
    } catch ActivitySummaryError.configuration {}
    config.enabled = true
    do {
        _ = try client.request(configuration: config, apiKey: "", excerpt: excerpt, language: "zh-Hans")
        preconditionFailure("Naming without its own toggle must not produce a request")
    } catch ActivitySummaryError.configuration {}
    config.nameSessions = true; config.disableThinking = true
    let request = try client.request(configuration: config, apiKey: "test-token", excerpt: excerpt, language: "zh-Hans")
    precondition(request.url?.absoluteString == "http://localhost:8000/v1/chat/completions")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let content = String(decoding: request.httpBody!, as: UTF8.self)
    precondition(!content.contains("test-token") && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    precondition(body["tools"] == nil && body["stream"] as? Bool == false && body["max_tokens"] as? Int == 160)
    precondition(body["temperature"] as? Double == 0)
    precondition((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
    let messagesBody = body["messages"] as? [[String: String]]
    precondition(messagesBody?.count == 2 && messagesBody?.last?["content"] == excerpt,
                 "Only the bounded first-message excerpt is sent")
    config.disableThinking = false
    let plain = try JSONSerialization.jsonObject(with: client.request(configuration: config, apiKey: "", excerpt: excerpt, language: "en").httpBody!) as! [String: Any]
    precondition(plain["chat_template_kwargs"] == nil)

    let response = Data(#"{"choices":[{"message":{"content":" 《修复登录跳转》\n"},"finish_reason":"stop"}]}"#.utf8)
    let responseText = try ActivitySummaryClient.responseText(response)
    precondition(SessionNaming.sanitize(responseText) == "修复登录跳转")
    let truncated = Data(#"{"choices":[{"message":{"content":"Fix log"},"finish_reason":"length"}]}"#.utf8)
    do {
        _ = SessionNaming.sanitize(try ActivitySummaryClient.responseText(truncated))
        preconditionFailure("A truncated title must be discarded")
    } catch ActivitySummaryError.truncated {}

    // The persisted record keeps automation away from user-touched titles.
    var workspace = LocalWorkspace()
    let reference = SessionReference(hostID: UUID(), terminalID: "s1", kind: .omp)
    workspace.rename(reference, title: "生成的名字")
    workspace.autoNamedSessions.insert(reference.id)
    workspace.rename(reference, title: "")
    precondition(workspace.autoNamedSessions.contains(reference.id),
                 "Clearing a title must not re-arm automation for that session")
    workspace.removeSession(reference)
    precondition(!workspace.autoNamedSessions.contains(reference.id))

    print("PASS: session naming config migration, placeholder detection, excerpt bounds, request shape, sanitization")
}
