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
/// Folded entry id -> its fold row id, split into a shared earlier base and a
/// small per-update overlay. A streaming delta appends only the latest turn's
/// folds to the overlay instead of copy-on-writing the whole earlier dictionary.
/// Lookup and equality range over the effective mapping; the overlay wins a key
/// collision, exactly the last-write-wins order of the flat merge it replaces.
public struct FoldParents: Equatable {
    public let base: [String: String]
    public let overlay: [String: String]

    public init() { base = [:]; overlay = [:] }
    public init(base: [String: String], overlay: [String: String] = [:]) {
        self.base = base; self.overlay = overlay
    }

    public subscript(key: String) -> String? { overlay[key] ?? base[key] }
    public var isEmpty: Bool { base.isEmpty && overlay.isEmpty }
    public var keys: [String] { overlay.isEmpty ? Array(base.keys) : Array(base.keys) + Array(overlay.keys) }
    public var flattened: [String: String] {
        overlay.isEmpty ? base : base.merging(overlay) { _, new in new }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.flattened == rhs.flattened }
    public static func == (lhs: Self, rhs: [String: String]) -> Bool { lhs.flattened == rhs }
    public static func == (lhs: [String: String], rhs: Self) -> Bool { lhs == rhs.flattened }
}

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
        /// The running turn's process disclosure (PI: active turns auto-open):
        /// the fold row exists while the turn is live, then settles in place.
        public let live: Bool
        public init(entry: ConversationTimelineEntry, tools: [String: VisibleTool],
                    activity: ActivityNarrativeRow?, foldedRows: [Row]? = nil, live: Bool = false) {
            self.entry = entry; self.tools = tools; self.activity = activity; self.foldedRows = foldedRows
            self.live = live
        }
    }
    /// One earlier turn's rows, kept while the tool chunk it was built from is
    /// reused, or all earlier rows when the prefix was projected as a whole.
    final class HistoryTurn {
        let chunk: ToolVisibilityProjection.Chunk?
        let rows: [Row]
        let navigation: [ConversationTurnSummary]
        private var presentation: (activity: [String: ActivityNarrativeRow], foldsProcess: Bool, value: Presentation)?

        init(chunk: ToolVisibilityProjection.Chunk?, rows: [Row], navigation: [ConversationTurnSummary]) {
            self.chunk = chunk; self.rows = rows; self.navigation = navigation
        }

        /// Nil when a summary overlay removes the turn's prompt row: that row ends
        /// the previous turn's fold, so only the whole history folds exactly.
        func presented(activity: [String: ActivityNarrativeRow], foldsProcess: Bool) -> Presentation? {
            if let presentation, presentation.foldsProcess == foldsProcess, presentation.activity == activity {
                return presentation.value
            }
            let displayed = History.displayed(rows, activity: activity)
            if let first = rows.first, first.entry.presentation == .message, first.entry.messages.first?.isUserPrompt == true,
               displayed.first?.entry.id != first.entry.id { return nil }
            let value = Presentation(displayed: displayed, foldsProcess: foldsProcess, isRunning: false)
            presentation = (activity, foldsProcess, value)
            return value
        }
    }

    /// Rows of the turns before the latest user prompt. While only the latest
    /// turn changes, every snapshot shares one instance, so its rows are neither
    /// rebuilt nor re-presented for each streamed token.
    final class History {
        let turns: [HistoryTurn]
        let rows: [Row]
        /// Entry id -> its turn's index RELATIVE to `turnIndexBase` (absolute
        /// index = stored value + base). Round 35: the offset indirection lets
        /// a prepended page reuse the prior dictionary by copy-on-write — old
        /// relative values survive the positional shift untouched, and only the
        /// new leading turns' rows are inserted, instead of rehashing every
        /// entry id in the window per prepend.
        private let entryTurns: [String: Int]
        private let turnIndexBase: Int
        private let uniqueEntries: Bool
        let navigation: [ConversationTurnSummary]
        let turnCount: Int
        let source: ToolVisibilityProjection.Prefix?
        var cost = 0
        private var presentation: (activity: [String: ActivityNarrativeRow], foldsProcess: Bool, value: Presentation)?
        /// Round 36: the prior History's joined presentation, captured at init
        /// while the prior is still alive (by presented() time the replaced
        /// History is usually already released). `joined` redoes an O(window)
        /// string-keyed `parents.merge` per prepend because each page builds a
        /// fresh History whose instance memo is empty; adopting the captured
        /// foldParents by copy-on-write turns that into O(page) hash inserts
        /// plus one rehash-free dictionary copy. Rows stay a flat rebuild (a
        /// memcpy-optimal assembly COW adoption would not beat). Scope: the
        /// captured memo must carry no summary overlays and the requesting
        /// call must ask for the same fold shape with no overlays either —
        /// overlay shapes take the existing full path.
        private let joinedAdoption: (rows: [Row], foldParents: FoldParents, foldsProcess: Bool,
                                     consumedRowCount: Int, consumedFoldKeys: [String], leadingNew: Int)?

        init(turns: [HistoryTurn] = [], turnCount: Int = 0, source: ToolVisibilityProjection.Prefix? = nil,
             prior: History? = nil) {
            self.turns = turns; self.turnCount = turnCount; self.source = source
            var rows: [Row] = [], navigation: [ConversationTurnSummary] = []
            rows.reserveCapacity(turns.reduce(0) { $0 + $1.rows.count })
            for turn in turns {
                rows.append(contentsOf: turn.rows)
                navigation.append(contentsOf: turn.navigation)
            }
            // Prepend detection with merge tolerance: a suffix of prior.turns
            // matches the tail of `turns` by INSTANCE identity, with new turns
            // only at the front. At most the FIRST prior turn may be missing:
            // a page boundary can split a turn whose head the next page
            // merges into a new leading turn (fresh HistoryTurn instance).
            // Anything deeper (an edited or rebuilt interior turn) falls back
            // to the full build.
            var matched: (consumed: Int, leadingNew: Int)?
            if let prior, !prior.turns.isEmpty {
                for consumed in 0..<min(2, prior.turns.count) {
                    let suffixCount = prior.turns.count - consumed
                    let k = turns.count - suffixCount
                    guard k >= 1, turns.count >= suffixCount else { continue }
                    if (0..<suffixCount).allSatisfy({ turns[k + $0] === prior.turns[consumed + $0] }) {
                        matched = (consumed, k)
                        break
                    }
                }
            }
            if let prior, let match = matched {
                // Suffix turns keep their relative values: a prior turn at
                // absolute p moves to leadingNew + (p - consumed), so the
                // base shifts by (leadingNew - consumed).
                let base = prior.turnIndexBase + match.leadingNew - match.consumed
                var entryTurns = prior.entryTurns  // COW copy
                if match.consumed > 0 {
                    // Drop the consumed leading turn's entries; the merged
                    // turn re-inserts the ids it still carries below.
                    let consumedRelative = 0 - prior.turnIndexBase
                    for row in prior.turns[0].rows where entryTurns[row.entry.id] == consumedRelative {
                        entryTurns.removeValue(forKey: row.entry.id)
                    }
                }
                var inserted: Set<String> = []
                for j in 0..<match.leadingNew {
                    for row in turns[j].rows {
                        let id = row.entry.id
                        // Full-build semantics are "last occurrence wins":
                        // the prior suffix turns sit AFTER the new leading
                        // ones, so an id they hold keeps that (later) turn;
                        // among the new turns a later j overwrites an earlier.
                        if inserted.contains(id) {
                            entryTurns[id] = j - base
                        } else if entryTurns[id] == nil {
                            entryTurns[id] = j - base
                            inserted.insert(id)
                        }
                    }
                }
                self.turnIndexBase = base
                self.entryTurns = entryTurns
                // Round 36: capture the prior's joined memo for presented()'s
                // foldParents adoption. Requires the prior memo to exist, to
                // carry no summary overlays, and to have been built by the
                // per-turn joined path (prior.uniqueEntries) — the fallback
                // whole-window fold has different rows/parents semantics.
                if prior.uniqueEntries, let priorMemo = prior.presentation, priorMemo.activity.isEmpty {
                    var consumedRowCount = 0
                    var consumedFoldKeys: [String] = []
                    var adopt = true
                    if match.consumed > 0 {
                        // Turn-level memo hit (the prior's joined called this
                        // same turn with the same empty activity and fold
                        // shape); empty activity never presents nil.
                        if let consumedValue = prior.turns[0].presented(activity: [:],
                                                                        foldsProcess: priorMemo.foldsProcess) {
                            consumedRowCount = consumedValue.rows.count
                            consumedFoldKeys = consumedValue.foldParents.keys
                        } else {
                            adopt = false
                        }
                    }
                    joinedAdoption = adopt
                        ? (priorMemo.value.rows, priorMemo.value.foldParents, priorMemo.foldsProcess,
                           consumedRowCount, consumedFoldKeys, match.leadingNew)
                        : nil
                } else {
                    joinedAdoption = nil
                }
            } else {
                var entryTurns: [String: Int] = [:]
                entryTurns.reserveCapacity(rows.capacity)
                for (index, turn) in turns.enumerated() {
                    for row in turn.rows { entryTurns[row.entry.id] = index }
                }
                self.turnIndexBase = 0
                self.entryTurns = entryTurns
                joinedAdoption = nil
            }
            self.rows = rows; self.navigation = navigation
            uniqueEntries = self.entryTurns.count == rows.count
        }

        func contains(entry id: String) -> Bool { entryTurns[id] != nil }

        /// These rows never carry the model's own narrative (it covers the latest
        /// turn only), and no live reply is among them; `Snapshot.presented` checks both.
        /// Folding is decided per turn, so each turn's presentation is reused
        /// while that turn and its summary overlays stay the same.
        func presented(activity: [String: ActivityNarrativeRow], foldsProcess: Bool) -> Presentation {
            var relevant: [String: ActivityNarrativeRow] = [:]
            var byTurn: [Int: [String: ActivityNarrativeRow]] = [:]
            for (id, narrative) in activity {
                guard let relative = entryTurns[id] else { continue }
                let turn = relative + turnIndexBase
                relevant[id] = narrative; byTurn[turn, default: [:]][id] = narrative
            }
            if let presentation, presentation.foldsProcess == foldsProcess, presentation.activity == relevant {
                return presentation.value
            }
            let value: Presentation?
            if uniqueEntries, relevant.isEmpty, let adoption = joinedAdoption,
               adoption.foldsProcess == foldsProcess {
                // Round 36: adopt the prior joined memo's foldParents instead
                // of re-merging every fold id in the window (see joinedAdoption).
                value = joinedIncremental(adoption, foldsProcess: foldsProcess)
                    ?? joined(byTurn, foldsProcess: foldsProcess)
            } else {
                value = uniqueEntries ? joined(byTurn, foldsProcess: foldsProcess) : nil
            }
            let result = value ?? Presentation(displayed: Self.displayed(rows, activity: relevant),
                                               foldsProcess: foldsProcess, isRunning: false)
            presentation = (relevant, foldsProcess, result)
            return result
        }

        private func joined(_ activity: [Int: [String: ActivityNarrativeRow]], foldsProcess: Bool) -> Presentation? {
            var rows: [Row] = [], parents: [String: String] = [:]
            for (index, turn) in turns.enumerated() {
                guard let value = turn.presented(activity: activity[index] ?? [:], foldsProcess: foldsProcess) else { return nil }
                rows.append(contentsOf: value.rows)
                parents.merge(value.foldParents.flattened) { current, _ in current }
            }
            return Presentation(rows: rows, foldParents: FoldParents(base: parents))
        }

        /// Round 36: joined's output for a prepending update, derived from the
        /// adoption captured at init. Equivalence with the full merge:
        /// - fold keys are unique across the window (uniqueEntries gate), so
        ///   the only cross-turn repetition is a merged leading turn
        ///   re-carrying the consumed turn's ids — removing consumed keys
        ///   BEFORE inserting the leading ones makes the merged turn the sole
        ///   holder, exactly as in the full build where the consumed turn is
        ///   absent;
        /// - the full merge lets the EARLIEST turn win a duplicate key; the
        ///   leading turns are earlier than every adopted one, so leading
        ///   parents are accumulated with the same current-wins rule among
        ///   themselves and then overwrite the adopted (later-turn) entries;
        /// - rows are the leading turns' presented rows followed by the
        ///   adopted rows minus the consumed turn's presented row count,
        ///   matching the full concatenation order turn-for-turn.
        private func joinedIncremental(_ adoption: (rows: [Row], foldParents: FoldParents, foldsProcess: Bool,
                                                    consumedRowCount: Int, consumedFoldKeys: [String], leadingNew: Int),
                                       foldsProcess: Bool) -> Presentation? {
            var leadingRows: [Row] = []
            var leadingParents: [String: String] = [:]
            for index in 0..<adoption.leadingNew {
                guard let value = turns[index].presented(activity: [:], foldsProcess: foldsProcess) else { return nil }
                leadingRows.append(contentsOf: value.rows)
                leadingParents.merge(value.foldParents.flattened) { current, _ in current }
            }
            var parents = adoption.foldParents.flattened  // COW copy on first mutation; no rehash
            for key in adoption.consumedFoldKeys { parents.removeValue(forKey: key) }
            for (key, parent) in leadingParents { parents[key] = parent }
            var rows = leadingRows
            rows.reserveCapacity(leadingRows.count + adoption.rows.count - adoption.consumedRowCount)
            rows.append(contentsOf: adoption.rows.dropFirst(adoption.consumedRowCount))
            return Presentation(rows: rows, foldParents: FoldParents(base: parents))
        }

        static func displayed(_ rows: [Row], activity: [String: ActivityNarrativeRow]) -> [Row] {
            guard !activity.isEmpty else { return rows }
            return rows.compactMap { row -> Row? in
                guard let narrative = activity[row.entry.id] else { return row }
                if narrative.isAnchor, !narrative.stageClosed, row.entry.isNarrativeSource(for: narrative.narrative),
                   !(narrative.narrative.source == .provider && narrative.narrative.evidenceIDs.isEmpty) { return nil }
                return Row(entry: row.entry, tools: row.tools, activity: narrative)
            }
        }
    }

    /// Transcript rows after external summaries and process folding.
    public struct Presentation: Equatable {
        public let rows: [Row]
        /// Folded entry id -> its fold row id, so find results open the fold.
        public let foldParents: FoldParents

        init(displayed: [Row], foldsProcess: Bool, isRunning: Bool) {
            rows = foldsProcess ? ConversationProcessFold.fold(rows: displayed, isRunning: isRunning) : displayed
            foldParents = FoldParents(base: Self.parents(of: rows))
        }
        init(rows: [Row], foldParents: FoldParents) { self.rows = rows; self.foldParents = foldParents }

        /// Keep the rows the reader explicitly opened while work was running in
        /// their original hosts. Other completed process still folds in source order.
        public func retainingProcessEntries(_ ids: Set<String>) -> Self {
            guard !ids.isEmpty else { return self }
            var result: [Row] = []
            for row in rows {
                // An opened child stays inside the running turn's disclosure.
                // Lifting it out would manufacture two sibling "running" heads.
                guard !row.live, let children = row.foldedRows, children.contains(where: { ids.contains($0.entry.id) }) else {
                    result.append(row); continue
                }
                var pending: [Row] = []
                func flush() {
                    guard let first = pending.first else { return }
                    result.append(Row(entry: .processFold(firstEntry: first.entry), tools: [:], activity: nil, foldedRows: pending, live: row.live))
                    pending = []
                }
                for child in children {
                    if ids.contains(child.entry.id) { flush(); result.append(child) }
                    else { pending.append(child) }
                }
                flush()
            }
            return Self(rows: result, foldParents: FoldParents(base: Self.parents(of: result)))
        }

        static func parents(of rows: [Row]) -> [String: String] {
            rows.reduce(into: [String: String]()) { map, row in
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
        public func presented(activity: [String: ActivityNarrativeRow], foldsProcess: Bool, isRunning: Bool,
                              preservingEntries: Set<String> = []) -> Presentation {
            if !preservingEntries.isEmpty {
                var overlays = activity
                for row in rows where preservingEntries.contains(row.entry.id) {
                    guard let narrative = activity[row.entry.id] ?? row.activity,
                          row.entry.isNarrativeSource(for: narrative.narrative) else { continue }
                    // A summary normally moves into the live activity preview;
                    // an explicitly opened source keeps its original disclosure.
                    overlays[row.entry.id] = ActivityNarrativeRow(narrative: narrative.narrative,
                        isAnchor: false, stageClosed: narrative.stageClosed)
                }
                return presented(activity: overlays, foldsProcess: foldsProcess, isRunning: isRunning)
            }
            let liveReplyID = Self.liveReplyID(in: tail)
            func whole() -> Presentation {
                Presentation(displayed: displayedRows { activity[$0] }, foldsProcess: foldsProcess, isRunning: isRunning)
            }
            guard !history.rows.isEmpty else {
                return Presentation(displayed: Self.displayed(tail, activity: { activity[$0] }, liveReplyID: liveReplyID),
                                    foldsProcess: foldsProcess, isRunning: isRunning)
            }
            if let liveReplyID, history.contains(entry: liveReplyID) { return whole() }
            let latest = Self.displayed(tail, activity: { activity[$0] }, liveReplyID: liveReplyID)
            // Folding is decided per turn, so it divides exactly at the latest prompt.
            if foldsProcess, let first = latest.first?.entry,
               !(first.presentation == .message && first.messages.first?.isUserPrompt == true) { return whole() }
            if foldsProcess, latest.isEmpty { return whole() }
            let earlier = history.presented(activity: activity, foldsProcess: foldsProcess)
            let rows = foldsProcess ? ConversationProcessFold.fold(rows: latest, isRunning: isRunning) : latest
            return Presentation(rows: earlier.rows + rows,
                                foldParents: FoldParents(base: earlier.foldParents.flattened,
                                                         overlay: Presentation.parents(of: rows)))
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
                   row.entry.isNarrativeSource(for: narrative.narrative),
                   !(narrative.narrative.source == .provider && narrative.narrative.evidenceIDs.isEmpty) { return nil }
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
    /// Earlier turns by their first message, while their tool chunk is reused.
    private var historyTurns: [String: HistoryTurn] = [:]
    /// Per-conversation narrative memo; lives and dies with the model.
    private let narrativeCache = NarrativeTextCache()
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
            turns = ConversationProjection(); history = nil; historyTurns = [:]; tools.discardPrefix()
            // Round 38 (review F1, load-bearing): the raw-setting memo token
            // covers setting flips; a .system system-language change instead
            // moves Input.language, firing this reset — its correctness gate.
            narrativeCache.invalidateToolResolutions()
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
            } else if let chunks = parts.prefix.chunks {
                // A page of older messages or a new prompt: rebuild only the turns
                // whose tool chunk was projected again.
                var next: [String: HistoryTurn] = [:], built: [HistoryTurn] = []
                built.reserveCapacity(chunks.count)
                for chunk in chunks {
                    let id = chunk.messages[0].id
                    let turn: HistoryTurn
                    if let prior = historyTurns[id], prior.chunk === chunk {
                        turn = prior; reusedTurnCount += 1
                    } else {
                        let timeline = ConversationTimelineEntry.make(chunk.messages, isRunning: false)
                        turn = HistoryTurn(chunk: chunk, rows: timeline.map { Self.row($0, tools: chunk.tools, activity: nil) },
                                           navigation: ConversationTurnSummary.lazy(chunk.messages, entries: timeline).map { [$0] } ?? [])
                        rebuiltTurnCount += 1
                    }
                    next[id] = turn; built.append(turn)
                }
                historyTurns = next
                earlier = History(turns: built, turnCount: chunks.count, source: parts.prefix,
                                  prior: history)
            } else {
                let timeline = turns.update(parts.prefix.messages, isRunning: false)
                reusedTurnCount = timeline.reusedTurnCount; rebuiltTurnCount = timeline.rebuiltTurnCount
                historyTurns = [:]
                earlier = History(turns: [HistoryTurn(chunk: nil, rows: timeline.entries.map { Self.row($0, tools: parts.prefix.tools, activity: nil) },
                                                      navigation: timeline.navigation)],
                                  turnCount: timeline.reusedTurnCount + timeline.rebuiltTurnCount, source: parts.prefix)
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
        let narrative = ActivityNarrativeProjection.make(entries: entries, tools: visibleTools, isRunning: input.isRunning, cache: narrativeCache)
        let narrativeEnded = timestamp()
        let rowsStarted = timestamp()
        let projected = narrative.rows
        let latest = entries.map { Self.row($0, tools: visibleTools, activity: projected[$0.id]) }
        let presentedHistory: History, tail: [Row]
        if let earlier, projected.keys.contains(where: earlier.contains(entry:)) {
            // An earlier entry sharing an id with the latest turn takes its
            // narrative too; present that snapshot without a shared history.
            presentedHistory = History()
            tail = earlier.rows.map { Row(entry: $0.entry, tools: $0.tools, activity: projected[$0.entry.id]) } + latest
        } else {
            presentedHistory = earlier ?? History(); tail = latest
        }
        let rowsEnded = timestamp()
        let summaryStarted = timestamp()
        let batch = input.summariesEnabled
            ? ActivitySummaryBatch.latest(in: entries, tools: visibleTools,
                projection: narrative, includeToolOutput: input.includeToolOutput)
            : nil
        let summaryEnded = timestamp()
        let value = Snapshot(history: presentedHistory, tail: tail, navigation: navigation, narrative: narrative, batch: batch)
        snapshot = value; preparationCount += 1
        messageCount = input.messages.count
        let retainedCostStarted = timestamp()
        // Token updates preserve historical message values. Reuse their source
        // costs while still comparing full values, including same-ID tool edits.
        let oldCosts = messageCosts
        let reuseEnd = reusedHistory && oldCosts.count >= split! ? split! : 0
        // A page of older messages moves the earlier ones back by its length.
        var shift = 0
        if reuseEnd == 0, let previous, let first = previous.messages.first, input.messages.count > previous.messages.count {
            shift = input.messages.prefix(input.messages.count - previous.messages.count + 1).firstIndex { $0.id == first.id } ?? 0
        }
        var costs = Array(oldCosts[..<reuseEnd])
        costs.reserveCapacity(input.messages.count)
        for index in reuseEnd..<input.messages.count {
            let message = input.messages[index]
            if let previous, previous.messages.indices.contains(index - shift), previous.messages[index - shift] == message {
                costs.append(oldCosts[index - shift])
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
