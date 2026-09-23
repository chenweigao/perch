import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var int: Int? { if case .number(let v) = self { return Int(v) }; return nil }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var display: String {
        if let string { return string }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: e.encode(self), as: UTF8.self)) ?? ""
    }
}

public enum KimiWire {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(Response<T>.self, from: data).value
    }
    public static func decodeEvent(from data: Data) throws -> KimiEvent {
        try decoder().decode(EventResponse.self, from: data).value
    }
    private struct EventResponse: Decodable {
        let value: KimiEvent
        private enum CodingKeys: String, CodingKey { case type, code, msg }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .type) == "ack",
               let code = try container.decodeIfPresent(Int.self, forKey: .code), code != 0 {
                throw WorkbenchError(try container.decodeIfPresent(String.self, forKey: .msg) ?? "Kimi 控制请求失败")
            }
            value = try KimiEvent(from: decoder)
        }
    }
    private struct Response<T: Decodable>: Decodable {
        let value: T
        private enum CodingKeys: String, CodingKey { case code, msg, data }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Errors need not have the success payload's shape.
            guard try container.decodeIfPresent(Int.self, forKey: .code) == 0 else {
                throw WorkbenchError(try container.decodeIfPresent(String.self, forKey: .msg) ?? "Kimi 返回了无法识别的响应")
            }
            value = try container.decode(T.self, forKey: .data)
        }
    }
}

public struct KimiPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let hasMore: Bool
}
public struct KimiSession: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let updatedAt: String
    public let busy: Bool
    public let mainTurnActive: Bool?
    public let pendingInteraction: String?
    public let archived: Bool?
    public let lastTurnReason: String?
    public let metadata: JSONValue
    public let agentConfig: JSONValue
    /// Present on the snapshot but zeroed on the list endpoint until a turn has run,
    /// which is why ContextBudget treats a zero limit as unknown.
    public let usage: JSONValue?
    public var displayTitle: String { title.isEmpty ? L("未命名会话") : title }
    public var cwd: String { metadata["cwd"].string ?? "" }
    public var model: String { agentConfig["model"].string ?? "" }
    /// Keys stay snake_case here: convertFromSnakeCase rewrites the properties of a
    /// decoded type, not the keys inside an untyped JSONValue.
    public var budget: ContextBudget? {
        ContextBudget(used: usage?["context_tokens"].int, limit: usage?["context_limit"].int)
    }
    public var status: String {
        if pendingInteraction == "approval" { return L("等待确认") }
        if pendingInteraction == "question" { return L("等待回答") }
        if busy { return L("运行中") }
        if lastTurnReason == "failed" { return L("出错") }
        return L("就绪")
    }
}
public struct KimiPart: Decodable, Equatable, Sendable {
    /// kimi-code delivers attachment metadata (for example the image compression
    /// note with the original's path) as its own `<system>…</system>` text part
    /// next to the typed prompt. It is harness metadata, not user prose.
    public var isRuntimeContext: Bool {
        guard type == "text", let text else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("<system-reminder>")
            || (value.hasPrefix("<notification ") && value.hasSuffix("</notification>"))
            || (value.hasPrefix("<skill-loaded ") && value.hasSuffix("</skill-loaded>"))
            || (value.hasPrefix("<system>") && value.hasSuffix("</system>"))
            || isToolSkillLoad(value)
    }
    /// A Skill tool result arrives as a one-line note ("Skill tool loaded
    /// instructions …") ahead of a `<skill-loaded trigger="model-tool">` block.
    /// The Skill call already shows in the activity record, so the whole
    /// injection folds as harness metadata — unlike a `trigger="user-slash"`
    /// activation, whose summary line anchors the user's turn.
    private func isToolSkillLoad(_ value: String) -> Bool {
        guard value.hasSuffix("</skill-loaded>"), let cut = value.firstIndex(of: "\n") else { return false }
        let block = value[cut...].drop(while: \.isWhitespace)
        guard block.hasPrefix("<skill-loaded ") else { return false }
        return block.prefix(while: { $0 != ">" }).contains(#"trigger="model-tool""#)
    }
    /// kimi-code prepends a one-line summary (for example "User activated the
    /// skill …") to the `<skill-loaded>` block. The line stays visible as the user
    /// bubble — folding the whole part would drop the turn boundary — while the
    /// skill body collapses instead of dumping the full SKILL.md into the chat.
    /// Tool-triggered loads never reach here; they fold as runtime context.
    public var skillContextSplit: (prefix: String, context: String)? {
        guard type == "text", let text, !isRuntimeContext else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix("</skill-loaded>"), let cut = value.firstIndex(of: "\n") else { return nil }
        let prefix = String(value[..<cut]).trimmingCharacters(in: .whitespaces)
        let context = String(value[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, context.hasPrefix("<skill-loaded ") else { return nil }
        return (prefix, context)
    }
    /// Text standing in for the part in excerpts and search: the visible prefix of
    /// a split skill context, nothing for folded runtime context, the body otherwise.
    public var visibleText: String? {
        if isRuntimeContext { return nil }
        if let split = skillContextSplit { return split.prefix }
        return text
    }
    public let type: String
    public let text: String?
    public let thinking: String?
    public let toolCallId: String?
    public let toolName: String?
    public let input: JSONValue?
    public let output: JSONValue?
    public let isError: Bool?
    public let source: JSONValue?
    public let fileId: String?
    public let name: String?
}
public struct KimiMessage: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let content: [KimiPart]
    public let createdAt: String
    public let metadata: JSONValue?
    /// Compaction summaries arrive as user-role messages; the origin marker is
    /// the only thing distinguishing them from user-typed prompts.
    public var isCompactionSummary: Bool {
        metadata?["origin"]["kind"].string == "compaction_summary"
    }
    /// Turns the person actually opened. Runtime-context injections and compaction
    /// summaries share the user role but never start or anchor one.
    public var isUserPrompt: Bool {
        role == "user" && !isCompactionSummary && !content.allSatisfy(\.isRuntimeContext)
    }
}
public struct KimiLiveTool: Decodable, Identifiable, Sendable {
    public let toolCallId: String
    public let name: String
    public let args: JSONValue?
    public var lastProgress: JSONValue?
    public var id: String { toolCallId }
}
public struct KimiInFlight: Decodable, Sendable {
    public let turnId: Int
    public var assistantText: String
    public var thinkingText: String
    public var runningTools: [KimiLiveTool]
    public let currentPromptId: String?
}
public struct KimiApproval: Decodable, Identifiable, Sendable {
    public let approvalId: String
    public let toolName: String
    public let action: String
    public let toolInputDisplay: JSONValue
    public let agentId: String
    public var id: String { approvalId }
}
public struct KimiQuestion: Decodable, Identifiable, Sendable {
    public let questionId: String
    public let questions: [Item]
    public var id: String { questionId }
    public struct Item: Decodable, Identifiable, Sendable {
        public let id: String
        public let question: String
        public let header: String?
        public let body: String?
        public let options: [Option]
        public let multiSelect: Bool?
        public let allowOther: Bool?
    }
    public struct Option: Decodable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let description: String?
    }
}
public struct KimiSnapshot: Decodable, Sendable {
    public let asOfSeq: Int
    public let epoch: String
    public let session: KimiSession
    public let messages: KimiPage<KimiMessage>
    public let inFlightTurn: KimiInFlight?
    public let pendingApprovals: [KimiApproval]
    public let pendingQuestions: [KimiQuestion]
    /// Absent on servers that predate the subagent roster.
    public let subagents: [KimiTask]?
}
public struct KimiEvent: Decodable, Sendable {
    public let type: String
    public let seq: Int?
    public let epoch: String?
    public let volatile: Bool?
    public let offset: Int?
    public let sessionId: String?
    /// Envelope time, the only clock a subagent lifecycle event carries.
    public let timestamp: String?
    public let payload: JSONValue
}

public struct KimiConversation: Sendable {
    public private(set) var snapshot: KimiSnapshot
    public private(set) var messages: [KimiMessage]
    public private(set) var live: KimiInFlight?
    public private(set) var lastSeq: Int
    public private(set) var hasOlder: Bool
    public var error: String?
    public var notice: String?
    /// Subagent roster and background tasks of this session. It survives a
    /// snapshot refresh, which replaces the roster but not the task list.
    public var tasks: KimiTaskBoard
    public init(_ snapshot: KimiSnapshot) {
        self.snapshot = snapshot; messages = snapshot.messages.items
        live = snapshot.inFlightTurn; lastSeq = snapshot.asOfSeq; hasOlder = snapshot.messages.hasMore
        tasks = KimiTaskBoard(subagents: snapshot.subagents ?? [])
    }
    public mutating func reconcile(_ snapshot: KimiSnapshot) {
        let previousNotice = notice
        let previousTurn = live?.turnId
        let previousError = error
        let old = messages
        let sameEpoch = self.snapshot.epoch == snapshot.epoch
        let hadLoadedOlder = hasOlder
        let previousTasks = tasks
        self = KimiConversation(snapshot)
        tasks.keepBackground(from: previousTasks)
        if snapshot.session.lastTurnReason == "failed" { error = previousError }
        if live != nil && live?.turnId == previousTurn { notice = previousNotice }
        if sameEpoch, let first = messages.first {
            let older = old.filter { $0.createdAt < first.createdAt }
            if !older.isEmpty { messages = older + messages; hasOlder = hadLoadedOlder }
        }
    }
    public mutating func prepend(_ page: KimiPage<KimiMessage>) {
        let existing = Set(messages.map(\.id))
        let older = page.items.filter { !existing.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        messages = older + messages; hasOlder = page.hasMore
    }
    /// Returns true when an authoritative snapshot is needed. Volatile deltas use JavaScript UTF-16 offsets.
    public mutating func apply(_ event: KimiEvent) -> Bool {
        guard event.sessionId == snapshot.session.id else { return false }
        if let epoch = event.epoch, epoch != snapshot.epoch { return true }
        // A snapshot may already include a later step in this same turn.
        if event.volatile == true, let seq = event.seq, seq < lastSeq { return false }
        if event.volatile != true, let seq = event.seq {
            guard seq > lastSeq else { return false }; lastSeq = seq
        }
        let p = event.payload
        // Subagent lifecycle only moves the local roster; the snapshot stays
        // authoritative and is not re-read for it.
        tasks.apply(event)
        if let agent = p["agentId"].string, agent != "main" { return false }
        switch event.type {
        case "assistant.delta", "thinking.delta":
            guard var live, live.turnId == p["turnId"].int, let delta = p["delta"].string, let offset = event.offset else { return true }
            var text = event.type == "assistant.delta" ? live.assistantText : live.thinkingText
            let length = text.utf16.count
            guard offset <= length else { return true }
            let overlap = length - offset
            if overlap < delta.utf16.count { text += String(decoding: delta.utf16.dropFirst(overlap), as: UTF16.self) }
            if event.type == "assistant.delta" { live.assistantText = text } else { live.thinkingText = text }
            self.live = live; notice = nil
            return false
        case "tool.progress":
            if let id = p["toolCallId"].string, let index = live?.runningTools.firstIndex(where: { $0.id == id }) {
                live?.runningTools[index].lastProgress = p["update"]
            }
            return false
        case "turn.step.retrying":
            notice = "服务端将在 \((p["delayMs"].int ?? 0) / 1000) 秒后重试：" + (p["errorMessage"].string ?? "模型请求失败")
            return false
        case "error": error = p["error"]["message"].string ?? p["message"].string; return true
        case "turn.started", "turn.ended", "turn.step.started", "turn.step.completed", "turn.step.interrupted", "tool.call.started", "tool.result",
             "compaction.started", "compaction.blocked", "compaction.cancelled", "compaction.completed", "goal.updated",
             "event.approval.requested", "event.approval.resolved", "event.question.requested", "event.question.answered", "event.question.dismissed",
             "prompt.submitted", "prompt.queued", "prompt.steered", "turn.steer", "prompt.started", "prompt.completed", "prompt.aborted": return true
        default: return false
        }
    }
}
