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
    /// The turns before the latest prompt were reused without being projected again.
    public let reusedHistory: Bool
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
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isRunning == rhs.isRunning && lhs.online == rhs.online && lhs.epoch == rhs.epoch
                && lhs.language == rhs.language && lhs.summariesEnabled == rhs.summariesEnabled
                && lhs.includeToolOutput == rhs.includeToolOutput && lhs.running == rhs.running && lhs.live == rhs.live
                && Self.equal(lhs.messages, rhs.messages)
        }
        /// A streamed token changes the latest message: compare from the end so
        /// a changed window is told apart without walking all of its history.
        private static func equal(_ lhs: [KimiMessage], _ rhs: [KimiMessage]) -> Bool {
            guard lhs.count == rhs.count else { return false }
            var index = lhs.count
            while index > 0 {
                index -= 1
                if lhs[index] != rhs[index] { return false }
            }
            return true
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
    /// Rows of the turns before the latest user prompt. While only the latest
    /// turn changes, every snapshot shares one instance, so its rows are neither
    /// rebuilt nor re-presented for each streamed token.
    final class History {
        let rows: [Row]
        let entryIDs: Set<String>
        let navigation: [ConversationTurnSummary]
        let turnCount: Int
        let source: ToolVisibilityProjection.Prefix?
        var cost = 0
        private var presentation: (activity: [String: ActivityNarrativeRow], foldsProcess: Bool, value: Presentation)?

        init(rows: [Row] = [], navigation: [ConversationTurnSummary] = [], turnCount: Int = 0,
             source: ToolVisibilityProjection.Prefix? = nil) {
            self.rows = rows; self.navigation = navigation; self.turnCount = turnCount; self.source = source
            entryIDs = Set(rows.map(\.entry.id))
        }

        /// These rows never carry the model's own narrative (it covers the latest
        /// turn only), and no live reply is among them; `Snapshot.presented` checks both.
        func presented(activity: [String: ActivityNarrativeRow], foldsProcess: Bool) -> Presentation {
            let relevant = activity.filter { entryIDs.contains($0.key) }
            if let presentation, presentation.foldsProcess == foldsProcess, presentation.activity == relevant {
                return presentation.value
            }
            let displayed = rows.compactMap { row -> Row? in
                guard let narrative = relevant[row.entry.id] else { return row }
                if narrative.isAnchor, !narrative.stageClosed, row.entry.isNarrativeSource(for: narrative.narrative) { return nil }
                return Row(entry: row.entry, tools: row.tools, activity: narrative)
            }
            let value = Presentation(displayed: displayed, foldsProcess: foldsProcess, isRunning: false)
            presentation = (relevant, foldsProcess, value)
            return value
        }
    }

    /// Transcript rows after external summaries and process folding.
    public struct Presentation: Equatable {
        public let rows: [Row]
        /// Folded entry id -> its fold row id, so find results open the fold.
        public let foldParents: [String: String]

        init(displayed: [Row], foldsProcess: Bool, isRunning: Bool) {
            rows = foldsProcess ? ConversationProcessFold.fold(rows: displayed, isRunning: isRunning) : displayed
            foldParents = Self.parents(of: rows)
        }
        init(rows: [Row], foldParents: [String: String]) { self.rows = rows; self.foldParents = foldParents }

        static func parents(of rows: [Row], into map: [String: String] = [:]) -> [String: String] {
            rows.reduce(into: map) { map, row in
                for folded in row.foldedRows ?? [] { map[folded.entry.id] = row.entry.id }
            }
        }
    }

    public final class Snapshot {
        let history: History
        let tail: [Row]
        public var rows: [Row] { history.rows.isEmpty ? tail : history.rows + tail }
        public let navigation: [ConversationTurnSummary]
        public let narrative: ActivityNarrativeSnapshot
        public let narrativeKey: String
        public let batch: ActivitySummaryBatch?
        init(history: History, tail: [Row], navigation: [ConversationTurnSummary], narrative: ActivityNarrativeSnapshot,
             batch: ActivitySummaryBatch?) {
            self.history = history; self.tail = tail
            self.navigation = navigation; self.narrative = narrative; self.batch = batch
            narrativeKey = [narrative.current?.stageID, narrative.current?.headline,
                narrative.current?.detail, narrative.current?.source.rawValue,
                narrative.current?.lifecycle.rawValue, narrative.current.map { String($0.revision) },
                narrative.current?.evidenceIDs.joined(separator: ","), String(narrative.entryStageIDs.count)]
                .compactMap { $0 }.joined(separator: "|")
        }
        /// External summaries stay live; they never become part of a cached input.
        public func displayedRows(activity: (String) -> ActivityNarrativeRow?) -> [Row] {
            Self.displayed(rows, activity: activity, liveReplyID: Self.liveReplyID(in: rows))
        }

        /// `displayedRows` followed by the process fold when `foldsProcess` is set.
        /// The earlier turns are presented once per summary overlay; each update
        /// then only presents the latest turn.
        public func presented(activity: [String: ActivityNarrativeRow], foldsProcess: Bool, isRunning: Bool) -> Presentation {
            let liveReplyID = Self.liveReplyID(in: tail)
            func whole() -> Presentation {
                Presentation(displayed: displayedRows { activity[$0] }, foldsProcess: foldsProcess, isRunning: isRunning)
            }
            guard !history.rows.isEmpty else {
                return Presentation(displayed: Self.displayed(tail, activity: { activity[$0] }, liveReplyID: liveReplyID),
                                    foldsProcess: foldsProcess, isRunning: isRunning)
            }
            if let liveReplyID, history.entryIDs.contains(liveReplyID) { return whole() }
            let latest = Self.displayed(tail, activity: { activity[$0] }, liveReplyID: liveReplyID)
            // Folding is decided per turn, so it divides exactly at the latest prompt.
            if foldsProcess, let first = latest.first?.entry,
               !(first.presentation == .message && first.messages.first?.isUserPrompt == true) { return whole() }
            if foldsProcess, latest.isEmpty { return whole() }
            let earlier = history.presented(activity: activity, foldsProcess: foldsProcess)
            let rows = foldsProcess ? ConversationProcessFold.fold(rows: latest, isRunning: isRunning) : latest
            return Presentation(rows: earlier.rows + rows, foldParents: Presentation.parents(of: rows, into: earlier.foldParents))
        }

        // Keep the current reply visible. Its locally derived commentary
        // summary is useful to the activity bar, but must not replace the
        // actual streaming text in the transcript.
        private static func liveReplyID(in rows: [Row]) -> String? {
            rows.last { $0.entry.presentation == .progress && $0.activity?.stageClosed == false }?.entry.id
        }

        private static func displayed(_ rows: [Row], activity: (String) -> ActivityNarrativeRow?, liveReplyID: String?) -> [Row] {
            rows.compactMap { row in
                if row.entry.id == liveReplyID {
                    return Row(entry: row.entry, tools: row.tools, activity: nil)
                }
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
    private var history: History?
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
                rebuiltTurnCount: 0,
                reusedHistory: false))
            return snapshot
        }
        let resetStarted = timestamp()
        // Runtime replacement clears live-only evidence; a language change only
        // rebuilds localized excerpts and keeps the same observed tool handoff.
        if let previous, previous.epoch != input.epoch { tools = ToolVisibilityProjection() }
        if let previous, previous.epoch != input.epoch || previous.language != input.language {
            turns = ConversationProjection(); history = nil; tools.discardPrefix()
        }
        let resetEnded = timestamp()
        let toolsStarted = timestamp()
        // The turns before the latest prompt are projected once; a streamed token
        // only reprojects the latest turn. The split never changes the result.
        let split = input.messages.lastIndex(where: \.isUserPrompt).flatMap { $0 > 0 ? $0 : nil }
        let parts = split.map { tools.update(input.messages, splittingAt: $0, sessionID: key, live: input.live,
                                             running: input.running, online: input.online) }
        let whole = parts == nil ? tools.update(input.messages, sessionID: key, live: input.live,
                                                running: input.running, online: input.online) : nil
        let toolsEnded = timestamp()
        let turnsStarted = timestamp()
        var reusedTurnCount = 0, rebuiltTurnCount = 0
        var earlier: History?
        var reusedHistory = false
        let entries: [ConversationTimelineEntry]
        let visibleTools: [String: VisibleTool]
        let navigation: [ConversationTurnSummary]
        if let parts, parts.separable {
            if let history, history.source === parts.prefix {
                earlier = history; reusedHistory = true
                reusedTurnCount = history.turnCount
            } else {
                let timeline = turns.update(parts.prefix.messages, isRunning: false)
                reusedTurnCount = timeline.reusedTurnCount; rebuiltTurnCount = timeline.rebuiltTurnCount
                earlier = History(rows: timeline.entries.map { Self.row($0, tools: parts.prefix.tools, activity: nil) },
                                  navigation: timeline.navigation, turnCount: timeline.reusedTurnCount + timeline.rebuiltTurnCount,
                                  source: parts.prefix)
            }
            entries = ConversationTimelineEntry.make(parts.tail.messages, isRunning: input.isRunning)
            rebuiltTurnCount += 1
            visibleTools = parts.tail.tools
            navigation = earlier!.navigation + (ConversationTurnSummary.make(parts.tail.messages, entries: entries).map { [$0] } ?? [])
        } else {
            let visible = whole ?? ToolVisibilityProjection.Snapshot(messages: parts!.prefix.messages + parts!.tail.messages,
                tools: parts!.prefix.tools.merging(parts!.tail.tools) { _, latest in latest })
            let timeline = turns.update(visible.messages, isRunning: input.isRunning)
            reusedTurnCount = timeline.reusedTurnCount; rebuiltTurnCount = timeline.rebuiltTurnCount
            entries = timeline.entries; visibleTools = visible.tools; navigation = timeline.navigation
        }
        history = earlier
        let turnsEnded = timestamp()
        let narrativeStarted = timestamp()
        let narrative = ActivityNarrativeProjection.make(entries: entries, tools: visibleTools, isRunning: input.isRunning)
        let narrativeEnded = timestamp()
        let rowsStarted = timestamp()
        let projected = narrative.rows
        let latest = entries.map { Self.row($0, tools: visibleTools, activity: projected[$0.id]) }
        let presentedHistory: History, tail: [Row]
        if let earlier, projected.keys.contains(where: earlier.entryIDs.contains) {
            // An earlier entry sharing an id with the latest turn takes its
            // narrative too; present that snapshot without a shared history.
            presentedHistory = History()
            tail = earlier.rows.map { Row(entry: $0.entry, tools: $0.tools, activity: projected[$0.entry.id]) } + latest
        } else {
            presentedHistory = earlier ?? History(); tail = latest
        }
        let rowsEnded = timestamp()
        let summaryStarted = timestamp()
        let batch = ActivitySummaryBatch.latest(in: entries, tools: visibleTools,
            isRunning: input.isRunning, enabled: input.summariesEnabled, includeToolOutput: input.includeToolOutput)
        let summaryEnded = timestamp()
        let value = Snapshot(history: presentedHistory, tail: tail, navigation: navigation, narrative: narrative, batch: batch)
        snapshot = value; preparationCount += 1
        messageCount = input.messages.count
        let retainedCostStarted = timestamp()
        // Token updates preserve historical message values. Reuse their source
        // costs while still comparing full values, including same-ID tool edits.
        let oldCosts = messageCosts
        let reuseEnd = reusedHistory && oldCosts.count >= split! ? split! : 0
        var costs = Array(oldCosts[..<reuseEnd])
        costs.reserveCapacity(input.messages.count)
        for index in reuseEnd..<input.messages.count {
            let message = input.messages[index]
            if let previous, previous.messages.indices.contains(index), previous.messages[index] == message {
                costs.append(oldCosts[index])
            } else {
                costs.append(Self.cost(message))
            }
        }
        messageCosts = costs
        let sourceCost: Int
        if let earlier, let split {
            if reuseEnd == 0 { earlier.cost = costs[..<split].reduce(0, +) }
            sourceCost = earlier.cost + costs[split...].reduce(0, +)
        } else {
            sourceCost = costs.reduce(0, +)
        }
        retainedPayloadCost = sourceCost
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
            reusedTurnCount: reusedTurnCount,
            rebuiltTurnCount: rebuiltTurnCount,
            reusedHistory: reusedHistory))
        return value
    }

    private static func row(_ entry: ConversationTimelineEntry, tools: [String: VisibleTool],
                            activity: ActivityNarrativeRow?) -> Row {
        var rowTools: [String: VisibleTool] = [:]
        for message in entry.messages {
            for part in message.content {
                if let id = part.toolCallId, let tool = tools[id] { rowTools[id] = tool }
            }
        }
        return Row(entry: entry, tools: rowTools, activity: activity)
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
