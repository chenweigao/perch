import Dispatch
import Foundation

public struct ConversationPresentationUpdateMetrics: Equatable {
    public let cacheHit: Bool
    public let inputComparisonNanoseconds: UInt64
    public let stateResetNanoseconds: UInt64
    public let toolProjectionNanoseconds: UInt64
    public let turnProjectionNanoseconds: UInt64
    public let narrativeNanoseconds: UInt64
    public let rowProjectionNanoseconds: UInt64
    public let summaryNanoseconds: UInt64
    public let retainedCostNanoseconds: UInt64
    public let totalNanoseconds: UInt64
    public let reusedTurnCount: Int
    public let rebuiltTurnCount: Int
}

/// Pure, synchronous presentation work. No provider, view, task or network owner is
/// retained here. The caller's complete inputs remain the source of truth.
public final class ConversationPresentationModel {
    public struct Input: Equatable {
        public let messages: [KimiMessage]
        public let live: [KimiLiveTool]
        public let running: Set<String>
        public let isRunning: Bool
        public let online: Bool
        public let epoch: String?
        public let language: String
        public let summariesEnabled: Bool
        public let includeToolOutput: Bool
        public init(messages: [KimiMessage], live: [KimiLiveTool] = [], running: Set<String> = [],
                    isRunning: Bool = false, online: Bool = true, epoch: String? = nil,
                    language: String, summariesEnabled: Bool = false, includeToolOutput: Bool = false) {
            self.messages = messages; self.live = live; self.running = running
            self.isRunning = isRunning; self.online = online; self.epoch = epoch; self.language = language
            self.summariesEnabled = summariesEnabled; self.includeToolOutput = includeToolOutput
        }
    }
    public struct Row: Equatable {
        public let entry: ConversationTimelineEntry
        public let tools: [String: VisibleTool]
        public let activity: ActivityNarrativeRow?
        /// Rows collapsed behind a process fold; non-nil only on fold rows.
        public let foldedRows: [Row]?
        public init(entry: ConversationTimelineEntry, tools: [String: VisibleTool],
                    activity: ActivityNarrativeRow?, foldedRows: [Row]? = nil) {
            self.entry = entry; self.tools = tools; self.activity = activity; self.foldedRows = foldedRows
        }
    }
    public final class Snapshot {
        public let rows: [Row]
        public let navigation: [ConversationTurnSummary]
        public let narrative: ActivityNarrativeSnapshot
        public let narrativeKey: String
        public let batch: ActivitySummaryBatch?
        init(rows: [Row], navigation: [ConversationTurnSummary], narrative: ActivityNarrativeSnapshot,
             batch: ActivitySummaryBatch?) {
            self.rows = rows; self.navigation = navigation; self.narrative = narrative; self.batch = batch
            narrativeKey = [narrative.current?.stageID, narrative.current?.headline,
                narrative.current?.detail, narrative.current?.source.rawValue,
                narrative.current?.lifecycle.rawValue, narrative.current.map { String($0.revision) },
                narrative.current?.evidenceIDs.joined(separator: ","), String(narrative.entryStageIDs.count)]
                .compactMap { $0 }.joined(separator: "|")
        }
        /// External summaries stay live; they never become part of a cached input.
        public func displayedRows(activity: (String) -> ActivityNarrativeRow?) -> [Row] {
            rows.compactMap { row in
                let narrative = activity(row.entry.id) ?? row.activity
                if let narrative, narrative.isAnchor, !narrative.stageClosed,
                   row.entry.isNarrativeSource(for: narrative.narrative) { return nil }
                return Row(entry: row.entry, tools: row.tools, activity: narrative)
            }
        }
    }
    public let key: String
    public private(set) var preparationCount = 0
    public private(set) var retainedPayloadCost = 0
    public private(set) var messageCount = 0
    private let metricsHandler: ((ConversationPresentationUpdateMetrics) -> Void)?
    private var tools = ToolVisibilityProjection()
    private var turns = ConversationProjection()
    private var messageCosts: [Int] = []
    private var previous: Input?
    private var snapshot: Snapshot?
    public init(key: String, metricsHandler: ((ConversationPresentationUpdateMetrics) -> Void)? = nil) {
        self.key = key
        self.metricsHandler = metricsHandler
    }

    public func update(_ input: Input) -> Snapshot {
        let updateStarted = timestamp()
        let comparisonStarted = timestamp()
        let equal = previous == input
        let comparisonEnded = timestamp()
        if equal, let snapshot {
            let updateEnded = timestamp()
            metricsHandler?(ConversationPresentationUpdateMetrics(
                cacheHit: true,
                inputComparisonNanoseconds: comparisonEnded - comparisonStarted,
                stateResetNanoseconds: 0,
                toolProjectionNanoseconds: 0,
                turnProjectionNanoseconds: 0,
                narrativeNanoseconds: 0,
                rowProjectionNanoseconds: 0,
                summaryNanoseconds: 0,
                retainedCostNanoseconds: 0,
                totalNanoseconds: updateEnded - updateStarted,
                reusedTurnCount: 0,
                rebuiltTurnCount: 0))
            return snapshot
        }
        let resetStarted = timestamp()
        // Runtime replacement clears live-only evidence; a language change only
        // rebuilds localized excerpts and keeps the same observed tool handoff.
        if let previous, previous.epoch != input.epoch { tools = ToolVisibilityProjection() }
        if let previous, previous.epoch != input.epoch || previous.language != input.language {
            turns = ConversationProjection()
        }
        let resetEnded = timestamp()
        let toolsStarted = timestamp()
        let visible = tools.update(input.messages, sessionID: key, live: input.live,
                                   running: input.running, online: input.online)
        let toolsEnded = timestamp()
        let turnsStarted = timestamp()
        let timeline = turns.update(visible.messages, isRunning: input.isRunning)
        let turnsEnded = timestamp()
        let narrativeStarted = timestamp()
        let narrative = ActivityNarrativeProjection.make(entries: timeline.entries, tools: visible.tools, isRunning: input.isRunning)
        let narrativeEnded = timestamp()
        let rowsStarted = timestamp()
        let projected = narrative.rows
        let rows = timeline.entries.map { entry in
            let ids = Set(entry.messages.flatMap(\.content).compactMap(\.toolCallId))
            let rowTools = ids.reduce(into: [String: VisibleTool]()) { if let tool = visible.tools[$1] { $0[$1] = tool } }
            return Row(entry: entry, tools: rowTools, activity: projected[entry.id])
        }
        let rowsEnded = timestamp()
        let summaryStarted = timestamp()
        let batch = ActivitySummaryBatch.latest(in: timeline.entries, tools: visible.tools,
            isRunning: input.isRunning, enabled: input.summariesEnabled, includeToolOutput: input.includeToolOutput)
        let summaryEnded = timestamp()
        let value = Snapshot(rows: rows, navigation: timeline.navigation, narrative: narrative, batch: batch)
        snapshot = value; preparationCount += 1
        messageCount = input.messages.count
        let retainedCostStarted = timestamp()
        // Token updates preserve historical message values. Reuse their source
        // costs while still comparing full values, including same-ID tool edits.
        let oldCosts = messageCosts
        messageCosts = input.messages.enumerated().map { index, message in
            if let previous, previous.messages.indices.contains(index), previous.messages[index] == message {
                return oldCosts[index]
            }
            return Self.cost(message)
        }
        retainedPayloadCost = messageCosts.reduce(0, +)
            + tools.retainedLiveTools.reduce(0) { $0 + $1.name.utf8.count + $1.id.utf8.count + Self.cost($1.args) + Self.cost($1.lastProgress) }
        previous = input
        let retainedCostEnded = timestamp()
        let updateEnded = timestamp()
        metricsHandler?(ConversationPresentationUpdateMetrics(
            cacheHit: false,
            inputComparisonNanoseconds: comparisonEnded - comparisonStarted,
            stateResetNanoseconds: resetEnded - resetStarted,
            toolProjectionNanoseconds: toolsEnded - toolsStarted,
            turnProjectionNanoseconds: turnsEnded - turnsStarted,
            narrativeNanoseconds: narrativeEnded - narrativeStarted,
            rowProjectionNanoseconds: rowsEnded - rowsStarted,
            summaryNanoseconds: summaryEnded - summaryStarted,
            retainedCostNanoseconds: retainedCostEnded - retainedCostStarted,
            totalNanoseconds: updateEnded - updateStarted,
            reusedTurnCount: timeline.reusedTurnCount,
            rebuiltTurnCount: timeline.rebuiltTurnCount))
        return value
    }

    private func timestamp() -> UInt64 {
        metricsHandler == nil ? 0 : DispatchTime.now().uptimeNanoseconds
    }
    // Admission cost counts UTF-8 payload and conservative per-record overhead,
    // including nested tool JSON and remembered live tools. This is not process RSS.
    private static func cost(_ message: KimiMessage) -> Int {
        message.id.utf8.count + message.role.utf8.count + message.createdAt.utf8.count + cost(message.metadata) + 128
            + message.content.reduce(0) { total, part in
                total + [part.type, part.text, part.thinking, part.toolCallId, part.toolName, part.fileId, part.name]
                    .compactMap { $0 }.reduce(128) { $0 + $1.utf8.count }
                    + cost(part.input) + cost(part.output) + cost(part.source)
            }
    }
    private static func cost(_ value: JSONValue?) -> Int {
        guard let value else { return 0 }
        switch value {
        case .string(let text): return text.utf8.count + 32
        case .array(let values): return values.reduce(32) { $0 + cost($1) }
        case .object(let values): return values.reduce(32) { $0 + $1.key.utf8.count + cost($1.value) + 32 }
        default: return 16
        }
    }
}

/// Workbench-owned LRU of computation models, never AppKit row hosts. Large active
/// conversations still render normally; they are not retained after leaving.
public final class ConversationPresentationCache {
    private let capacity: Int
    private let maximumMessages: Int
    private let maximumPayloadCost: Int
    private var models: [String: ConversationPresentationModel] = [:]
    private var recency: [String] = []
    public var count: Int { models.count }
    public private(set) var restorationCount = 0
    public var retainedPreparationCount: Int { models.values.reduce(0) { $0 + $1.preparationCount } }
    public var retainedPayloadCost: Int { models.values.reduce(0) { $0 + $1.retainedPayloadCost } }
    public init(capacity: Int = 8, maximumMessages: Int = 1_000, maximumPayloadCost: Int = 1_048_576) {
        precondition(capacity >= 0 && maximumMessages >= 0 && maximumPayloadCost >= 0)
        self.capacity = capacity; self.maximumMessages = maximumMessages; self.maximumPayloadCost = maximumPayloadCost
    }
    func model(for key: String) -> ConversationPresentationModel? {
        guard let model = models[key] else { return nil }
        restorationCount += 1
        return model
    }
    func retain(_ model: ConversationPresentationModel) {
        remove(model.key)
        guard capacity > 0, model.messageCount <= maximumMessages, model.retainedPayloadCost <= maximumPayloadCost else { return }
        models[model.key] = model; recency.append(model.key)
        while recency.count > capacity { remove(recency[0]) }
    }
    public func remove(_ key: String) { models.removeValue(forKey: key); recency.removeAll { $0 == key } }
    public func remove(prefix: String) { for key in recency.filter({ $0.hasPrefix(prefix) }) { remove(key) } }
    public func removeAll() { models.removeAll(); recency.removeAll() }
}

/// View-lifetime handle also keeps an oversized/evicted active model usable. It
/// releases that model on navigation; the optional workbench cache controls reuse.
public final class ConversationPresentationHandle {
    private var current: ConversationPresentationModel?
    public init() {}
    public func update(key: String, input: ConversationPresentationModel.Input,
                       cache: ConversationPresentationCache? = nil) -> ConversationPresentationModel.Snapshot {
        let model = current?.key == key ? current! : cache?.model(for: key) ?? ConversationPresentationModel(key: key)
        current = model
        let result = model.update(input)
        cache?.retain(model)
        return result
    }
}
