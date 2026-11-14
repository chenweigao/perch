import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
    /// A transcript delivery carries a typed operation batch in its payload
    /// instead of a session event, so it is decoded separately from the same bytes.
    public static func decodeTranscript<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(TranscriptEnvelope<T>.self, from: data).payload
    }
    private struct TranscriptEnvelope<T: Decodable>: Decodable {
        let payload: T
    }
    private struct EventResponse: Decodable {
        let value: KimiEvent
        private enum CodingKeys: String, CodingKey { case type, code, msg }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .type) == "ack",
               let code = try container.decodeIfPresent(Int.self, forKey: .code), code != 0 {
                throw WorkbenchError(try container.decodeIfPresent(String.self, forKey: .msg) ?? L("Kimi 控制请求失败"))
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
                throw WorkbenchError(try container.decodeIfPresent(String.self, forKey: .msg) ?? L("Kimi 返回了无法识别的响应"))
            }
            value = try container.decode(T.self, forKey: .data)
        }
    }
}

/// `GET /api/v1/meta`. The version belongs to the process answering this
/// connection, which is not necessarily the package installed on the host: a
/// `kimi web` service keeps serving the code it started with after an upgrade.
/// Fields stay optional so an older or trimmed service still connects.
public struct KimiServerMeta: Decodable, Equatable, Sendable {
    public let serverVersion: String?
    public let serverId: String?
    public let startedAt: String?
    public var runtime: RunningRuntime { RunningRuntime(version: serverVersion, startedAt: startedAt) }
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
    /// `busy` also includes background tasks such as preview servers. Only the
    /// main turn controls reply presentation, the composer, turn timing and the
    /// running classification in the sidebar, header and archive flow.
    public var isTurnRunning: Bool { mainTurnActive ?? busy }
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
        if SessionTurn(kimi: self).pending { return L("等你处理") }
        if isTurnRunning { return L("运行中") }
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
        if source?["kind"].string == "runtime_context" { return true }
        // Every marker below starts with "<" or "B" or ends with ">". Projections
        // ask this of every text part on each update; most prose is neither, and
        // is answered without copying the trimmed text.
        guard let edges = Self.trimmedEdges(text), edges.first == "<" || edges.first == "B" || edges.last == ">" else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The prefix also recognizes historical Claude snapshots whose bridge
        // discarded the SDK synthetic marker. Keep them folded on reopen.
        return (value.hasPrefix("Base directory for this skill: ") && value.contains("\n"))
            || value.hasPrefix("<system-reminder>")
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
    /// The first and last scalars `trimmingCharacters(in: .whitespacesAndNewlines)` keeps.
    private static func trimmedEdges(_ text: String) -> (first: Unicode.Scalar, last: Unicode.Scalar)? {
        let scalars = text.unicodeScalars
        guard let first = scalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
              let last = scalars.last(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        return (first, last)
    }
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
        guard type == "text", let text, !isRuntimeContext, Self.trimmedEdges(text)?.last == ">" else { return nil }
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

    func appendingText(_ more: String) -> KimiPart {
        KimiPart(type: type, text: (text ?? "") + more, thinking: thinking, toolCallId: toolCallId,
                 toolName: toolName, input: input, output: output, isError: isError,
                 source: source, fileId: fileId, name: name)
    }

    func appendingThinking(_ more: String) -> KimiPart {
        KimiPart(type: type, text: text, thinking: (thinking ?? "") + more, toolCallId: toolCallId,
                 toolName: toolName, input: input, output: output, isError: isError,
                 source: source, fileId: fileId, name: name)
    }
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
    /// Turns the person actually opened. Claude tool results, runtime-context
    /// injections and compaction summaries also use the user role, but never
    /// start or anchor a turn.
    public var isUserPrompt: Bool {
        role == "user" && !isCompactionSummary && !content.allSatisfy { $0.isRuntimeContext || $0.type == "tool_result" }
    }
    func coalescingAdjacentAssistantParts() -> KimiMessage {
        guard role == "assistant", content.count > 1 else { return self }
        var merged: [KimiPart] = []
        merged.reserveCapacity(content.count)
        for part in content {
            if part.source == nil, !part.isRuntimeContext,
               let previous = merged.last, previous.source == nil, !previous.isRuntimeContext {
                if part.type == "text", previous.type == "text" {
                    merged[merged.count - 1] = previous.appendingText(part.text ?? "")
                    continue
                }
                if part.type == "thinking", previous.type == "thinking" {
                    merged[merged.count - 1] = previous.appendingThinking(part.thinking ?? "")
                    continue
                }
            }
            merged.append(part)
        }
        return merged.count == content.count ? self : KimiMessage(
            id: id, role: role, content: merged, createdAt: createdAt, metadata: metadata)
    }
}
/// A reused projection or search must know that the earlier messages of a window
/// did not change, and asks on every streamed token. Walking them through an
/// iterator copies each element, retaining and releasing its strings and parts;
/// a copy of an unchanged message is instead compared as the bytes it was copied
/// from, because bitwise equal storage is value equal. A byte difference only
/// means the values still need the real comparison.
extension KimiMessage {
    static func sameWindow(_ lhs: ArraySlice<KimiMessage>, _ rhs: ArraySlice<KimiMessage>) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return lhs.count == rhs.count }
        let bitwise = lhs.withContiguousStorageIfAvailable { left in
            rhs.withContiguousStorageIfAvailable { right -> Bool? in
                guard left.count == right.count,
                      let first = left.baseAddress, let second = right.baseAddress else { return nil }
                let size = MemoryLayout<KimiMessage>.size, stride = MemoryLayout<KimiMessage>.stride
                let lhsBytes = UnsafeRawPointer(first), rhsBytes = UnsafeRawPointer(second)
                // Without trailing padding one comparison covers the window.
                if size == stride { return memcmp(lhsBytes, rhsBytes, left.count * stride) == 0 }
                for index in 0..<left.count
                where !sameBytes(lhsBytes + index * stride, rhsBytes + index * stride, count: size) { return false }
                return true
            } ?? nil
        } ?? nil
        if bitwise == true { return true }
        // Messages rebuilt from the same wire data are equal by value with
        // different payloads. The indexed walk keeps them from being copied.
        let valued = lhs.withContiguousStorageIfAvailable { left in
            rhs.withContiguousStorageIfAvailable { right -> Bool? in
                guard left.count == right.count else { return nil }
                for index in 0..<left.count where left[index] != right[index] { return false }
                return true
            } ?? nil
        } ?? nil
        return valued ?? lhs.elementsEqual(rhs)
    }

    /// Only trailing padding can separate two copies of one value, so the bytes
    /// a value occupies decide.
    private static func sameBytes(_ lhs: UnsafeRawPointer, _ rhs: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset + 8 <= count {
            if lhs.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                != rhs.loadUnaligned(fromByteOffset: offset, as: UInt64.self) { return false }
            offset += 8
        }
        while offset < count {
            if lhs.load(fromByteOffset: offset, as: UInt8.self) != rhs.load(fromByteOffset: offset, as: UInt8.self) { return false }
            offset += 1
        }
        return true
    }

    /// The identity a find-bar cache reuses rendered search results under.
    /// Value equality alone is weaker than search equivalence: JSON rendering
    /// keeps a number's zero sign (`display` renders -0.0 as "-0" and 0.0 as
    /// "0", while `==` calls them equal) and strings keep their UTF-8 encoding
    /// (NFC and NFD compare equal but are different literal and regex bytes).
    /// The bitwise tier of `sameWindow` proves rendered identity directly; a
    /// value-equal pair additionally has to prove every field that reaches the
    /// rendered sources is byte-identical.
    static func sameSearchableWindow(_ lhs: ArraySlice<KimiMessage>, _ rhs: ArraySlice<KimiMessage>) -> Bool {
        sameWindowBits(lhs, rhs) || (sameWindow(lhs, rhs) && sameRenderedMessages(lhs, rhs))
    }

    /// The bitwise tier of `sameWindow` alone: true only when both slices lend
    /// contiguous storage whose value bytes are identical.
    static func sameWindowBits(_ lhs: ArraySlice<KimiMessage>, _ rhs: ArraySlice<KimiMessage>) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        let bitwise = lhs.withContiguousStorageIfAvailable { left in
            rhs.withContiguousStorageIfAvailable { right -> Bool? in
                guard left.count == right.count,
                      let first = left.baseAddress, let second = right.baseAddress else { return nil }
                let size = MemoryLayout<KimiMessage>.size, stride = MemoryLayout<KimiMessage>.stride
                let lhsBytes = UnsafeRawPointer(first), rhsBytes = UnsafeRawPointer(second)
                // Without trailing padding one comparison covers the window.
                if size == stride { return memcmp(lhsBytes, rhsBytes, left.count * stride) == 0 }
                for index in 0..<left.count
                where !sameBytes(lhsBytes + index * stride, rhsBytes + index * stride, count: size) { return false }
                return true
            } ?? nil
        } ?? nil
        return bitwise ?? false
    }

    /// Byte identity of every field that reaches the find bar's rendered entry
    /// text (`ConversationSearch.sources`: type, text via visibleText, toolName,
    /// name, input, output). Fields that only feed value-based decisions
    /// (thinking, source, metadata, isError, fileId, id, role, createdAt) are
    /// pinned by `sameWindow`'s value tier, and canonical-equality differences
    /// in them cannot change rendered bytes. Extend this comparison together
    /// with `sources(of:)` when it renders a new field.
    static func sameRenderedMessages(_ lhs: ArraySlice<KimiMessage>, _ rhs: ArraySlice<KimiMessage>) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let bitwise = lhs.withContiguousStorageIfAvailable { left in
            rhs.withContiguousStorageIfAvailable { right -> Bool? in
                guard left.count == right.count,
                      let first = left.baseAddress, let second = right.baseAddress else { return nil }
                for index in 0..<left.count where !sameRenderedMessage(first[index], second[index]) { return false }
                return true
            } ?? nil
        } ?? nil
        if let bitwise { return bitwise }
        var left = lhs.startIndex, right = rhs.startIndex
        while left != lhs.endIndex {
            if !sameRenderedMessage(lhs[left], rhs[right]) { return false }
            left = lhs.index(after: left)
            right = rhs.index(after: right)
        }
        return true
    }

    private static func sameRenderedMessage(_ lhs: KimiMessage, _ rhs: KimiMessage) -> Bool {
        guard lhs.content.count == rhs.content.count else { return false }
        for (left, right) in zip(lhs.content, rhs.content) where !sameRenderedPart(left, right) { return false }
        return true
    }

    private static func sameRenderedPart(_ lhs: KimiPart, _ rhs: KimiPart) -> Bool {
        sameRenderedUTF8(lhs.type, rhs.type)
            && sameRenderedOptionalUTF8(lhs.text, rhs.text)
            && sameRenderedOptionalUTF8(lhs.toolName, rhs.toolName)
            && sameRenderedOptionalUTF8(lhs.name, rhs.name)
            && sameRenderedPayload(lhs.input, rhs.input)
            && sameRenderedPayload(lhs.output, rhs.output)
    }
}

/// Byte identity of strings that reach a rendered search source: copy-on-write
/// storage shared between the two copies compares at pointer speed, distinct
/// storage compares by content, and foreign storage falls back to a code-unit
/// walk. Canonical equality is deliberately not enough here.
func sameRenderedUTF8(_ lhs: String, _ rhs: String) -> Bool {
    guard lhs.utf8.count == rhs.utf8.count else { return false }
    let bitwise = lhs.utf8.withContiguousStorageIfAvailable { left in
        rhs.utf8.withContiguousStorageIfAvailable { right -> Bool? in
            guard let a = left.baseAddress, let b = right.baseAddress else { return nil }
            return a == b || memcmp(a, b, left.count) == 0
        } ?? nil
    } ?? nil
    return bitwise ?? lhs.utf8.elementsEqual(rhs.utf8)
}

func sameRenderedOptionalUTF8(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (let a?, let b?): return sameRenderedUTF8(a, b)
    default: return false
    }
}

func sameRenderedPayload(_ lhs: JSONValue?, _ rhs: JSONValue?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (let a?, let b?): return a.rendersIdentically(to: b)
    default: return false
    }
}

extension JSONValue {
    /// Byte identity of `display`'s output instead of value equality: JSON
    /// rendering keeps a number's zero sign and a string's UTF-8 encoding,
    /// both of which `==` folds away. `display` sorts object keys, so dict
    /// insertion order cannot change the rendering — but the keys' own
    /// encodings can, and are compared byte-wise.
    fileprivate func rendersIdentically(to other: JSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a.bitPattern == b.bitPattern
        case (.string(let a), .string(let b)): return sameRenderedUTF8(a, b)
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for (left, right) in zip(a, b) where !left.rendersIdentically(to: right) { return false }
            return true
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (key, value) in a {
                guard let match = b.first(where: { $0.key == key }),
                      sameRenderedUTF8(key, match.key),
                      value.rendersIdentically(to: match.value) else { return false }
            }
            return true
        default: return false
        }
    }
}

public struct KimiLiveTool: Decodable, Identifiable, Equatable, Sendable {
    public let toolCallId: String
    public let name: String
    public let args: JSONValue?
    public var lastProgress: JSONValue?
    public var id: String { toolCallId }
}
public struct KimiInFlight: Decodable, Sendable {
    public let turnId: Int
    public private(set) var assistantText: String
    public private(set) var thinkingText: String
    public var runningTools: [KimiLiveTool]
    public let currentPromptId: String?
    // Counting UTF-16 walks the whole text; a long stream must not pay it per delta.
    private var assistantUTF16Count: Int?
    private var thinkingUTF16Count: Int?

    public var assistantUTF16Length: Int { assistantUTF16Count ?? assistantText.utf16.count }
    public var thinkingUTF16Length: Int { thinkingUTF16Count ?? thinkingText.utf16.count }

    /// Applies a volatile delta at its UTF-16 offset. Returns false when the
    /// offset lies beyond the current text and an authoritative snapshot is needed.
    public mutating func appendDelta(_ delta: String, offset: Int, thinking: Bool) -> Bool {
        let length = thinking ? thinkingUTF16Length : assistantUTF16Length
        guard offset <= length else { return false }
        let overlap = length - offset
        let deltaLength = delta.utf16.count
        if overlap < deltaLength {
            let appended = String(decoding: delta.utf16.dropFirst(overlap), as: UTF16.self)
            if thinking { thinkingText += appended; thinkingUTF16Count = offset + deltaLength }
            else { assistantText += appended; assistantUTF16Count = offset + deltaLength }
        } else if thinking { thinkingUTF16Count = length }
        else { assistantUTF16Count = length }
        return true
    }
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
    /// Several pages at once, as successive `prepend(_:)` calls would leave them.
    /// Messages that arrived in the window since the batch began are not repeated.
    public mutating func prepend(_ batch: KimiHistoryBatch) {
        guard !batch.pages.isEmpty else { return }
        let existing = Set(messages.map(\.id))
        var older: [KimiMessage] = []
        for page in batch.pages.reversed() { older.append(contentsOf: page.filter { !existing.contains($0.id) }) }
        messages = older + messages; hasOlder = batch.hasMore
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
            guard live.appendDelta(delta, offset: offset, thinking: event.type == "thinking.delta") else { return true }
            self.live = live; notice = nil
            return false
        case "tool.progress":
            if let id = p["toolCallId"].string, let index = live?.runningTools.firstIndex(where: { $0.id == id }) {
                live?.runningTools[index].lastProgress = p["update"]
            }
            return false
        case "turn.step.retrying":
            let seconds = (p["delayMs"].int ?? 0) / 1000
            let reason = p["errorMessage"].string ?? L("模型请求失败")
            notice = L("服务端将在 \(seconds) 秒后重试：\(reason)")
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

/// Older pages read one after another, held until they are prepended together.
/// Each page is reduced and ordered as `KimiConversation.prepend(_:)` would at
/// that point, so the next page is requested before the same message.
public struct KimiHistoryBatch {
    fileprivate private(set) var pages: [[KimiMessage]] = []
    private var existing: Set<String>
    /// The window's first message once these pages are prepended.
    public private(set) var oldest: KimiMessage?
    public private(set) var hasMore: Bool
    public var isEmpty: Bool { pages.isEmpty }
    public init(_ conversation: KimiConversation) {
        existing = Set(conversation.messages.map(\.id)); oldest = conversation.messages.first; hasMore = conversation.hasOlder
    }
    public mutating func add(_ page: KimiPage<KimiMessage>) {
        let older = page.items.filter { !existing.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        existing.formUnion(older.map(\.id))
        pages.append(older); hasMore = page.hasMore
        if let first = older.first { oldest = first }
    }
}
