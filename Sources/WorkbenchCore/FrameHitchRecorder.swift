import Foundation

/// Per-frame hitch accounting for Perch's opt-in performance diagnostics.
///
/// The app's display-link monitor calls `frame(timestamp:duration:scrolling:phase:)`
/// once per callback; instrumented main-thread work calls
/// `work(stage:start:end:detail:)` when it finishes. A frame whose gap since the
/// previous callback exceeds 1.5 × its interval is a hitch: the display showed
/// `round(gap / interval) − 1` refreshes without a new frame from this app. Each
/// hitch is attributed to the recorded work that overlapped its window.
///
/// Times are seconds on one monotonic clock (CACurrentMediaTime in the app). The
/// refresh interval comes from each frame; no rate is assumed. Value type: the
/// app guards one instance with a lock. Foundation only, so the logic is checked
/// on any platform.
public struct FrameHitchRecorder: Sendable {
    /// A frame is a hitch when its gap exceeds this multiple of its interval.
    public static let hitchFactor = 1.5
    /// Gap histogram bucket upper bounds in frame intervals; a bucket holds
    /// gaps above the previous bound up to and including its own. The last
    /// bucket is open.
    public static let intervalBounds: [Double] = [1.5, 3, 6, 12]
    /// Gap histogram bucket upper bounds in milliseconds, same convention.
    public static let millisecondBounds: [Double] = [17, 34, 50, 100, 250, 500, 1_000]
    /// Stages listed per hitch; the rest are summed into `other_stages_ms`.
    public static let stagesPerHitch = 8
    /// Distinct details kept per stage, taken from its longest intervals.
    public static let detailsPerStage = 3

    /// One finished main-thread work interval.
    public struct Work: Equatable, Sendable {
        public let stage: String
        public let start: Double
        public let end: Double
        public let detail: String?
        /// Append order. Between two equal intervals the later one encloses the
        /// earlier: a nested probe finishes before its parent.
        public let sequence: Int
    }

    /// One stage's share of a hitch window.
    public struct StageShare: Codable, Equatable, Sendable {
        public var stage: String
        /// Self time inside the window: nested probes are subtracted, so the
        /// shares of all stages plus `unattributed_ms` add up to the gap.
        public var ms: Double
        /// Including nested probes; overlaps other stages' shares.
        public var inclusiveMS: Double
        /// Intervals of this stage overlapping the window.
        public var count: Int
        public var details: [String]

        enum CodingKeys: String, CodingKey {
            case stage, ms, count, details
            case inclusiveMS = "inclusive_ms"
        }
    }

    public struct Hitch: Codable, Equatable, Sendable {
        /// Window start (the previous frame), in milliseconds after recording start.
        public var startMS: Double
        public var gapMS: Double
        public var intervalMS: Double
        public var missedFrames: Int
        public var scrolling: Bool
        public var phase: String?
        /// The largest stages by self time.
        public var work: [StageShare]
        /// Self time of every overlapping stage, including those beyond `work`.
        public var attributedMS: Double
        public var otherStagesMS: Double
        /// Time in the window that no recorded interval covered.
        public var unattributedMS: Double
        /// The journal had already overwritten intervals that may overlap this window.
        public var journalTruncated: Bool

        enum CodingKeys: String, CodingKey {
            case scrolling, phase, work
            case startMS = "start_ms", gapMS = "gap_ms", intervalMS = "interval_ms"
            case missedFrames = "missed_frames", attributedMS = "attributed_ms"
            case otherStagesMS = "other_stages_ms", unattributedMS = "unattributed_ms"
            case journalTruncated = "journal_truncated"
        }
    }

    /// One stage summed over every hitch, not only the retained worst ones.
    public struct Blame: Codable, Equatable, Sendable {
        public var stage: String
        public var ms: Double
        public var inclusiveMS: Double
        public var hitches: Int

        enum CodingKeys: String, CodingKey {
            case stage, ms, hitches
            case inclusiveMS = "inclusive_ms"
        }
    }

    /// Gaps with `lower < gap <= upper`; `upper` is absent on the open last bucket.
    public struct Bucket: Codable, Equatable, Sendable {
        public var lower: Double
        public var upper: Double?
        public var count: Int
    }

    public struct Histogram: Codable, Equatable, Sendable {
        /// In multiples of each frame's own interval.
        public var byInterval: [Bucket]
        public var byMS: [Bucket]

        enum CodingKeys: String, CodingKey {
            case byInterval = "by_interval", byMS = "by_ms"
        }
    }

    public struct Counters: Codable, Equatable, Sendable {
        /// Frames with a measured gap; the first frame of each chain only sets a baseline.
        public var observed = 0
        public var scrolling = 0
        public var hitches = 0
        public var scrollingHitches = 0
        public var missedFrames = 0
        public var scrollingMissedFrames = 0

        enum CodingKeys: String, CodingKey {
            case observed, scrolling, hitches
            case scrollingHitches = "scrolling_hitches", missedFrames = "missed_frames"
            case scrollingMissedFrames = "scrolling_missed_frames"
        }
    }

    public struct DisplayInterval: Codable, Equatable, Sendable {
        public var last: Double
        public var min: Double
        public var max: Double
    }

    public struct Journal: Codable, Equatable, Sendable {
        public var capacity: Int
        public var recorded: Int
        public var retained: Int
        public var dropped: Int
    }

    public struct Report: Codable, Equatable, Sendable {
        /// From recording start to the latest frame or interval seen.
        public var recordingMS: Double
        public var displayIntervalMS: DisplayInterval?
        public var counters: Counters
        public var gapHistogram: Histogram
        /// Largest gaps first.
        public var worstHitches: [Hitch]
        /// Largest self time first.
        public var blame: [Blame]
        /// Summed over every hitch.
        public var unattributedMS: Double
        public var journal: Journal

        enum CodingKeys: String, CodingKey {
            case counters, blame, journal
            case recordingMS = "recording_ms", displayIntervalMS = "display_interval_ms"
            case gapHistogram = "gap_histogram", worstHitches = "worst_hitches"
            case unattributedMS = "unattributed_ms"
        }
    }

    private struct BlameTotal: Sendable {
        var own = 0.0
        var inclusive = 0.0
        var hitches = 0
    }

    public let journalCapacity: Int
    public let worstCapacity: Int
    /// Recording start; set by the first frame or interval when not given.
    public private(set) var origin: Double?
    private var previous: Double?
    private var latest: Double?
    private var interval: DisplayInterval?
    private var counters = Counters()
    private var byInterval: [Int]
    private var byMS: [Int]
    private var worst: [Hitch] = []
    private var blame: [String: BlameTotal] = [:]
    private var unattributed = 0.0
    private var journal: [Work] = []
    /// Oldest entry once the ring is full.
    private var journalHead = 0
    private var journalRecorded = 0

    public init(origin: Double? = nil, journalCapacity: Int = 1_024, worstCapacity: Int = 60) {
        self.origin = origin
        self.journalCapacity = Swift.max(1, journalCapacity)
        self.worstCapacity = Swift.max(1, worstCapacity)
        byInterval = Array(repeating: 0, count: Self.intervalBounds.count + 1)
        byMS = Array(repeating: 0, count: Self.millisecondBounds.count + 1)
    }

    public var isEmpty: Bool { counters.observed == 0 && journalRecorded == 0 }

    /// Retained intervals, oldest first.
    public var retainedWork: [Work] {
        journal.count < journalCapacity ? journal : Array(journal[journalHead...] + journal[..<journalHead])
    }

    /// The next frame only sets a baseline. Call when the frame source restarts
    /// (activation, screen change, wake): the pause before it is not a hitch.
    public mutating func breakChain() {
        previous = nil
    }

    /// Records one finished main-thread interval. Intervals are expected in the
    /// order they finish, which is how probes on one thread produce them.
    public mutating func work(stage: String, start: Double, end: Double, detail: String? = nil) {
        guard start.isFinite, end.isFinite, end >= start else { return }
        if origin == nil { origin = start }
        latest = Swift.max(latest ?? end, end)
        let entry = Work(stage: stage, start: start, end: end, detail: detail, sequence: journalRecorded)
        journalRecorded += 1
        if journal.count < journalCapacity {
            journal.append(entry)
        } else {
            journal[journalHead] = entry
            journalHead = (journalHead + 1) % journalCapacity
        }
    }

    /// Records one display-link callback. `duration` is the frame's own interval
    /// (target timestamp − timestamp). Returns the hitch this frame ended, if any.
    @discardableResult
    public mutating func frame(timestamp: Double, duration: Double, scrolling: Bool, phase: String? = nil) -> Hitch? {
        guard timestamp.isFinite else { return nil }
        if origin == nil { origin = timestamp }
        latest = Swift.max(latest ?? timestamp, timestamp)
        guard let start = previous else {
            previous = timestamp
            return nil
        }
        // A repeated or out-of-order callback carries no new frame.
        guard timestamp > start else { return nil }
        previous = timestamp
        guard duration.isFinite, duration > 0 else { return nil }
        noteInterval(duration)
        let gap = timestamp - start
        let ratio = gap / duration
        counters.observed += 1
        if scrolling { counters.scrolling += 1 }
        byInterval[Self.bucket(ratio, Self.intervalBounds)] += 1
        byMS[Self.bucket(gap * 1_000, Self.millisecondBounds)] += 1
        guard ratio > Self.hitchFactor else { return nil }
        let missed = Swift.max(1, Int(ratio.rounded()) - 1)
        counters.hitches += 1
        counters.missedFrames += missed
        if scrolling {
            counters.scrollingHitches += 1
            counters.scrollingMissedFrames += missed
        }
        let attribution = attribute(from: start, to: timestamp)
        unattributed += attribution.unattributed
        var attributed = 0.0
        for share in attribution.shares {
            attributed += share.own
            var total = blame[share.stage] ?? BlameTotal()
            total.own += share.own
            total.inclusive += share.inclusive
            total.hitches += 1
            blame[share.stage] = total
        }
        let listed = attribution.shares.prefix(Self.stagesPerHitch)
        let hitch = Hitch(
            startMS: Self.ms(start - (origin ?? start)), gapMS: Self.ms(gap), intervalMS: Self.ms(duration),
            missedFrames: missed, scrolling: scrolling, phase: phase,
            work: listed.map {
                StageShare(stage: $0.stage, ms: Self.ms($0.own), inclusiveMS: Self.ms($0.inclusive),
                           count: $0.count, details: $0.details)
            },
            attributedMS: Self.ms(attributed),
            otherStagesMS: Self.ms(attribution.shares.dropFirst(Self.stagesPerHitch).reduce(0) { $0 + $1.own }),
            unattributedMS: Self.ms(attribution.unattributed), journalTruncated: attribution.truncated)
        keep(hitch)
        return hitch
    }

    public func report() -> Report {
        let base = origin ?? 0
        let hitches = worst.sorted { $0.gapMS != $1.gapMS ? $0.gapMS > $1.gapMS : $0.startMS < $1.startMS }
        let stages = blame.map { Blame(stage: $0.key, ms: Self.ms($0.value.own), inclusiveMS: Self.ms($0.value.inclusive),
                                       hitches: $0.value.hitches) }
            .sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.stage < $1.stage }
        return Report(
            recordingMS: Self.ms(Swift.max(0, (latest ?? base) - base)),
            displayIntervalMS: interval.map { DisplayInterval(last: Self.ms($0.last), min: Self.ms($0.min), max: Self.ms($0.max)) },
            counters: counters,
            gapHistogram: Histogram(byInterval: Self.buckets(byInterval, Self.intervalBounds),
                                    byMS: Self.buckets(byMS, Self.millisecondBounds)),
            worstHitches: hitches, blame: stages, unattributedMS: Self.ms(unattributed),
            journal: Journal(capacity: journalCapacity, recorded: journalRecorded, retained: journal.count,
                             dropped: journalRecorded - journal.count))
    }

    // MARK: Attribution

    private struct Share {
        let stage: String
        var own = 0.0
        var inclusive = 0.0
        var count = 0
        var details: [String] = []
    }

    private struct Attribution {
        var shares: [Share]
        var unattributed: Double
        var truncated: Bool
    }

    /// Clips the journal to (start, end], gives each interval its self time
    /// (nested intervals subtracted) and sums per stage, largest first.
    private func attribute(from start: Double, to end: Double) -> Attribution {
        struct Piece {
            let stage: String
            let detail: String?
            let start: Double
            let end: Double
            let sequence: Int
            var own: Double
        }
        var pieces: [Piece] = []
        for entry in journal where entry.end > start && entry.start < end {
            let clippedStart = Swift.max(entry.start, start), clippedEnd = Swift.min(entry.end, end)
            guard clippedEnd > clippedStart else { continue }
            pieces.append(Piece(stage: entry.stage, detail: entry.detail, start: clippedStart, end: clippedEnd,
                                sequence: entry.sequence, own: clippedEnd - clippedStart))
        }
        // An enclosing interval sorts before everything it contains.
        pieces.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return $0.sequence > $1.sequence
        }
        var open: [Int] = []
        var covered = 0.0
        var coveredEnd = -Double.infinity
        for index in pieces.indices {
            let piece = pieces[index]
            while let top = open.last, pieces[top].end <= piece.start { open.removeLast() }
            // Probes on one thread nest; a partial overlap (an interval spanning a
            // suspension point) is left whole rather than guessed apart.
            if let top = open.last, pieces[top].end >= piece.end {
                pieces[top].own -= piece.end - piece.start
            }
            open.append(index)
            if piece.end > coveredEnd {
                covered += piece.end - Swift.max(piece.start, coveredEnd)
                coveredEnd = piece.end
            }
        }
        var byStage: [String: Share] = [:]
        var ranked: [String: [(length: Double, detail: String)]] = [:]
        for piece in pieces {
            var share = byStage[piece.stage] ?? Share(stage: piece.stage)
            share.own += Swift.max(0, piece.own)
            share.inclusive += piece.end - piece.start
            share.count += 1
            byStage[piece.stage] = share
            if let detail = piece.detail { ranked[piece.stage, default: []].append((piece.end - piece.start, detail)) }
        }
        for (stage, details) in ranked {
            var distinct: [String] = []
            for item in details.sorted(by: { $0.length > $1.length }) where !distinct.contains(item.detail) {
                distinct.append(item.detail)
                if distinct.count == Self.detailsPerStage { break }
            }
            byStage[stage]?.details = distinct
        }
        let shares = byStage.values.sorted {
            if $0.own != $1.own { return $0.own > $1.own }
            if $0.inclusive != $1.inclusive { return $0.inclusive > $1.inclusive }
            return $0.stage < $1.stage
        }
        // Entries finish in order, so anything overwritten ended no later than
        // the oldest retained entry.
        let wrapped = journalRecorded > journal.count
        let truncated = wrapped && journal[journalHead].end > start
        return Attribution(shares: shares, unattributed: Swift.max(0, (end - start) - covered), truncated: truncated)
    }

    // MARK: Helpers

    private mutating func noteInterval(_ duration: Double) {
        if let current = interval {
            interval = DisplayInterval(last: duration, min: Swift.min(current.min, duration), max: Swift.max(current.max, duration))
        } else {
            interval = DisplayInterval(last: duration, min: duration, max: duration)
        }
    }

    private mutating func keep(_ hitch: Hitch) {
        guard worst.count >= worstCapacity else {
            worst.append(hitch)
            return
        }
        guard let smallest = worst.indices.min(by: { worst[$0].gapMS < worst[$1].gapMS }),
              worst[smallest].gapMS < hitch.gapMS else { return }
        worst[smallest] = hitch
    }

    private static func bucket(_ value: Double, _ bounds: [Double]) -> Int {
        bounds.firstIndex { value <= $0 } ?? bounds.count
    }

    private static func buckets(_ counts: [Int], _ bounds: [Double]) -> [Bucket] {
        counts.indices.map { index in
            Bucket(lower: index == 0 ? 0 : bounds[index - 1], upper: index < bounds.count ? bounds[index] : nil,
                   count: counts[index])
        }
    }

    /// Seconds to milliseconds at 0.01 ms resolution.
    static func ms(_ seconds: Double) -> Double {
        (seconds * 100_000).rounded() / 100
    }
}
