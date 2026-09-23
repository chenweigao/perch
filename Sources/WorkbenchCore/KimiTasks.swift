import Foundation

/// One entry of Kimi's task vocabulary. The snapshot's subagent roster, the REST
/// task list and a single task read share this shape; the phase fields only
/// appear on roster entries. Kind, status and phase stay strings so an added
/// server value remains visible instead of failing the whole read.
public struct KimiTask: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let description: String
    public var status: String
    public let createdAt: String?
    public var startedAt: String?
    public var completedAt: String?
    public var subagentPhase: String?
    public var suspendedReason: String?
    public var outputPreview: String?
    public let command: String?
    public let model: String?
    public let thinkingEffort: String?
    public let agentId: String?
    public let subagentType: String?
    public let parentToolCallId: String?
    public let swarmIndex: Int?
    public let runInBackground: Bool?
    public let outputBytes: Int?

    public init(id: String, kind: String, description: String, status: String,
                createdAt: String? = nil, startedAt: String? = nil, completedAt: String? = nil,
                subagentPhase: String? = nil, suspendedReason: String? = nil, outputPreview: String? = nil,
                command: String? = nil, model: String? = nil, thinkingEffort: String? = nil,
                agentId: String? = nil, subagentType: String? = nil, parentToolCallId: String? = nil,
                swarmIndex: Int? = nil, runInBackground: Bool? = nil, outputBytes: Int? = nil) {
        self.id = id; self.kind = kind; self.description = description; self.status = status
        self.createdAt = createdAt; self.startedAt = startedAt; self.completedAt = completedAt
        self.subagentPhase = subagentPhase; self.suspendedReason = suspendedReason
        self.outputPreview = outputPreview; self.command = command; self.model = model
        self.thinkingEffort = thinkingEffort; self.agentId = agentId; self.subagentType = subagentType
        self.parentToolCallId = parentToolCallId; self.swarmIndex = swarmIndex
        self.runInBackground = runInBackground; self.outputBytes = outputBytes
    }

    public var kindLabel: String {
        switch kind {
        case "subagent": return L("子 Agent")
        case "bash": return L("命令")
        case "tool": return L("工具")
        default: return kind
        }
    }
    public var statusLabel: String {
        switch status {
        case "running": return L("运行中")
        case "completed": return L("已完成")
        case "failed": return L("失败")
        case "cancelled": return L("已取消")
        default: return status
        }
    }
    /// The roster separates a queued child from one whose turn already runs, and
    /// a suspended one from a finished one. Terminal phases read as their status.
    public var phaseLabel: String {
        switch subagentPhase {
        case "queued": return L("排队中")
        case "working": return L("执行中")
        case "suspended": return L("已暂停")
        case nil: return statusLabel
        default: return statusLabel
        }
    }
    public var isRunning: Bool { status == "running" }
    public var isFailed: Bool { status == "failed" }
    /// The agent whose transcript this row can open. A roster entry is keyed by
    /// its agent id; a detached child reports that id next to its own task id.
    public var transcriptAgentId: String? {
        guard kind == "subagent" else { return nil }
        return agentId ?? id
    }

    /// Server timestamps are JavaScript `toISOString()` values, so they always
    /// carry fractional seconds.
    private static let timestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    public var startedDate: Date? { Self.timestampParser.date(from: startedAt ?? createdAt ?? "") }
    public var completedDate: Date? { completedAt.flatMap { Self.timestampParser.date(from: $0) } }
    public func elapsed(at now: Date) -> TimeInterval? {
        guard let startedDate else { return nil }
        return max(0, (completedDate ?? now).timeIntervalSince(startedDate))
    }
}

/// `GET /sessions/{id}/tasks` reports the persisted list; unlike the message
/// pages it carries no continuation cursor.
public struct KimiTaskList: Decodable, Sendable {
    public let items: [KimiTask]
}

/// The selected session's subagent roster and background task list. Snapshot and
/// REST reads are authoritative; subagent lifecycle events keep the roster
/// current in between, because a swarm emits far too many of them to re-read a
/// snapshot each time.
public struct KimiTaskBoard: Equatable, Sendable {
    public private(set) var subagents: [KimiTask] = []
    public private(set) var background: [KimiTask] = []
    /// Output tails read on demand, keyed by task id. Refreshing the task records
    /// must not discard a tail the reader already opened.
    public private(set) var outputs: [String: String] = [:]

    public init() {}
    public init(subagents: [KimiTask]) { self.subagents = subagents }

    public var isEmpty: Bool { subagents.isEmpty && backgroundTasks.isEmpty }
    public var runningCount: Int { (subagents + backgroundTasks).filter(\.isRunning).count }
    /// A foreground child is already in the roster; while it runs, the task list
    /// carries the same child again under its own task id.
    public var backgroundTasks: [KimiTask] {
        let roster = Set(subagents.map(\.id))
        return background.filter { task in task.agentId.flatMap { roster.contains($0) } != true }
    }
    /// A fetched tail is more complete than the summary the wire already carried.
    public func output(of task: KimiTask) -> String? { outputs[task.id] ?? task.outputPreview }

    public mutating func reconcile(background: [KimiTask]) { self.background = background }
    public mutating func store(output: String, for id: String) { outputs[id] = output }
    /// A snapshot replaces the roster only. The task list and the tails already
    /// read belong to the session rather than to one turn.
    public mutating func keepBackground(from previous: KimiTaskBoard) {
        background = previous.background
        outputs = previous.outputs
    }

    /// Events that change the REST task list. `background.task.*` are legacy
    /// aliases of the same transition, so they are not counted twice.
    public static func changesTaskList(_ type: String) -> Bool {
        type == "task.started" || type == "task.terminated"
    }

    @discardableResult
    public mutating func apply(_ event: KimiEvent) -> Bool {
        let payload = event.payload
        if event.type == "turn.started" {
            // The server drops the whole roster when a new main turn begins.
            guard payload["agentId"].string == "main", !subagents.isEmpty else { return false }
            subagents = []
            return true
        }
        guard event.type.hasPrefix("subagent."), let id = payload["subagentId"].string else { return false }
        if event.type == "subagent.spawned" {
            // The server roster skips background children; the task list reports them.
            guard payload["runInBackground"] != .bool(true) else { return false }
            let name = payload["subagentName"].string
            let spawned = KimiTask(id: id, kind: "subagent",
                                   description: payload["description"].string ?? name ?? id,
                                   status: "running", createdAt: event.timestamp,
                                   subagentPhase: "queued", model: payload["model"].string,
                                   thinkingEffort: payload["thinkingEffort"].string, subagentType: name,
                                   parentToolCallId: payload["parentToolCallId"].string,
                                   swarmIndex: payload["swarmIndex"].int, runInBackground: false)
            if let index = subagents.firstIndex(where: { $0.id == id }) { subagents[index] = spawned }
            else { subagents.append(spawned) }
            return true
        }
        guard let index = subagents.firstIndex(where: { $0.id == id }) else { return false }
        switch event.type {
        case "subagent.started":
            subagents[index].subagentPhase = "working"
            subagents[index].suspendedReason = nil
            // Like the server roster, a resumed child keeps its first start time.
            subagents[index].startedAt = subagents[index].startedAt ?? event.timestamp
        case "subagent.suspended":
            subagents[index].subagentPhase = "suspended"
            subagents[index].suspendedReason = payload["reason"].string
        case "subagent.completed":
            subagents[index].status = "completed"
            subagents[index].subagentPhase = "completed"
            subagents[index].completedAt = event.timestamp
            subagents[index].outputPreview = payload["resultSummary"].string
        case "subagent.failed":
            subagents[index].status = "failed"
            subagents[index].subagentPhase = "failed"
            subagents[index].completedAt = event.timestamp
            subagents[index].outputPreview = payload["error"].string
        case "subagent.cancelled":
            subagents[index].status = "cancelled"
            subagents[index].subagentPhase = "cancelled"
            subagents[index].completedAt = event.timestamp
        default: return false
        }
        return true
    }
}
