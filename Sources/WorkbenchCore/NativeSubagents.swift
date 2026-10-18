import Foundation

// MARK: - Roster

/// Lifecycle of a native subagent as the bridge reports it. A value this build
/// does not know, or none at all, reads as `.unknown` instead of failing the read.
public enum NativeSubagentStatus: String, Decodable, Equatable, Sendable {
    case queued, running, completed, failed, stopped, unknown

    public init(from decoder: Decoder) throws {
        let value = try? decoder.singleValueContainer().decode(String.self)
        self = value.flatMap(Self.init(rawValue:)) ?? .unknown
    }

    /// Queued or running: the subagent can still change.
    public var isLive: Bool { self == .queued || self == .running }
}

/// What the runtime last reported a subagent used. Unreported values stay nil
/// rather than zero.
public struct NativeSubagentUsage: Decodable, Equatable, Sendable {
    public let totalTokens: Int?
    public let toolUses: Int?
    public let durationMs: Int?

    public init(totalTokens: Int? = nil, toolUses: Int? = nil, durationMs: Int? = nil) {
        self.totalTokens = totalTokens; self.toolUses = toolUses; self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey { case totalTokens, toolUses, durationMs }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try? container.decodeIfPresent(Int.self, forKey: .totalTokens)
        toolUses = try? container.decodeIfPresent(Int.self, forKey: .toolUses)
        durationMs = try? container.decodeIfPresent(Int.self, forKey: .durationMs)
    }
}

/// One entry of a native session's subagent roster: an element of a protocol 7
/// snapshot's `subagents`, and the `entry` of every transcript read.
///
/// `id` is the first identifier the bridge saw and never changes; the transcript
/// and stop routes accept it or any alias (`taskId`, an element of `toolUseIds`).
/// Timestamps are ISO 8601 UTC with milliseconds, as on `KimiTask`. Decoding is
/// tolerant: a missing or mistyped field reads as nil, false or empty and an
/// unknown status as `.unknown`, so one odd entry never fails the snapshot.
public struct NativeSubagent: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    /// Runtime family: "claude" for now.
    public let kind: String?
    public let taskId: String?
    public let toolUseIds: [String]
    /// The main turn that started it.
    public let turnId: String?
    public let description: String?
    public let subagentType: String?
    public let status: NativeSubagentStatus
    public let background: Bool?
    public let startedAt: String?
    public let updatedAt: String?
    public let endedAt: String?
    public let usage: NativeSubagentUsage?
    public let lastToolName: String?
    public let summary: String?
    public let error: String?
    /// The bridge can stop this subagent on its own right now.
    public let canStop: Bool
    public let stopRequested: Bool
    /// Why the last stop request failed.
    public let stopError: String?
    public let messageCount: Int?
    /// The transcript revision this entry was reported with.
    public let revision: Int?

    public init(id: String, kind: String? = nil, taskId: String? = nil, toolUseIds: [String] = [],
                turnId: String? = nil, description: String? = nil, subagentType: String? = nil,
                status: NativeSubagentStatus = .unknown, background: Bool? = nil,
                startedAt: String? = nil, updatedAt: String? = nil, endedAt: String? = nil,
                usage: NativeSubagentUsage? = nil, lastToolName: String? = nil, summary: String? = nil,
                error: String? = nil, canStop: Bool = false, stopRequested: Bool = false,
                stopError: String? = nil, messageCount: Int? = nil, revision: Int? = nil) {
        self.id = id; self.kind = kind; self.taskId = taskId; self.toolUseIds = toolUseIds
        self.turnId = turnId; self.description = description; self.subagentType = subagentType
        self.status = status; self.background = background
        self.startedAt = startedAt; self.updatedAt = updatedAt; self.endedAt = endedAt
        self.usage = usage; self.lastToolName = lastToolName; self.summary = summary; self.error = error
        self.canStop = canStop; self.stopRequested = stopRequested; self.stopError = stopError
        self.messageCount = messageCount; self.revision = revision
    }

    /// Whether `key` names this entry: its id, its task id or one of its tool use ids.
    public func matches(_ key: String) -> Bool {
        id == key || taskId == key || toolUseIds.contains(key)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, taskId, toolUseIds, turnId, description, subagentType, status, background
        case startedAt, updatedAt, endedAt, usage, lastToolName, summary, error
        case canStop, stopRequested, stopError, messageCount, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys) -> T? { try? container.decodeIfPresent(T.self, forKey: key) }
        taskId = field(.taskId)
        toolUseIds = field(.toolUseIds) ?? []
        // An entry is still addressable through an alias if its own id is unreadable.
        let declared: String? = field(.id)
        guard let id = declared ?? taskId ?? toolUseIds.first else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath,
                                                                  debugDescription: "A subagent entry has no identifier"))
        }
        self.id = id
        kind = field(.kind)
        turnId = field(.turnId)
        description = field(.description)
        subagentType = field(.subagentType)
        status = field(.status) ?? .unknown
        background = field(.background)
        startedAt = field(.startedAt)
        updatedAt = field(.updatedAt)
        endedAt = field(.endedAt)
        usage = field(.usage)
        lastToolName = field(.lastToolName)
        summary = field(.summary)
        error = field(.error)
        canStop = field(.canStop) ?? false
        stopRequested = field(.stopRequested) ?? false
        stopError = field(.stopError)
        messageCount = field(.messageCount)
        revision = field(.revision)
    }
}

/// The subagent a pending interaction was raised in: the `subagent` object on an
/// interaction. `id` stays nil until the bridge resolves `agentId` to an entry.
public struct NativeSubagentLabel: Decodable, Equatable, Sendable {
    public let id: String?
    public let agentId: String?
    public let title: String?
    public let type: String?

    public init(id: String? = nil, agentId: String? = nil, title: String? = nil, type: String? = nil) {
        self.id = id; self.agentId = agentId; self.title = title; self.type = type
    }

    /// The label of one entry of `NativeAgentSnapshot.interactions`; nil when the
    /// main agent raised it.
    public init?(interaction: JSONValue) {
        guard case .object = interaction["subagent"] else { return nil }
        self.init(label: interaction["subagent"])
    }

    public init(from decoder: Decoder) throws {
        self.init(label: try JSONValue(from: decoder))
    }

    private init(label: JSONValue) {
        self.init(id: label["id"].string, agentId: label["agentId"].string,
                  title: label["title"].string, type: label["type"].string)
    }

    /// What to call the subagent: its title, else its type; nil while neither is known.
    public var name: String? {
        [title, type].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The roster entry this label names, by id and then by agent id.
    public func entry(in subagents: [NativeSubagent]) -> NativeSubagent? {
        for key in [id, agentId].compactMap({ $0 }) {
            if let entry = subagents.first(where: { $0.matches(key) }) { return entry }
        }
        return nil
    }
}

extension KimiTask {
    /// A native roster entry as a row of the activity bar's subagent section.
    ///
    /// Status and phase use Kimi's roster vocabulary so the row's symbol, label,
    /// tint and running count read correctly: queued is a running task in phase
    /// "queued", running is phase "working", stopped reads as "cancelled", and a
    /// finished phase repeats its status. `id` is the entry key, `agentId` the
    /// task id and `parentToolCallId` the first tool use id, so
    /// `transcriptAgentId` is always a route alias. A finished entry without an
    /// end time ends at its last update, which stops its clock. The output is
    /// the summary, followed by the error when there is one.
    public init(native subagent: NativeSubagent) {
        let (status, phase): (String, String) = switch subagent.status {
        case .queued: ("running", "queued")
        case .running: ("running", "working")
        case .completed: ("completed", "completed")
        case .failed: ("failed", "failed")
        case .stopped: ("cancelled", "cancelled")
        case .unknown: ("unknown", "unknown")
        }
        func text(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        let output = [text(subagent.summary), text(subagent.error)].compactMap { $0 }
        self.init(id: subagent.id, kind: "subagent",
                  description: text(subagent.description) ?? text(subagent.subagentType) ?? subagent.id,
                  status: status, createdAt: subagent.startedAt, startedAt: subagent.startedAt,
                  completedAt: subagent.endedAt ?? (subagent.status.isLive ? nil : subagent.updatedAt),
                  subagentPhase: phase, outputPreview: output.isEmpty ? nil : output.joined(separator: "\n\n"),
                  agentId: subagent.taskId, subagentType: text(subagent.subagentType),
                  parentToolCallId: subagent.toolUseIds.first, runInBackground: subagent.background,
                  tokenCount: subagent.usage?.totalTokens, toolUseCount: subagent.usage?.toolUses,
                  latestActivity: text(subagent.lastToolName),
                  stoppable: subagent.canStop && subagent.status.isLive)
    }
}

// MARK: - Transcript paging

/// A contiguous run of one subagent's transcript: the window a full read returns
/// (the latest messages) or the page an older read (`before=`) returns. `start`
/// is the absolute index of `messages[0]` within `epoch`.
public struct NativeSubagentWindow: Decodable, Equatable, Sendable {
    public let entry: NativeSubagent?
    public let epoch: String
    public let revision: Int
    public let total: Int
    /// Messages trimmed from the front before this epoch began.
    public let truncated: Int
    public let start: Int
    public let messages: [KimiMessage]

    private enum CodingKeys: String, CodingKey { case entry, epoch, revision, total, truncated, start, messages }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entry = try? container.decodeIfPresent(NativeSubagent.self, forKey: .entry)
        epoch = try container.decode(String.self, forKey: .epoch)
        revision = try container.decode(Int.self, forKey: .revision)
        start = try container.decode(Int.self, forKey: .start)
        messages = try container.decode([KimiMessage].self, forKey: .messages)
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? start + messages.count
        truncated = (try? container.decodeIfPresent(Int.self, forKey: .truncated)) ?? 0
    }
}

/// Every message whose version is newer than the revision the client sent, by
/// absolute index within `epoch`.
public struct NativeSubagentDelta: Decodable, Equatable, Sendable {
    public struct Change: Decodable, Equatable, Sendable {
        public let index: Int
        public let message: KimiMessage
    }
    public let entry: NativeSubagent?
    public let epoch: String
    public let revision: Int
    public let total: Int
    public let truncated: Int
    public let changes: [Change]

    private enum CodingKeys: String, CodingKey { case entry, epoch, revision, total, truncated, changes }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entry = try? container.decodeIfPresent(NativeSubagent.self, forKey: .entry)
        epoch = try container.decode(String.self, forKey: .epoch)
        revision = try container.decode(Int.self, forKey: .revision)
        total = try container.decode(Int.self, forKey: .total)
        truncated = (try? container.decodeIfPresent(Int.self, forKey: .truncated)) ?? 0
        changes = try container.decode([Change].self, forKey: .changes)
    }
}

/// One answer of `GET /sessions/<sid>/subagents/<key>`.
///
/// Decoding reads a follow read: `{"unchanged":true}`, a delta (it carries
/// `changes`) or a full window. An older page has the full window's shape, so
/// whoever asked for one decodes a `NativeSubagentWindow` and wraps it in `.older`.
public enum NativeSubagentPage: Decodable, Equatable, Sendable {
    case unchanged
    case full(NativeSubagentWindow)
    case delta(NativeSubagentDelta)
    case older(NativeSubagentWindow)

    private enum CodingKeys: String, CodingKey { case unchanged, changes }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .unchanged) == true { self = .unchanged }
        else if container.contains(.changes) { self = .delta(try NativeSubagentDelta(from: decoder)) }
        else { self = .full(try NativeSubagentWindow(from: decoder)) }
    }
}

/// One subagent's transcript as this client holds it: a contiguous window of one
/// epoch, kept current by follow reads and extended backwards by older pages.
/// Positions are absolute, so a message replaced by index never duplicates.
public struct NativeSubagentTranscript: Equatable, Sendable {
    /// The key this client reads under; any alias of the entry.
    public let key: String
    /// The entry as the latest page reported it.
    public private(set) var entry: NativeSubagent?
    /// The baseline's history epoch. nil until a full window arrives, and again
    /// after a delta that did not fit; either way the next follow read is full.
    public private(set) var epoch: String?
    public private(set) var revision = 0
    public private(set) var total = 0
    public private(set) var truncated = 0
    /// Absolute index of `messages[0]`.
    public private(set) var start = 0
    public private(set) var messages: [KimiMessage] = []

    public init(key: String) { self.key = key }

    /// Earlier messages of this epoch can be read with `olderQuery(limit:)`.
    public var hasOlder: Bool { epoch != nil && start > 0 }

    /// The query of the next follow read: none (a full window) until there is a
    /// baseline, then a delta against it.
    public var followQuery: String {
        guard let epoch else { return "" }
        return "?epoch=\(Self.queryValue(epoch))&revision=\(revision)"
    }

    /// The query of the page that ends where the held window starts, or nil when
    /// there is none. The bridge serves at most 200 messages per page.
    public func olderQuery(limit: Int = 100) -> String? {
        guard hasOlder, let epoch else { return nil }
        return "?epoch=\(Self.queryValue(epoch))&before=\(start)&limit=\(min(max(limit, 1), 200))"
    }

    /// Applies a follow read and returns whether the value changed; store it when
    /// true. A full window replaces everything unless it is an older read of the
    /// same epoch. A delta patches by index and needs the same epoch and a newer
    /// revision; changes before the held window are skipped, because an older
    /// page brings their current version. A delta that does not fit drops the
    /// baseline but keeps the messages on screen, so the next follow read is full.
    /// Older pages go through `prepend(_:)`; this ignores them.
    @discardableResult
    public mutating func apply(_ page: NativeSubagentPage) -> Bool {
        switch page {
        case .unchanged, .older:
            return false
        case .full(let window):
            if let epoch, window.epoch == epoch, window.revision <= revision { return false }
            entry = window.entry ?? entry
            epoch = window.epoch
            revision = window.revision
            total = window.total
            truncated = window.truncated
            start = window.start
            messages = window.messages
            return true
        case .delta(let delta):
            guard let epoch, delta.epoch == epoch, delta.revision > revision else { return false }
            let changes = delta.changes.filter { $0.index >= start }.sorted { $0.index < $1.index }
            guard let merged = try? NativeHistoryWindow.merge(messages, start: start, total: delta.total,
                                                               changes: changes.map { ($0.index, $0.message) }) else {
                self.epoch = nil
                return true
            }
            entry = delta.entry ?? entry
            revision = delta.revision
            total = delta.total
            truncated = delta.truncated
            messages = merged
            return true
        }
    }

    /// Adds an `.older` page of the same epoch that ends exactly where the held
    /// window starts; returns whether it was added. The entry and total stay
    /// current. The revision drops to the page's when the page is older, so the
    /// next delta also covers edits the page predates.
    @discardableResult
    public mutating func prepend(_ page: NativeSubagentPage) -> Bool {
        guard case .older(let window) = page, let epoch, window.epoch == epoch,
              window.start >= 0, window.start < start,
              window.start + window.messages.count == start else { return false }
        messages = window.messages + messages
        start = window.start
        revision = min(revision, window.revision)
        return true
    }

    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }
}

// MARK: - Transcript rows

/// One row of a subagent transcript sheet, shared by the Kimi and native sheets.
/// Rows are flat, so one long turn never becomes one enormous lazy layout unit,
/// and each carries only what it draws.
public struct SubagentTranscriptRow: Identifiable, Equatable {
    public enum Content: Equatable {
        /// A Kimi turn header.
        case turn(ordinal: Int?, state: String?)
        /// Prose. A user-role text is the prompt the subagent was given.
        case text(String, role: String?)
        case thinking(String)
        /// A tool call with its result, as the tool cards read it.
        case tool(VisibleTool)
        /// A runtime notice; level "error" marks a failure.
        case notice(String, level: String?)
        /// The failure that ended a Kimi turn.
        case error(String)
    }
    public let id: String
    public let content: Content

    public init(id: String, content: Content) { self.id = id; self.content = content }
}

extension SubagentTranscriptRow {
    /// Rows of a native transcript, which uses the main conversation's message
    /// schema: each visible text and thought, and one row per tool call with its
    /// result folded in by ToolVisibilityProjection, which also gives a result
    /// without its call a row of its own. Runtime context, results and repeated
    /// calls draw nothing here. Pass the entry's `status.isLive` as `isRunning`:
    /// only then can an unanswered call be running; offline it reads as disconnected.
    public static func rows(from messages: [KimiMessage], isRunning: Bool, online: Bool = true) -> [SubagentTranscriptRow] {
        let running = ToolVisibilityProjection.runningIDs(in: messages, busy: isRunning)
        let projected = ToolVisibilityProjection().update(messages, sessionID: "subagent", running: running, online: online)
        var rows: [SubagentTranscriptRow] = []
        for message in projected.messages {
            for (offset, part) in message.content.enumerated() {
                switch part.type {
                case "text":
                    guard let text = part.visibleText,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    rows.append(.init(id: "text:\(message.id):\(offset)", content: .text(text, role: message.role)))
                case "thinking":
                    guard let thinking = part.thinking, !thinking.isEmpty else { continue }
                    rows.append(.init(id: "thinking:\(message.id):\(offset)", content: .thinking(thinking)))
                case "tool_use":
                    guard let id = part.toolCallId, let tool = projected.tools[id] else { continue }
                    rows.append(.init(id: "tool:\(id)", content: .tool(tool)))
                default:
                    continue
                }
            }
        }
        return rows
    }

    /// Rows of a Kimi subagent transcript, flattened the way
    /// KimiSubagentTranscriptSheet draws it: each turn's header, the frames of its
    /// steps in order, then the turn's error. A frame with nothing to draw has no row.
    public static func rows(from transcript: KimiSubagentTranscript) -> [SubagentTranscriptRow] {
        transcript.turns.flatMap { turn -> [SubagentTranscriptRow] in
            var rows = [SubagentTranscriptRow(id: "turn:" + turn.id, content: .turn(ordinal: turn.ordinal, state: turn.state))]
            for frame in (turn.steps ?? []).flatMap({ $0.frames ?? [] }) {
                if let content = Content(frame: frame) { rows.append(.init(id: "frame:" + frame.frameId, content: content)) }
            }
            if let error = turn.error, !error.isEmpty { rows.append(.init(id: "error:" + turn.id, content: .error(error))) }
            return rows
        }
    }
}

extension SubagentTranscriptRow.Content {
    /// What the Kimi sheet draws for one frame: a tool card, a non-empty thought,
    /// a non-empty notice, or the text of any other kind.
    fileprivate init?(frame: KimiTranscriptFrame) {
        switch frame.kind {
        case "tool":
            guard let tool = frame.tool else { return nil }
            self = .tool(tool)
        case "thinking":
            guard let text = frame.text, !text.isEmpty else { return nil }
            self = .thinking(text)
        case "notice":
            guard let message = frame.message, !message.isEmpty else { return nil }
            self = .notice(message, level: frame.level)
        default:
            guard let text = frame.text, !text.isEmpty else { return nil }
            self = .text(text, role: frame.role)
        }
    }
}
