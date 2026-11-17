import Foundation

public enum ActivityNarrativePhase: String, Codable, CaseIterable, Hashable, Sendable {
    case exploring, editing, validating, integrating, blocked, mixed

    public var label: String {
        switch self {
        case .exploring: return L("探索")
        case .editing: return L("修改")
        case .validating: return L("验证")
        case .integrating: return L("整合")
        case .blocked: return L("受阻")
        case .mixed: return L("推进")
        }
    }
}

public enum ActivityNarrativeSource: String, Codable, Sendable {
    case provider, commentary, external, local

    public var label: String {
        switch self {
        case .provider: return L("模型原生摘要")
        case .commentary: return L("Agent 进度")
        case .external: return L("外部摘要")
        case .local: return L("本地推断")
        }
    }
}

public enum ActivityNarrativeLifecycle: String, Codable, Sendable {
    case streaming, final
}

/// Bounded memo for the projection's pure text derivations. Streaming updates
/// revisit the same unchanged entries thousands of times; only the live tail
/// produces new strings. Eviction clears all, which costs one recompute and never
/// changes results. Entry steps are addressed by entry id, so they live in a
/// per-conversation instance; the content-addressed text tables are shared.
public final class NarrativeTextCache: @unchecked Sendable {
    /// Shared content-addressed text tables.
    private static let textLock = NSLock()
    private static var phases: [String: ActivityNarrativePhase] = [:]
    private static var cleaned: [String: String] = [:]
    private static var narratives: [String: (headline: String, detail: String?)] = [:]

    public init() {}
    private let lock = NSLock()
    private var steps: [String: ([KimiMessage], ConversationTimelineEntry.Presentation, [NarrativeStep])] = [:]

    private static func value<V>(_ table: inout [String: V], _ key: String, _ make: () -> V) -> V {
        textLock.lock()
        if let hit = table[key] { textLock.unlock(); return hit }
        textLock.unlock()
        let value = make()
        textLock.lock()
        if table.count > 8192 { table.removeAll() }
        table[key] = value
        textLock.unlock()
        return value
    }

    static func phase(for text: String, _ make: () -> ActivityNarrativePhase) -> ActivityNarrativePhase {
        value(&phases, text, make)
    }
    static func clean(_ text: String, limit: Int?, _ make: () -> String) -> String {
        value(&cleaned, "\(limit ?? -1)\u{1}\(text)", make)
    }
    static func narrativeText(_ text: String, _ make: () -> (headline: String, detail: String?)) -> (headline: String, detail: String?) {
        value(&narratives, text, make)
    }

    /// One tool step's pure resolution against the live tool table: everything
    /// `make` derives from the VisibleTool value alone (phase, compact target,
    /// shell headline, incidental flag). The stage-assembly decisions around it
    /// depend on prior stages and are NOT part of the resolution.
    struct ToolResolution: Equatable, Sendable {
        let phase: ActivityNarrativePhase
        let target: String
        let headline: String
        let incidental: Bool
    }

    private var toolResolutions: [String: (tool: VisibleTool, language: String, resolution: ToolResolution)] = [:]

    /// A tool step's resolution, reusable while the tool VALUE and the UI
    /// language are unchanged. Streaming deltas revisit every completed tool
    /// of the live turn on each update while only the running tool's value
    /// moves; the full-value check (same doctrine as steps(for:)) recomputes
    /// exactly when status, input, output or progress moved. Unlike steps,
    /// the resolution embeds LOCALIZED strings (phase.label, shell headlines,
    /// L() fallbacks read AppLanguage.current at derive time), so the entry
    /// also records the language token and misses when it moved — a
    /// language switch re-derives every resolution (review F1; token
    /// semantics: see the capture site in make()).
    func resolution(for tool: VisibleTool, language: String, derive: () -> ToolResolution) -> ToolResolution {
        lock.lock()
        if let hit = toolResolutions[tool.id], hit.tool == tool, hit.language == language {
            lock.unlock(); return hit.resolution
        }
        lock.unlock()
        let derived = derive()
        lock.lock()
        if toolResolutions.count > 65536 { toolResolutions.removeAll() }
        toolResolutions[tool.id] = (tool, language, derived)
        lock.unlock()
        return derived
    }

    /// Drop every tool resolution (localized strings) while keeping the
    /// language-neutral steps and text tables. Called on the model's
    /// language/epoch reset. Load-bearing layer 2 of the F1 guard: a
    /// system-language change under the .system setting does not move the
    /// raw-value token, but it does move Input.language (locale + resolved
    /// localization), which fires the reset that calls this. Layer 1 is the
    /// per-entry token in resolution(for:language:).
    func invalidateToolResolutions() {
        lock.lock()
        toolResolutions.removeAll()
        lock.unlock()
    }

    /// An entry's ordered fold steps, reusable while the entry's messages and
    /// presentation are unchanged. Full values, not an id hash, are the validation:
    /// a reused id with edited content or a running state change must recompute.
    func steps(for entry: ConversationTimelineEntry, derive: () -> [NarrativeStep]) -> [NarrativeStep] {
        lock.lock()
        if let (messages, presentation, steps) = steps[entry.id],
           messages == entry.messages, presentation == entry.presentation { lock.unlock(); return steps }
        lock.unlock()
        let derived = derive()
        lock.lock()
        if steps.count > 65536 { steps.removeAll() }
        steps[entry.id] = (entry.messages, entry.presentation, derived)
        lock.unlock()
        return derived
    }

    /// Round 41: per-entry incremental commentary derivations, keyed like
    /// steps by entry id. Runs under the instance lock; the only nested lock
    /// is the static text tables' (steps' derive closure runs UNLOCKED, so
    /// the ordering is one-way). Eviction mirrors steps: clearing costs one
    /// reseed and never changes results.
    private var commentaryStates: [String: CommentaryDerivation] = [:]
    /// Anti-blind counter for the pins: observations that produced an
    /// incremental step (as opposed to a from-scratch fallback).
    public private(set) var commentaryObservations = 0
    /// Pin infrastructure (public because the checks binary compiles without
    /// testability in the release A/B protocol): disables the incremental
    /// derivator so the differential fuzz (checkCommentaryDerivation) can run
    /// the from-scratch path through the very same make() code as its oracle.
    /// Never set in product code.
    public var commentaryDerivationDisabled = false

    func commentary(entryID: String, parts: [String], firstMessageID: String) -> CommentaryDerivation.Outcome {
        guard !commentaryDerivationDisabled else { return .fallback }
        lock.lock()
        defer { lock.unlock() }
        let derivation = commentaryStates[entryID] ?? CommentaryDerivation()
        let outcome = derivation.observe(parts: parts, firstMessageID: firstMessageID)
        if commentaryStates.count > 65536 { commentaryStates.removeAll() }
        commentaryStates[entryID] = derivation
        if case .step = outcome { commentaryObservations += 1 }
        return outcome
    }

    /// Pin introspection (anti-blind): one entry's derivation vitals.
    public func commentaryStats(entryID: String) -> (observations: Int, phaseCommittedBytes: Int,
                                              delimFrontier: Int, strict: Bool, reseeds: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let derivation = commentaryStates[entryID] else { return nil }
        return (derivation.observations, derivation.phaseCommittedBytes, derivation.delimFrontier,
                derivation.strict, derivation.reseedCount)
    }
}

/// One entry's ordered contribution to the narrative fold. Text work happens at
/// derive time; tool steps resolve against the live tool table when applied.
/// `precleaned` marks stage steps whose headline/detail already carry the
/// assembly's clean() (round 41: the commentary derivator computes the exact
/// same final values incrementally; every other producer keeps the re-clean).
enum NarrativeStep {
    case stage(id: String, phase: ActivityNarrativePhase, subject: String, headline: String,
               detail: String?, source: ActivityNarrativeSource, lifecycle: ActivityNarrativeLifecycle,
               precleaned: Bool = false)
    case thinkingPlaceholder(messageID: String)
    case tool(KimiPart)
}

public struct ActivityNarrative: Equatable, Sendable {
    public let turnID: String
    public let stageID: String
    public let phase: ActivityNarrativePhase
    public let subject: String
    public let headline: String
    public let detail: String?
    public let source: ActivityNarrativeSource
    public let evidenceIDs: [String]
    public let lifecycle: ActivityNarrativeLifecycle
    public let revision: Int

    public init(turnID: String, stageID: String, phase: ActivityNarrativePhase,
                subject: String = "", headline: String, detail: String? = nil,
                source: ActivityNarrativeSource, evidenceIDs: [String] = [],
                lifecycle: ActivityNarrativeLifecycle, revision: Int = 0) {
        self.turnID = turnID
        self.stageID = stageID
        self.phase = phase
        self.subject = subject
        self.headline = headline
        self.detail = detail
        self.source = source
        self.evidenceIDs = evidenceIDs
        self.lifecycle = lifecycle
        self.revision = revision
    }
}

public struct ActivityNarrativeStage: Equatable, Sendable {
    public let narrative: ActivityNarrative
    public let entryIDs: [String]
    public let toolIDs: [String]
    public let closed: Bool
}

public struct ActivityNarrativeRow: Equatable, Sendable {
    public let narrative: ActivityNarrative
    public let isAnchor: Bool
    public let stageClosed: Bool

    public init(narrative: ActivityNarrative, isAnchor: Bool, stageClosed: Bool) {
        self.narrative = narrative
        self.isAnchor = isAnchor
        self.stageClosed = stageClosed
    }
}

public struct ActivityNarrativeSnapshot: Equatable, Sendable {
    public let turnID: String?
    public let stages: [ActivityNarrativeStage]
    public let entryStageIDs: [String: String]

    public init(turnID: String?, stages: [ActivityNarrativeStage], entryStageIDs: [String: String]) {
        self.turnID = turnID
        self.stages = stages
        self.entryStageIDs = entryStageIDs
    }

    public var current: ActivityNarrative? { stages.last?.narrative }
    public var rows: [String: ActivityNarrativeRow] {
        stages.reduce(into: [:]) { result, stage in
            for (index, entryID) in stage.entryIDs.enumerated() {
                result[entryID] = ActivityNarrativeRow(
                    narrative: stage.narrative, isAnchor: index == 0, stageClosed: stage.closed)
            }
        }
    }
    public func row(for entryID: String) -> ActivityNarrativeRow? { rows[entryID] }
    public func narrative(for entryID: String) -> ActivityNarrative? { row(for: entryID)?.narrative }

    public func applying(_ external: [String: ActivitySummaryResult]) -> Self {
        let updated = stages.map { stage -> ActivityNarrativeStage in
            guard stage.narrative.source == .local,
                  let result = external[stage.narrative.stageID], result.shouldUpdate else { return stage }
            let headline = Self.clean(result.summary)
            guard !headline.isEmpty else { return stage }
            let narrative = ActivityNarrative(
                turnID: stage.narrative.turnID, stageID: stage.narrative.stageID,
                phase: result.phase, subject: Self.clean(result.subject, limit: 80),
                headline: headline, detail: stage.narrative.detail, source: .external,
                evidenceIDs: result.evidenceIDs.filter(stage.toolIDs.contains),
                lifecycle: stage.closed ? .final : .streaming,
                revision: stage.narrative.revision + 1)
            return ActivityNarrativeStage(narrative: narrative, entryIDs: stage.entryIDs,
                                          toolIDs: stage.toolIDs, closed: stage.closed)
        }
        return Self(turnID: turnID, stages: updated, entryStageIDs: entryStageIDs)
    }

    fileprivate static func clean(_ value: String, limit: Int? = nil) -> String {
        NarrativeTextCache.clean(value, limit: limit) {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in ["### ", "## ", "# ", "**"] where text.hasPrefix(marker) {
                text.removeFirst(marker.count)
                if marker == "**" { text = text.replacingOccurrences(of: "**", with: "") }
                break
            }
            text = text.collapsedWhitespace
            text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ":：")))
            guard let limit, text.count > limit else { return text }
            return String(text.prefix(limit - 1)) + "…"
        }
    }

    /// Separator literals with their exact UTF-8 bytes; the patterns and the
    /// strings must stay in sync (the pin re-derives the bytes from the
    /// strings and asserts equality).
    private static let narrativeSeparators: [(text: String, bytes: [UInt8])] = [
        ("：", [0xEF, 0xBC, 0x9A]),
        (": ", [0x3A, 0x20]),
    ]

    fileprivate static func narrativeText(_ value: String) -> (headline: String, detail: String?) {
        NarrativeTextCache.narrativeText(value) {
            let text = clean(value)
            for separator in narrativeSeparators {
                // Round 26: byte-level first-occurrence search with a two-sided
                // grapheme-boundary proof; falls back to the original grapheme-
                // aware range(of:) whenever a boundary is unprovable, so the
                // result is identical on every input (NarrativeDelimiterScan).
                let range: Range<String.Index>?
                switch NarrativeDelimiterScan.firstOccurrence(in: text, pattern: separator.bytes) {
                case .match(let byteRange):
                    let view = text.utf8
                    range = view.index(view.startIndex, offsetBy: byteRange.lowerBound)
                        ..< view.index(view.startIndex, offsetBy: byteRange.upperBound)
                case .absent:
                    range = nil
                case .inconclusive:
                    range = text.range(of: separator.text)
                }
                guard let range else { continue }
                let headline = clean(String(text[..<range.lowerBound]), limit: 80)
                let detail = clean(String(text[range.upperBound...]))
                if !headline.isEmpty, headline.count <= 48, !detail.isEmpty {
                    return (headline, detail)
                }
            }
            return (text, nil)
        }
    }
}


/// Round 26: byte-level first-occurrence search for the two `narrativeText`
/// separators (U+FF1A and ": "), replacing two grapheme-aware `range(of:)`
/// full-text searches per cache miss on the streaming progress derivation
/// path (long-tail bench tails are unique per update, i.e. miss-heavy).
///
/// Equivalence argument (round-17/22 boundary-proof playbook):
/// 1. **No false positions.** UTF-8 self-synchronization: the pattern bytes
///    (EF BC 9A / 3A 20) can only occur at scalar boundaries inside valid
///    UTF-8, so a byte match is always a whole-scalar occurrence.
/// 2. **No false positives.** Boundary-proven occurrences are accepted by
///    the original search. This proof is sufficient, not necessary;
///    corelibs' GB9b behavior (Linux `range(of:)` can match inside a
///    Prepend-fused cluster) remains delegated to `range(of:)`. A byte
///    occurrence is proven when (a) no Prepend scalar precedes it (GB9b
///    would absorb it into the previous cluster) and (b) no binding scalar
///    follows it (Extend/ZWJ/SpacingMark/pinned fusers would absorb it into
///    the next cluster). All Prepend and binding scalars are non-ASCII, so
///    an ASCII preceding byte (or the string start) proves the preceding
///    boundary outright; non-ASCII predecessors are decided by the pinned
///    exhaustive set `String.isPrependScalar`. The following boundary is
///    delegated to `String.beginsBindingMark`, whose completeness is pinned
///    by the round-24 `fusionGap == 0` walk — but it only decodes non-ASCII
///    scalars, so ASCII successors currently fall back conservatively
///    (review F8: no binding class contains ASCII, so the hit path has
///    unexploited headroom there; queued as a future candidate, unmeasured).
///    Unprovable boundaries yield `.inconclusive` and the caller falls back
///    to the original `range(of:)`, so legacy semantics decide exactly where
///    the proof does not reach.
/// 3. **No false negatives.** An exhaustive operational canonical-equivalence
///    sweep (all 1,112,064 scalars, both toolchains, 2026-11-16; pinned in
///    checkNarrativeDelimiterScan) found ZERO scalars canonically equal to
///    U+FF1A, U+003A or U+0020 other than themselves, so no separator
///    occurrence can hide behind different bytes; multi-scalar sequences
///    cannot compose the atoms either (canonical decomposition acts per
///    scalar; a combining mark cannot cancel into ":" or " " — round-22's
///    multi-scalar composition argument). `.absent` therefore implies
///    `range(of:)` would also find nothing.
/// 4. **First-match identity.** The scan inspects byte occurrences in order;
///    the FIRST confirmed occurrence is necessarily the first grapheme match
///    (an earlier grapheme match would be an earlier byte occurrence). The
///    first inconclusive occurrence defers the whole decision to `range(of:)`.
private enum NarrativeDelimiterScan {
    enum Outcome {
        /// Byte range of the first boundary-proven occurrence.
        case match(Range<Int>)
        /// No byte occurrence at all; range(of:) would find none either.
        case absent
        /// Boundary unprovable at the first occurrence; caller must use range(of:).
        case inconclusive
    }

    static func firstOccurrence(in text: String, pattern: [UInt8]) -> Outcome {
        var contiguous = text
        return contiguous.withUTF8 { bytes in
            let n = bytes.count
            let m = pattern.count
            guard m > 0, n >= m else { return .absent }
            var offset = 0
            while offset + m <= n {
                if bytes[offset] != pattern[0] { offset += 1; continue }
                var k = 1
                while k < m, bytes[offset + k] == pattern[k] { k += 1 }
                if k < m { offset += 1; continue }
                let lower = offset
                let upper = offset + m
                // Preceding boundary (GB9b): only Prepend scalars fuse forward
                // over the separator, and all are non-ASCII — an ASCII
                // preceding byte or the string start proves safety.
                if lower > 0, bytes[lower - 1] >= 0x80 {
                    guard let previous = precedingScalar(in: bytes, before: lower),
                          !String.isPrependScalar(previous) else { return .inconclusive }
                }
                // Following boundary: any scalar that binds onto the previous
                // character (Extend/ZWJ/Mn/Mc/Me plus the round-24 pinned
                // fusers) would absorb the separator's last character.
                // beginsBindingMark decodes only non-ASCII scalars and answers
                // true (conservative) for ASCII, so ASCII successors currently
                // take the range(of:) fallback even though no binding class
                // contains ASCII (review F8; safe, unexploited headroom).
                if upper < n, String.beginsBindingMark(in: bytes, at: upper) {
                    return .inconclusive
                }
                return .match(lower..<upper)
            }
            return .absent
        }
    }

    /// Decodes the scalar ending exactly at `index`; nil on any malformed or
    /// unexpected shape (nil forces the safe `.inconclusive` fallback).
    /// Fileprivate since round 41: the commentary derivator's incremental
    /// delimiter scan reuses this exact preceding-boundary proof.
    fileprivate static func precedingScalar(in bytes: UnsafeBufferPointer<UInt8>, before index: Int) -> UInt32? {
        var start = index - 1
        var walked = 0
        while start > 0, bytes[start] & 0xC0 == 0x80 {
            start -= 1
            walked += 1
            if walked > 3 { return nil }
        }
        let lead = bytes[start]
        let length: Int
        var value: UInt32
        switch lead {
        case 0x00...0x7F:
            if start + 1 != index { return nil }
            return UInt32(lead)
        case 0xC2...0xDF:
            length = 2; value = UInt32(lead & 0x1F)
        case 0xE0...0xEF:
            length = 3; value = UInt32(lead & 0x0F)
        case 0xF0...0xF4:
            length = 4; value = UInt32(lead & 0x07)
        default:
            return nil
        }
        guard start + length == index else { return nil }
        for i in (start + 1)..<index {
            guard bytes[i] & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt32(bytes[i] & 0x3F)
        }
        guard Unicode.Scalar(value) != nil else { return nil }
        return value
    }
}

/// Round 22: single-pass byte-level multi-pattern scan replacing the phase
/// closure's `lowercased()` full-text copy plus up to 32 grapheme-aware
/// `contains` substring searches. Attribution (miss-heavy KB-scale long-tail
/// profile at 68b0ce4 state, round-21 archive): the phase derivation closure
/// was 54.61% of the narrative stage on the base product (73.36% after the
/// table machinery shrank), and the bench's keyword-free tails execute ALL
/// 32 predicates per derive — 32 full-text canonical searches per delta of a
/// growing reply.
///
/// Equivalence (pinned by checkNarrativePhaseSinglePass: exhaustive scalar
/// bridge sweep + differential fuzz against the reference predicate chain +
/// the unchanged narrative golden):
/// - A byte match with BOTH boundaries proven (preceding byte ASCII or start;
///   following byte ASCII or end — every Prepend/Extend/SpacingMark/ZWJ
///   scalar is non-ASCII, round-17 two-sided boundary technique) implies the
///   keyword's characters are their own graphemes in a contiguous run, so the
///   old `lowercased().contains(keyword)` necessarily matched: no false
///   positives.
/// - A boundary-inconclusive match defers to the ORIGINAL canonical predicate
///   (lowercased + substring contains), computed lazily only for the affected
///   keywords — GB9b fusion (e.g. U+0600 before, combining mark after) can
///   make the old search miss, so the old behavior decides exactly as before.
/// - No false negatives from casing: an old match requires the keyword's
///   characters contiguous in the lowercased text; ASCII keywords can only
///   gain bytes from lowercasing via non-ASCII scalars lowercasing to ASCII —
///   the exhaustive sweep pins U+212A ('k') as the ONLY such bridge and no
///   keyword contains 'k'.
/// - No false negatives from normalization (review F1 counterexamples):
///   canonical substring search folds CJK COMPATIBILITY ideographs to their
///   canonical equivalents (U+FA55→突, U+FA8E→搜, U+F96A→索), so texts like
///   "冲\u{FA55}" match 冲突 under the old predicate while no literal keyword
///   bytes exist. The scan therefore detects the UTF-8 lead patterns of the
///   three blocks carrying canonical decompositions to ideographs —
///   U+2F00–2FFF (E2 BC..BF, Kangxi, conservative), U+F900–FAFF (EF A4..AB),
///   U+2F800–2FFFF (F0 AF, conservative) — and defers the WHOLE text to the
///   legacy chain. Corrected probe evidence (re-review F1', byte-level
///   comparison on both platforms): canonical decomposition DOES change the
///   bytes of these scalars (460 byte-changing scalars in U+F900–FAFF;
///   U+FA55→U+7A81, U+FA8E→U+641C, U+F96A→U+7D22) and contains() folds
///   them on both platforms. The completeness pin is nonetheless the
///   OPERATIONAL canonical-equality sweep (String's canonical == via Set
///   membership over all 1,112,064 scalars — the same equality the legacy
///   search relies on, independent of decomposition-API behavior): exactly
///   three scalars are canonically equal to a keyword character
///   (U+FA55/U+FA8E/U+F96A), all inside the detected ranges.
private enum NarrativePhaseScan {
    /// Priority order matches the replaced if-chain: validating, editing,
    /// integrating, exploring.
    static let keywords: [(text: String, phase: ActivityNarrativePhase)] = [
        ("test", .validating), ("build", .validating), ("lint", .validating), ("verify", .validating),
        ("测试", .validating), ("构建", .validating), ("验证", .validating), ("检查", .validating), // l10n-ignore
        ("edit", .editing), ("implement", .editing), ("write", .editing), ("fix", .editing),
        ("修改", .editing), ("实现", .editing), ("修复", .editing), ("编写", .editing), // l10n-ignore
        ("git", .integrating), ("commit", .integrating), ("merge", .integrating), ("integrat", .integrating),
        ("提交", .integrating), ("合并", .integrating), ("整合", .integrating), ("冲突", .integrating), // l10n-ignore
        ("read", .exploring), ("search", .exploring), ("inspect", .exploring), ("explor", .exploring),
        ("读取", .exploring), ("搜索", .exploring), ("查看", .exploring), ("分析", .exploring), // l10n-ignore
    ]
    static let keywordBytes: [[UInt8]] = keywords.map { Array($0.text.utf8) }
    /// Case-folded first-byte dispatch. ASCII letters fold; bytes >= 0x80
    /// (CJK leads) index their own bucket unfolded.
    static let buckets: [[Int]] = {
        var table = [[Int]](repeating: [], count: 256)
        for (index, bytes) in keywordBytes.enumerated() {
            table[Int(fold(bytes[0]))].append(index)
        }
        return table
    }()
    static func fold(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    /// The replaced predicate chain, verbatim — the authoritative decision
    /// for texts containing CJK compatibility ideographs (review F1), and
    /// the source of the per-keyword fallback predicate below.
    static func legacyPhase(_ text: String) -> ActivityNarrativePhase {
        let value = text.lowercased()
        if value.contains("test") || value.contains("build") || value.contains("lint") || value.contains("verify")
            || value.contains("测试") || value.contains("构建") || value.contains("验证") || value.contains("检查") { return .validating } // l10n-ignore
        if value.contains("edit") || value.contains("implement") || value.contains("write") || value.contains("fix")
            || value.contains("修改") || value.contains("实现") || value.contains("修复") || value.contains("编写") { return .editing } // l10n-ignore
        if value.contains("git") || value.contains("commit") || value.contains("merge") || value.contains("integrat")
            || value.contains("提交") || value.contains("合并") || value.contains("整合") || value.contains("冲突") { return .integrating } // l10n-ignore
        if value.contains("read") || value.contains("search") || value.contains("inspect") || value.contains("explor")
            || value.contains("读取") || value.contains("搜索") || value.contains("查看") || value.contains("分析") { return .exploring } // l10n-ignore
        return .mixed
    }

    /// Round 41: resumable scan state. The commentary derivator commits bytes
    /// up to a holdback frontier and replays the tail per observation; results
    /// committed below the frontier are count-invariant, because the
    /// trailing-at-end-of-text rule and the compatibility lookahead can only
    /// fire within `maxKeywordBytes + 1` of the end and both proofs below the
    /// frontier read real, immutable bytes. `phase(in:)` scans in one call
    /// with limit == count == buffer length, so its behavior is unchanged.
    struct ScanState {
        var offset = 0
        var confirmedValidating = false
        var confirmedEditing = false
        var confirmedIntegrating = false
        var confirmedExploring = false
        var inconclusive = [Bool](repeating: false, count: keywords.count)
        var compatibilityDetected = false
    }

    static let maxKeywordBytes = keywordBytes.reduce(0) { max($0, $1.count) }

    /// Scans `bytes[state.offset..<limit]` against a logical text of length
    /// `count` (`state.offset <= limit <= count <= bytes.count`). Same loop
    /// body, in the same order, as the pre-round-41 monolithic scan.
    static func scan(_ state: inout ScanState, _ bytes: UnsafeBufferPointer<UInt8>, limit: Int, count: Int) {
        var offset = state.offset
        var confirmedValidating = state.confirmedValidating
        var confirmedEditing = state.confirmedEditing
        var confirmedIntegrating = state.confirmedIntegrating
        var confirmedExploring = state.confirmedExploring
        var inconclusive = state.inconclusive
        var compatibilityDetected = state.compatibilityDetected
        defer {
            state.offset = offset
            state.confirmedValidating = confirmedValidating
            state.confirmedEditing = confirmedEditing
            state.confirmedIntegrating = confirmedIntegrating
            state.confirmedExploring = confirmedExploring
            state.inconclusive = inconclusive
            state.compatibilityDetected = compatibilityDetected
        }
        guard !compatibilityDetected else { return }
        while offset < limit {
            let lead = bytes[offset]
            // CJK compatibility ideographs canonically decompose to
            // ordinary ideographs (U+FA55→突 etc.), which the canonical
            // substring search folds but a byte scan cannot see. Detect
            // their UTF-8 lead patterns (conservatively) and defer the
            // whole text to the legacy chain.
            if lead == 0xE2 || lead == 0xEF || lead == 0xF0, offset + 1 < count {
                let next = bytes[offset + 1]
                if (lead == 0xE2 && next >= 0xBC)
                    || (lead == 0xEF && next >= 0xA4 && next <= 0xAB)
                    || (lead == 0xF0 && next == 0xAF) {
                    compatibilityDetected = true
                    break
                }
            }
            let bucket = buckets[Int(fold(lead))]
            if !bucket.isEmpty {
                for index in bucket {
                    let keyword = keywordBytes[index]
                    guard offset + keyword.count <= count else { continue }
                    var matched = true
                    for position in 1..<keyword.count {
                        let expected = keyword[position]
                        let actual = bytes[offset + position]
                        if expected < 0x80 {
                            if fold(actual) != expected { matched = false; break }
                        } else if actual != expected {
                            matched = false
                            break
                        }
                    }
                    guard matched else { continue }
                    // Round 41 (queued by round-26 review F8): the boundary
                    // proofs extend from "adjacent byte is ASCII" to the
                    // decoded-scalar proofs the delimiter scan already pins —
                    // a preceding scalar outside the pinned Prepend set cannot
                    // fuse forward over the keyword (GB9b), and a following
                    // scalar that begins no binding mark cannot absorb its
                    // last character — so the keyword's characters are their
                    // own graphemes and the legacy canonical `contains`
                    // necessarily matches (the round-22 no-false-positive
                    // argument, with the same two primitives whose
                    // completeness the round-24 fusionGap walk and
                    // checkCollapsedWhitespace pin). CJK keywords inside CJK
                    // prose thereby stay on the confirmed fast path instead
                    // of falling to lowercased+contains every derivation.
                    // Unprovable boundaries keep the original inconclusive
                    // fallback, so legacy semantics decide exactly where the
                    // proof does not reach.
                    var leadingProven = offset == 0 || bytes[offset - 1] < 0x80
                    if !leadingProven,
                       let previous = NarrativeDelimiterScan.precedingScalar(in: bytes, before: offset) {
                        leadingProven = !String.isPrependScalar(previous)
                    }
                    var trailingProven = offset + keyword.count == count || bytes[offset + keyword.count] < 0x80
                    if !trailingProven, offset + keyword.count < count {
                        trailingProven = !String.beginsBindingMark(in: bytes, at: offset + keyword.count)
                    }
                    if leadingProven && trailingProven {
                        switch keywords[index].phase {
                        case .validating: confirmedValidating = true
                        case .editing: confirmedEditing = true
                        case .integrating: confirmedIntegrating = true
                        case .exploring: confirmedExploring = true
                        case .blocked, .mixed: break
                        }
                    } else {
                        inconclusive[index] = true
                    }
                }
            }
            offset += 1
        }
    }

    /// The post-scan decision, verbatim from the monolithic form. `text` is
    /// the full logical text, materialized lazily: only the compatibility and
    /// inconclusive fallbacks read it.
    static func resolve(_ state: ScanState, text: @autoclosure () -> String) -> ActivityNarrativePhase {
        if state.compatibilityDetected { return legacyPhase(text()) }
        let inconclusive = state.inconclusive
        // Priority order: a lower-priority confirmed result still requires the
        // higher-priority inconclusive keywords to be resolved first, so each
        // phase checks confirmed-then-fallback in strict priority. One lazy
        // lowercased value is shared across all category resolutions (review
        // F2: the previous per-category lowers ran up to four times).
        var lowered: String?
        func resolves(_ phase: ActivityNarrativePhase) -> Bool {
            var needed = false
            for index in keywords.indices where keywords[index].phase == phase && inconclusive[index] {
                needed = true
                break
            }
            guard needed else { return false }
            let value = lowered ?? text().lowercased()
            lowered = value
            for index in keywords.indices where keywords[index].phase == phase && inconclusive[index] {
                if value.contains(keywords[index].text) { return true }
            }
            return false
        }
        if state.confirmedValidating { return .validating }
        if resolves(.validating) { return .validating }
        if state.confirmedEditing { return .editing }
        if resolves(.editing) { return .editing }
        if state.confirmedIntegrating { return .integrating }
        if resolves(.integrating) { return .integrating }
        if state.confirmedExploring { return .exploring }
        if resolves(.exploring) { return .exploring }
        return .mixed
    }

    static func phase(in text: String) -> ActivityNarrativePhase {
        var state = ScanState()
        var body = text
        body.withUTF8 { buffer in
            scan(&state, buffer, limit: buffer.count, count: buffer.count)
        }
        return resolve(state, text: text)
    }
}

/// Round 41: incremental commentary derivation for one `.progress` entry.
///
/// The from-scratch path rebuilds, per delta, the entry's text
/// (`clean(part)`, then joined), `narrativeText` (delimiter scan + gated
/// headline/detail) and the phase scan — several O(T) byte passes plus
/// multiple O(T) string hashes and static-table inserts per derivation
/// (growing texts are unique per delta, so they always miss and feed the
/// 8192-entry eviction churn). This derivator reproduces the exact same
/// per-observation results while touching only the newly appended bytes,
/// exploiting three invariants of streaming text:
///
/// 1. **clean(joined) is byte-derived.** A `.progress` entry always carries
///    exactly ONE visible text part (ConversationTimelineEntry.make gives
///    every text part its own single-part entry; multi-part input falls back
///    defensively), so the joined text IS the cleaned part: collapsed and
///    trimmed, needing no re-collapsing; `clean(text)` inside
///    `narrativeText` degenerates to a head marker/trim skip (`headSkip2`).
///    The stream is append-only (`joined`), with one exception: the trailing
///    whitespace+colon run (`zoneLen`) that the part's final trim removes.
///    Zone bytes are appended but excluded from the trimmed view until a
///    following non-trim byte makes them interior. `lenTrimmed` never
///    shrinks, so committed scan positions stay valid.
/// 2. **The phase and delimiter scans are resumable.** Phase results
///    committed below a `maxKeywordBytes + 3` holdback are count-invariant
///    (the trailing-at-end-of-text rule and the compatibility lookahead can
///    only fire nearer the end); each observation replays only the tail from
///    the committed state, exactly reproducing a full re-scan at that
///    observation point. Delimiter first-occurrences are prefix-stable; a
///    match is committed only when both boundary proofs read real bytes
///    inside the trimmed view. The round-26 `.inconclusive` outcome (which
///    defers to grapheme-aware `range(of:)`) is not incrementally trackable,
///    so it — like every collapse strict trigger — permanently disables the
///    derivator for this entry (fail-safe: the from-scratch path decides).
///    ASCII delimiter successors are proven non-binding inline (no binding
///    class contains ASCII — the same pinned fact the round-24/26 exhaustive
///    walks document), which keeps ordinary ": word" text on the fast path.
/// 3. **Growth is prefix-stable.** The growing part must extend its stored
///    raw value (`hasPrefix`). Any other shape (mid-turn edit, shrink)
///    reseeds the whole state once.
///
/// The part's own `clean` is mirrored by a collapse state machine with the
/// same strict triggers as `collapsedWhitespace` (GB9b prepend, post-
/// whitespace binding mark, interior non-ASCII whitespace, malformed UTF-8);
/// its head marker gate ("### ", "## ", "# ", "**") is decided only once
/// provably final — before that, and whenever the machine would have to
/// guess, the observation returns `.fallback` and the caller runs the
/// unchanged from-scratch path. `"**"` (a GLOBAL replacement) and any strict
/// trigger set `strict`, permanently retiring this entry to from-scratch.
/// Results are byte-identical by construction and pinned differentially
/// (checkCommentaryDerivation): every observation of every fuzz sequence is
/// compared against the from-scratch path through the same make() code.
final class CommentaryDerivation {
    enum Outcome {
        /// The derived commentary step for this observation (nil = empty text,
        /// i.e. no stage step — same as the from-scratch `text.isEmpty` skip).
        case step(NarrativeStep?)
        /// Run the from-scratch path for this observation. State is unchanged
        /// (undetermined head) or retired (`strict`).
        case fallback
    }

    private(set) var strict = false
    /// Anti-blind counters for the pins: observations that produced a step,
    /// bytes committed below the phase holdback, the delimiter frontier, and
    /// how often each reseed/transition path actually ran.
    private(set) var observations = 0
    private(set) var phaseCommittedBytes = 0
    private(set) var delimFrontier = 0
    private(set) var reseedCount = 0

    // Validation snapshot: raw visibleText parts at the last committed observation.
    private var parts: [String] = []

    // Growing-part collapse machine (mirrors collapsedWhitespace's fast path).
    private var headResolved = false
    private var machineStart = 0    // fold input start inside the growing raw (leading ws + marker)
    private var machinePos = 0      // growing-raw bytes decided by the machine
    private var pendingSpace = false
    private var lastScalar: UInt32 = 0
    private var foldOutEmpty = true
    private var headTrimActive = true
    private var headPending: [UInt8] = []   // at most one scalar, while headTrimActive

    // The joined logical byte stream == the bytes of the from-scratch `text`,
    // plus its open trailing trim zone (zoneLen) excluded from lenTrimmed.
    private var joined: [UInt8] = []
    private var zoneLen = 0

    // clean(text)'s head marker/trim skip over `joined` (narrativeText's inner
    // clean; the rest of clean(text) is identity on this stream).
    private var headSkip2 = 0
    private var headSkip2Fixed = false

    // Resumable phase scan; committed frontier == phaseState.offset.
    private var phaseState = NarrativePhaseScan.ScanState()

    // Delimiter state, joined coordinates. One first-occurrence per kind, in
    // the pinned kind order ("：" then ": "), plus the frozen bounded headline.
    private var delimFound: [Int?] = [nil, nil]
    private var delimHeadline: [String?] = [nil, nil]      // clean(L[..<p], limit: 80)
    private var delimHeadlineFinal: [String?] = [nil, nil] // clean(headline) — assembly-equivalent
    private var delimScanPos = 0

    private static let markerBytes: [[UInt8]] = [
        [0x23, 0x23, 0x23, 0x20],  // "### "
        [0x23, 0x23, 0x20],        // "## "
        [0x23, 0x20],              // "# "
        [0x2A, 0x2A],              // "**" — global replacement, never incremental
    ]
    /// markerBytes as Strings — kept in sync by the byte re-derivation in
    /// checkCommentaryDerivation's sibling pins; markerMatches decides with
    /// these via the product's own String.hasPrefix.
    private static let markerStrings: [String] = ["### ", "## ", "# ", "**"]
    private static let phaseHoldback = NarrativePhaseScan.maxKeywordBytes + 3
    private static let delimPatterns: [[UInt8]] = [[0xEF, 0xBC, 0x9A], [0x3A, 0x20]]

    static func isWhitespaceScalar(_ scalar: UInt32) -> Bool {
        // The stdlib Character.isWhitespace set: ASCII {09-0D, 20} ∪ the
        // non-ASCII set pinned in String.isNonASCIIWhitespace (Zs minus 0x20,
        // plus NEL/LS/PS). This is what the collapse machine's strict
        // triggers mirror (collapsedWhitespace splits on \.isWhitespace).
        scalar == 0x20 || (0x09...0x0D).contains(scalar) || String.isNonASCIIWhitespace(scalar)
    }
    static func isFoundationWhitespaceScalar(_ scalar: UInt32) -> Bool {
        // CharacterSet.whitespacesAndNewlines — what trimmingCharacters uses
        // — is the stdlib set PLUS U+200B on BOTH supported toolchains
        // (ZERO WIDTH SPACE is not Unicode White_Space, but corelibs AND
        // Darwin Foundation both include it; targeted sweep on both, round-41
        // review F4). Trim runs must mirror Foundation, not the stdlib set.
        isWhitespaceScalar(scalar) || scalar == 0x200B
    }
    static func isTrimScalar(_ scalar: UInt32) -> Bool {
        isFoundationWhitespaceScalar(scalar) || scalar == 0x3A || scalar == 0xFF1A
    }
    private static func scalarLength(_ lead: UInt8) -> Int {
        lead < 0x80 ? 1 : (lead <= 0xDF ? 2 : (lead <= 0xEF ? 3 : 4))
    }

    func observe(parts currentParts: [String], firstMessageID: String) -> Outcome {
        if strict { return .fallback }

        // 1. Classify the change against the stored snapshot (read-only).
        //    A `.progress` entry always carries exactly ONE visible text part
        //    (ConversationTimelineEntry.make gives every text part its own
        //    single-part entry), so the derivator is single-part by contract;
        //    any other shape defensively clears state and falls back.
        guard currentParts.count <= 1 else {
            clearState()
            return .fallback
        }
        enum Shape { case reseed, growth, unchanged }
        var shape: Shape = .reseed
        if parts.count == 1, currentParts.count == 1 {
            let stored = parts[0]
            let growing = currentParts[0]
            // Byte-level classification ONLY (review F2): Swift's canonical
            // == accepts NFC/NFD re-encoding, but every derivator offset is a
            // BYTE offset into the stored encoding — a canonically-equal
            // re-encode must reseed, never classify unchanged/growth.
            if Self.isBytePrefix(stored, of: growing) {
                shape = growing.utf8.count == stored.utf8.count ? .unchanged : .growth
            } else {
                shape = .reseed
            }
        } else if parts.isEmpty, currentParts.isEmpty {
            shape = .unchanged
        }

        // 2. Growing-part head gate (leading ws + marker), before any mutation:
        //    while undetermined the cleaned form can still flip (a trailing-
        //    trimmed marker space can reappear), so fall back uncommitted.
        //    A reseed creates a FRESH machine, so the gate re-resolves even
        //    while the previous part's resolution still stands.
        let freshMachine = (shape == .reseed)
        if let growing = currentParts.last {
            var growingBody = growing
            let head = growingBody.withUTF8 { buf -> Int in
                if headResolved, !freshMachine { return machineStart }
                let lead = Self.leadingRun(in: buf, from: 0, limit: buf.count, trimSet: false)
                let trail = Self.trailingRun(in: buf, limit: buf.count, from: 0, trimSet: false)
                if lead + trail >= buf.count { return -1 }  // all-whitespace: undetermined
                for index in Self.markerBytes.indices {
                    if Self.markerMatches(in: buf, at: lead, limit: buf.count - trail, markerIndex: index) {
                        return index == 3 ? -2 : lead + Self.markerBytes[index].count  // -2: "**" → strict
                    }
                }
                if buf.count - trail - lead >= 4 { return lead }
                for marker in Self.markerBytes
                where Self.isProperPrefix(in: buf, at: lead, limit: buf.count - trail, of: marker) {
                    return -1
                }
                return lead
            }
            if head == -2 { strict = true; return .fallback }
            if head == -1 { return .fallback }  // undetermined: no state may advance
            if !headResolved || freshMachine { pendingMachineStart = head }
        }

        // 3. Apply the classified shape. `resolvedStart` survives the reset.
        let resolvedStart = pendingMachineStart
        pendingMachineStart = nil
        if shape == .reseed {
            reseedCount += 1
            clearState()
            parts = currentParts
            // Window-shuffled entries (paging splits whose messages re-form
            // non-monotonically) change without ever growing: seeding the
            // machine for them costs more than the table-backed from-scratch
            // path they fall back to. Store the parts only — a following
            // prefix-growth observation classifies .growth and seeds then,
            // so genuinely streaming entries lose at most one observation.
            return .fallback
        }
        if let start = resolvedStart { machineStart = start; machinePos = start; headResolved = true }
        parts = currentParts

        // 4. Feed the machine; then scans and output composition.
        if !feedGrowing() { return .fallback }  // strict set inside
        return compose(firstMessageID: firstMessageID)
    }

    private var pendingMachineStart: Int? = nil

    /// Byte-level prefix validation. `String.hasPrefix` is grapheme-aware
    /// and costs ~32µs on a 2.8KB CJK string (measured); a plain UTF-8
    /// prefix memcmp costs ~1.7µs and implies the content prefix.
    /// Canonically-equal-but-byte-different growth (NFC/NFD re-encoding)
    /// fails here and takes the reseed path — the conservative direction
    /// (a needless reseed, never a missed one).
    private static func isBytePrefix(_ stored: String, of current: String) -> Bool {
        var storedBody = stored
        var currentBody = current
        return storedBody.withUTF8 { storedBytes in
            currentBody.withUTF8 { currentBytes in
                guard currentBytes.count >= storedBytes.count else { return false }
                for index in 0..<storedBytes.count
                where storedBytes[index] != currentBytes[index] { return false }
                return true
            }
        }
    }

    /// Full state reset (reseed / defensive bail): the next feed rebuilds
    /// everything from the current growing part in one O(T) pass.
    private func clearState() {
        headResolved = false; machineStart = 0; machinePos = 0
        pendingSpace = false; lastScalar = 0; foldOutEmpty = true
        headTrimActive = true; headPending = []; zonePartial = []
        pendingMachineStart = nil
        joined = []; zoneLen = 0
        headSkip2 = 0; headSkip2Fixed = false
        phaseState = NarrativePhaseScan.ScanState()
        delimFound = [nil, nil]; delimHeadline = [nil, nil]; delimHeadlineFinal = [nil, nil]
        delimScanPos = 0
    }

    // MARK: - Collapse machine

    /// Feeds the growing raw part up to its trailing whitespace holdback.
    /// Returns false (with `strict` set) on any collapsedWhitespace strict
    /// trigger; the caller falls back and the entry retires to from-scratch.
    private func feedGrowing() -> Bool {
        guard headResolved, let growing = parts.last else { return true }
        var body = growing
        return body.withUTF8 { buf -> Bool in
            let trail = Self.trailingRun(in: buf, limit: buf.count, from: machinePos, trimSet: false)
            let feedLimit = buf.count - trail
            var i = machinePos
            while i < feedLimit {
                if strict { return false }
                let byte = buf[i]
                if byte == 0x20 || (0x09...0x0D).contains(byte) {
                    if String.isPrependScalar(lastScalar) { strict = true; return false }
                    var j = i
                    while j < feedLimit, buf[j] == 0x20 || (0x09...0x0D).contains(buf[j]) { j += 1 }
                    // feedLimit ends on a non-whitespace scalar boundary, so an
                    // interior run always terminates below it.
                    if j >= feedLimit { break }
                    if buf[j] >= 0x80, String.beginsBindingMark(in: buf, at: j) { strict = true; return false }
                    if !foldOutEmpty { pendingSpace = true }
                    i = j
                } else if byte < 0x80 {
                    if pendingSpace { emit(0x20); pendingSpace = false }
                    emit(byte)
                    lastScalar = 0
                    i += 1
                } else {
                    guard let (scalar, length) = String.utf8Scalar(in: buf, at: i) else { strict = true; return false }
                    guard i + length <= feedLimit else { break }  // straddles the holdback: defer
                    if String.isNonASCIIWhitespace(scalar) { strict = true; return false }
                    if pendingSpace { emit(0x20); pendingSpace = false }
                    for offset in 0..<length { emit(buf[i + offset]) }
                    lastScalar = scalar
                    i += length
                }
            }
            machinePos = i
            return !strict
        }
    }

    /// Appends one fold-output byte to `joined`, applying the part's leading
    /// trim (headTrimActive) and tracking the trailing trim zone.
    private func emit(_ byte: UInt8) {
        foldOutEmpty = false
        if headTrimActive {
            headPending.append(byte)
            let need = Self.scalarLength(headPending[0])
            if headPending.count < need { return }
            // String.utf8Scalar deliberately does not decode ASCII (it serves
            // the non-ASCII branch of collapsedWhitespace); single-byte scalars
            // decode here directly.
            var scalar: UInt32? = headPending[0] < 0x80 ? UInt32(headPending[0]) : nil
            if scalar == nil {
                headPending.withUnsafeBufferPointer { pending in
                    scalar = String.utf8Scalar(in: pending, at: 0)?.0
                }
            }
            guard let value = scalar else { strict = true; return }
            if Self.isTrimScalar(value) { headPending = []; return }
            headTrimActive = false
            joined.append(contentsOf: headPending)  // single part: joined is empty here
            headPending = []
            zoneLen = 0
            return
        }
        joined.append(byte)
        if byte < 0x80 {
            zoneLen = Self.isTrimScalar(UInt32(byte)) ? zoneLen + 1 : 0
        } else {
            zonePartial.append(byte)
            let need = Self.scalarLength(zonePartial[0])
            if zonePartial.count == need {
                var scalar: UInt32? = nil
                zonePartial.withUnsafeBufferPointer { partial in
                    scalar = String.utf8Scalar(in: partial, at: 0)?.0
                }
                let trim = scalar.map(Self.isTrimScalar) ?? false
                zoneLen = trim ? zoneLen + need : 0
                zonePartial = []
            }
        }
    }
    private var zonePartial: [UInt8] = []

    // MARK: - Byte helpers (generic over the raw-part buffer and `joined`)

    private static func decodeScalar<C: RandomAccessCollection>(in bytes: C, at i: Int) -> (UInt32, Int)?
    where C.Element == UInt8, C.Index == Int {
        func continuation(_ j: Int) -> Bool { j < bytes.count && bytes[j] & 0xC0 == 0x80 }
        switch bytes[i] {
        case 0x00...0x7F: return (UInt32(bytes[i]), 1)
        case 0xC2...0xDF:
            guard continuation(i + 1) else { return nil }
            return (UInt32(bytes[i] & 0x1F) << 6 | UInt32(bytes[i + 1] & 0x3F), 2)
        case 0xE0...0xEF:
            guard continuation(i + 1), continuation(i + 2) else { return nil }
            return (UInt32(bytes[i] & 0x0F) << 12 | UInt32(bytes[i + 1] & 0x3F) << 6
                    | UInt32(bytes[i + 2] & 0x3F), 3)
        case 0xF0...0xF4:
            guard continuation(i + 1), continuation(i + 2), continuation(i + 3) else { return nil }
            return (UInt32(bytes[i] & 0x07) << 18 | UInt32(bytes[i + 1] & 0x3F) << 12
                    | UInt32(bytes[i + 2] & 0x3F) << 6 | UInt32(bytes[i + 3] & 0x3F), 4)
        default: return nil
        }
    }

    /// Length of the leading run of trim-set scalars in bytes[from..<limit].
    /// trimSet: false = whitespace only (clean's first trim), true = ws+colon.
    private static func leadingRun<C: RandomAccessCollection>(in bytes: C, from: Int, limit: Int, trimSet: Bool) -> Int
    where C.Element == UInt8, C.Index == Int {
        var i = from
        while i < limit {
            guard let (value, len) = decodeScalar(in: bytes, at: i), i + len <= limit else { break }
            guard trimSet ? isTrimScalar(value) : isFoundationWhitespaceScalar(value) else { break }
            i += len
        }
        return i - from
    }

    /// Length of the trailing run of trim-set scalars ending at `limit`.
    private static func trailingRun<C: RandomAccessCollection>(in bytes: C, limit: Int, from: Int, trimSet: Bool) -> Int
    where C.Element == UInt8, C.Index == Int {
        var i = limit
        while i > from {
            var start = i - 1
            var walked = 0
            while start > from, bytes[start] & 0xC0 == 0x80 { start -= 1; walked += 1; if walked > 3 { return limit - i } }
            guard let (value, len) = decodeScalar(in: bytes, at: start), start + len == i else { return limit - i }
            guard trimSet ? isTrimScalar(value) : isFoundationWhitespaceScalar(value) else { break }
            i = start
        }
        return limit - i
    }

    private static func hasPrefix<C: RandomAccessCollection>(in bytes: C, at: Int, limit: Int, pattern: [UInt8]) -> Bool
    where C.Element == UInt8, C.Index == Int {
        guard at + pattern.count <= limit else { return false }
        for offset in pattern.indices where bytes[at + offset] != pattern[offset] { return false }
        return true
    }

    /// Whether bytes[at..<limit] is a proper prefix of `pattern` (the marker
    /// decision could still flip as bytes arrive).
    private static func isProperPrefix<C: RandomAccessCollection>(in bytes: C, at: Int, limit: Int, of pattern: [UInt8]) -> Bool
    where C.Element == UInt8, C.Index == Int {
        let n = limit - at
        guard n > 0, n < pattern.count else { return false }
        for offset in 0..<n where bytes[at + offset] != pattern[offset] { return false }
        return true
    }

    /// Marker match by the PRODUCT'S OWN predicate (review F3 + re-review
    /// F3'). clean()'s gate is `text.hasPrefix(marker)` on the trimmed
    /// string; neither the raw byte prefix (accepts "# ◌́x", which
    /// grapheme-aware hasPrefix rejects — the space fuses with the Extend
    /// mark) nor a beginsBindingMark rejection (rejects "**◌\u{102B}x",
    /// where hasPrefix ACCEPTS: beginsBindingMark is a conservative
    /// over-approximation of fusion — safe when it routes to fallback,
    /// unsafe as a definitive rejection while staying incremental) is
    /// exact. So: byte-match first (cheap filter), then materialize the
    /// decision window — the marker plus the next 8 bytes of the trimmed
    /// view — and ask String.hasPrefix itself. Window sufficiency: a
    /// fusion that changes the marker's last Character must begin at the
    /// first scalar after the marker (≤4 bytes, inside the window); a cut
    /// inside a longer fused cluster can only keep that cluster unequal
    /// to the bare marker character, preserving the answer. `limit` is the
    /// caller's trimmed-view end (clean() never sees trailing whitespace).
    private static func markerMatches<C: RandomAccessCollection>(in bytes: C, at: Int, limit: Int, markerIndex: Int) -> Bool
    where C.Element == UInt8, C.Index == Int {
        let marker = markerBytes[markerIndex]
        guard hasPrefix(in: bytes, at: at, limit: limit, pattern: marker) else { return false }
        let windowEnd = min(limit, at + marker.count + 8)
        let window = String(decoding: bytes[at..<windowEnd], as: UTF8.self)
        return window.hasPrefix(markerStrings[markerIndex])
    }

    /// The head marker removal clean() would apply at `at`; sets `strict` for
    /// "**" (a GLOBAL replacement — not incrementally trackable).
    private func markerSkip(in bytes: [UInt8], at: Int, limit: Int) -> Int {
        for (index, marker) in Self.markerBytes.enumerated()
        where Self.markerMatches(in: bytes, at: at, limit: limit, markerIndex: index) {
            if index == 3 { strict = true }
            return marker.count
        }
        return 0
    }

    // MARK: - Scans and output composition

    /// clean(text)'s head marker/trim skip over `joined` (narrativeText's
    /// inner clean; the rest of clean(text) is identity on this stream — the
    /// parts are collapsed and trimmed, the junctions are single spaces).
    private func resolveHeadSkip2(lenTrimmed: Int) {
        guard !headSkip2Fixed else { return }
        for index in Self.markerBytes.indices
        where Self.markerMatches(in: joined, at: 0, limit: lenTrimmed, markerIndex: index) {
            if index == 3 { strict = true; return }
            // A full match implies a following non-trim byte (cleaned parts
            // end non-trimmed), so the marker skip is final; the ws+colon run
            // behind it is final only once closed by a non-trim byte.
            let runEnd = Self.markerBytes[index].count + Self.leadingRun(in: joined, from: Self.markerBytes[index].count, limit: lenTrimmed, trimSet: true)
            headSkip2 = runEnd
            headSkip2Fixed = runEnd < lenTrimmed
            return
        }
        headSkip2 = 0
        // Fixed once no marker can still complete: every marker either
        // diverges within the available head bytes or needs more bytes than
        // exist with the head already >= the marker length.
        var couldMatch = false
        for marker in Self.markerBytes where marker.count > lenTrimmed {
            var diverged = false
            for offset in 0..<lenTrimmed where joined[offset] != marker[offset] { diverged = true; break }
            if !diverged { couldMatch = true }
        }
        headSkip2Fixed = !couldMatch
    }

    /// Commits phase bytes below the holdback frontier, replays the tail, and
    /// resolves — equal to a full `NarrativePhaseScan.phase(in:)` of the
    /// current joined text at every observation (committed results are
    /// count-invariant below the frontier; see ScanState's contract).
    private func runPhaseScan(lenTrimmed: Int) -> ActivityNarrativePhase {
        return joined.withUnsafeBufferPointer { buf in
            if !phaseState.compatibilityDetected {
                let limit = max(phaseState.offset, lenTrimmed - Self.phaseHoldback)
                NarrativePhaseScan.scan(&phaseState, buf, limit: limit, count: lenTrimmed)
                phaseCommittedBytes = phaseState.offset
            }
            var tail = phaseState
            NarrativePhaseScan.scan(&tail, buf, limit: lenTrimmed, count: lenTrimmed)
            return NarrativePhaseScan.resolve(tail, text: String(decoding: joined[0..<lenTrimmed], as: UTF8.self))
        }
    }

    /// Incremental first-occurrence scan for both delimiter kinds, in joined
    /// coordinates (valid while headSkip2 is fixed; L == joined[headSkip2..]).
    /// Loop bound: an occurrence must end at least one byte below lenTrimmed
    /// (both patterns end on trim-set bytes, which the trimmed view excludes),
    /// so every occurrence a full scan would see at this observation is
    /// reached; the narrower pattern's guard covers its shorter span.
    private func runDelimScan(lenTrimmed: Int) {
        joined.withUnsafeBufferPointer { buf in
            // The scan operates on L == joined[headSkip2...]: an occurrence
            // inside the skipped head does not exist for narrativeText's
            // clean(text), and slicing joined[headSkip2..<pos] with
            // pos < headSkip2 is a reversed (fatal) range (review F1).
            var pos = max(delimScanPos, headSkip2)
            while pos + 2 <= lenTrimmed - 1 {
                for (kind, pattern) in Self.delimPatterns.enumerated() where delimFound[kind] == nil {
                    guard pos + pattern.count <= lenTrimmed - 1 else { continue }
                    var matched = true
                    for offset in pattern.indices where buf[pos + offset] != pattern[offset] { matched = false; break }
                    guard matched else { continue }
                    // Preceding boundary (GB9b): the same proof as
                    // NarrativeDelimiterScan.firstOccurrence.
                    if pos > headSkip2, buf[pos - 1] >= 0x80 {
                        guard let previous = NarrativeDelimiterScan.precedingScalar(in: buf, before: pos),
                              !String.isPrependScalar(previous) else { strict = true; return }
                    }
                    // Following boundary: ASCII successors are proven
                    // non-binding (no binding class contains ASCII — the
                    // pinned round-24/26 walk documentation); non-ASCII
                    // decodes one scalar, complete below lenTrimmed because
                    // the trimmed view ends on a scalar boundary.
                    let upper = pos + pattern.count
                    if buf[upper] >= 0x80, String.beginsBindingMark(in: buf, at: upper) {
                        strict = true; return
                    }
                    delimFound[kind] = pos
                    let slice = String(decoding: buf[headSkip2..<pos], as: UTF8.self)
                    let headline = ActivityNarrativeSnapshot.clean(slice, limit: 80)
                    delimHeadline[kind] = headline
                    delimHeadlineFinal[kind] = ActivityNarrativeSnapshot.clean(headline)
                }
                if strict { return }
                pos += 1
            }
            delimScanPos = pos
            delimFrontier = pos - headSkip2
        }
    }

    /// clean(suffix)'s head skip (ws run, marker gate, ws+colon run) followed
    /// by the assembly's clean(detail) head skip (marker gate, ws+colon run;
    /// its first trim is a no-op because the previous run covers whitespace).
    /// Returns the final detail start and whether clean(suffix) is nonempty —
    /// monotone under growth, matching the from-scratch `!detail.isEmpty` gate.
    private func detailHeadSkip(upper: Int, lenTrimmed: Int) -> (start: Int, nonEmpty: Bool) {
        var s = upper + Self.leadingRun(in: joined, from: upper, limit: lenTrimmed, trimSet: false)
        s += markerSkip(in: joined, at: s, limit: lenTrimmed)
        if strict { return (s, false) }
        s += Self.leadingRun(in: joined, from: s, limit: lenTrimmed, trimSet: true)
        let nonEmpty = s < lenTrimmed
        s += markerSkip(in: joined, at: s, limit: lenTrimmed)
        if strict { return (s, false) }
        s += Self.leadingRun(in: joined, from: s, limit: lenTrimmed, trimSet: true)
        return (s, nonEmpty)
    }

    /// clean(L)'s head skip for the separator-free headline (assembly's
    /// clean(subject)); L's head is never whitespace, so this is the marker
    /// gate plus the ws+colon run behind it. Recomputed per observation:
    /// like the from-scratch form, the decision follows the bytes available
    /// NOW (a short head matches no marker yet).
    private func headMarkerTrimSkip(from: Int, limit: Int) -> Int {
        var s = from + markerSkip(in: joined, at: from, limit: limit)
        if strict { return 0 }
        s += Self.leadingRun(in: joined, from: s, limit: limit, trimSet: true)
        return s - from
    }

    private func compose(firstMessageID: String) -> Outcome {
        let lenTrimmed = joined.count - zoneLen
        guard lenTrimmed > 0 else { observations += 1; return .step(nil) }

        resolveHeadSkip2(lenTrimmed: lenTrimmed)
        if strict { return .fallback }
        let phaseValue = runPhaseScan(lenTrimmed: lenTrimmed)
        if headSkip2Fixed { runDelimScan(lenTrimmed: lenTrimmed) }
        if strict { return .fallback }

        // Gate evaluation mirrors the from-scratch kind loop AT THIS
        // observation: a kind whose gate passes later (its detail becoming
        // nonempty) outranks a previously-passing later kind, so gates are
        // re-checked per observation, never frozen at first pass.
        var chosen: (kind: Int, detailStart: Int)? = nil
        for kind in 0..<2 {
            guard let position = delimFound[kind], let headline = delimHeadline[kind],
                  !headline.isEmpty, headline.count <= 48 else { continue }
            let (start, nonEmpty) = detailHeadSkip(upper: position + Self.delimPatterns[kind].count,
                                                   lenTrimmed: lenTrimmed)
            if strict { return .fallback }
            if nonEmpty { chosen = (kind, start); break }
        }

        observations += 1
        let id = "commentary:\(firstMessageID)"
        if let (kind, detailStart) = chosen {
            let detail = String(decoding: joined[detailStart..<lenTrimmed], as: UTF8.self)
            return .step(.stage(id: id, phase: phaseValue, subject: delimHeadline[kind]!,
                                headline: delimHeadlineFinal[kind]!, detail: detail,
                                source: .commentary, lifecycle: .streaming, precleaned: true))
        }
        let subject = String(decoding: joined[headSkip2..<lenTrimmed], as: UTF8.self)
        let skip3 = headMarkerTrimSkip(from: headSkip2, limit: lenTrimmed)
        if strict { return .fallback }
        let headline = skip3 == 0
            ? subject
            : String(decoding: joined[(headSkip2 + skip3)..<lenTrimmed], as: UTF8.self)
        return .step(.stage(id: id, phase: phaseValue, subject: subject, headline: headline,
                            detail: nil, source: .commentary, lifecycle: .streaming, precleaned: true))
    }
}

public enum ActivityNarrativeProjection {
    private struct Builder {
        var narrative: ActivityNarrative
        var entryIDs: [String] = []
        /// Membership index for entryIDs: attaching thousands of entries to one open
        /// stage must not scan the array per entry.
        var entryIDSet: Set<String> = []
        var toolIDs: [String] = []
    }

    public static func make(entries: [ConversationTimelineEntry], tools: [String: VisibleTool],
                            isRunning: Bool,
                            external: [String: ActivitySummaryResult] = [:],
                            cache: NarrativeTextCache = NarrativeTextCache()) -> ActivityNarrativeSnapshot {
        let boundary = entries.lastIndex { entry in
            entry.presentation == .message && entry.messages.first?.isUserPrompt == true
        }
        let turnID = boundary.flatMap { entries[$0].messages.first?.id }
        let currentEntries = boundary.map { Array(entries.dropFirst($0 + 1)) } ?? entries
        guard let turnID = turnID ?? currentEntries.first?.messages.first?.id else {
            return ActivityNarrativeSnapshot(turnID: nil, stages: [], entryStageIDs: [:])
        }

        var stages: [Builder] = []
        var entryStageIDs: [String: String] = [:]
        // Captured once per call: the resolution memo validates against this
        // token because its headlines embed L() output (AppLanguage.current).
        // The token is the cheap raw setting, not the resolved localization:
        // resolving reads the global defaults domain + Bundle localization
        // preferences (~20µs measured on the append benches). Two layers keep
        // this sound: (1) a settings change (en/zh-Hans/system) flips the raw
        // value and misses every entry; (2) a system-language change under
        // the .system setting flips Input.language (callers compose it from
        // the locale identifier + resolved localization), which fires the
        // model's language reset → invalidateToolResolutions() below.
        let resolutionLanguage = AppLanguage.current.rawValue

        // Keywords matched against agent text in either language, not UI labels.
        // Only unresolved tool states (missingResult / disconnected) mark a stage
        // `.blocked`; ordinary commentary mentioning "error" or "失败" is prose.
        // Round 22: the 32-predicate lowercased+contains chain lives on in
        // NarrativePhaseScan — one byte pass with proven-boundary fast accepts
        // and the original canonical predicate as the inconclusive fallback.
        func phase(from text: String) -> ActivityNarrativePhase {
            NarrativeTextCache.phase(for: text) {
                NarrativePhaseScan.phase(in: text)
            }
        }

        func localHeadline(_ phase: ActivityNarrativePhase, target: String?) -> String {
            let cleanTarget = ActivityNarrativeSnapshot.clean(target ?? "", limit: 80)
            if cleanTarget.isEmpty {
                switch phase {
                case .exploring: return L("分析任务")
                case .editing: return L("修改实现")
                case .validating: return L("验证改动")
                case .integrating: return L("整合改动")
                case .blocked: return L("处理失败的操作")
                case .mixed: return L("推进任务")
                }
            }
            return "\(phase.label) \(cleanTarget)"
        }

        func toolPhase(_ tool: VisibleTool) -> ActivityNarrativePhase {
            if [.missingResult, .disconnected].contains(tool.status) { return .blocked }
            let name = tool.name.lowercased()
            if ToolPresentation.isExploration(name) || ["fetch", "web_search", "view_image"].contains(name) { return .exploring }
            if ["edit", "write", "edit_file", "write_file", "apply_patch", "filechange"].contains(name) { return .editing }
            if let command = ShellActivity.command(tool) { return ShellActivity.parse(command)?.phase ?? .mixed }
            return .mixed
        }

        func appendStage(id: String, phase: ActivityNarrativePhase, subject: String,
                         headline: String, detail: String?, source: ActivityNarrativeSource,
                         evidenceIDs: [String] = [], lifecycle: ActivityNarrativeLifecycle = .streaming,
                         precleaned: Bool = false) {
            let narrative = ActivityNarrative(turnID: turnID, stageID: id, phase: phase,
                subject: subject, headline: precleaned ? headline : ActivityNarrativeSnapshot.clean(headline),
                detail: detail.map { precleaned ? $0 : ActivityNarrativeSnapshot.clean($0) },
                source: source, evidenceIDs: evidenceIDs, lifecycle: lifecycle)
            stages.append(Builder(narrative: narrative))
        }

        for entry in currentEntries {
            // This placeholder reuses the first message for the empty-output UI;
            // it is not a second observation of that message's tools.
            guard entry.presentation != .emptyOutput else { continue }
            let steps = cache.steps(for: entry) {
                var derived: [NarrativeStep] = []
                if entry.presentation == .progress {
                    let parts = entry.messages.flatMap(\.content).compactMap(\.visibleText)
                    // Round 41: the incremental derivator reproduces the block
                    // below byte-for-byte at every observation; .fallback runs
                    // it unchanged (undetermined head, or a retired entry).
                    var incremental = false
                    if let firstMessage = entry.messages.first {
                        if case .step(let step) = cache.commentary(entryID: entry.id, parts: parts,
                                                                   firstMessageID: firstMessage.id) {
                            incremental = true
                            if let step { derived.append(step) }
                        }
                    }
                    if !incremental {
                        let text = parts.map({ ActivityNarrativeSnapshot.clean($0) })
                            .filter({ !$0.isEmpty }).joined(separator: " ")
                        if !text.isEmpty {
                            let narrativeText = ActivityNarrativeSnapshot.narrativeText(text)
                            derived.append(.stage(id: "commentary:\(entry.messages[0].id)", phase: phase(from: text),
                                subject: narrativeText.headline, headline: narrativeText.headline,
                                detail: narrativeText.detail, source: .commentary, lifecycle: .streaming))
                        }
                    }
                }
                for message in entry.messages {
                    for part in message.content {
                        if part.type == "thinking", part.source?["kind"].string == "activity_summary" {
                            let parts = part.source?["summaryParts"].array.compactMap(\.string) ?? []
                            let text = parts.map { ActivityNarrativeSnapshot.clean($0) }
                                .filter { !$0.isEmpty }.joined(separator: " ")
                            if text.isEmpty { continue }
                            let narrativeText = ActivityNarrativeSnapshot.narrativeText(text)
                            let itemID = part.source?["itemId"].string ?? message.id
                            let state: ActivityNarrativeLifecycle = part.source?["state"].string == "final"
                                ? .final : .streaming
                            derived.append(.stage(id: "provider:\(itemID)", phase: phase(from: text),
                                subject: narrativeText.headline, headline: narrativeText.headline,
                                detail: narrativeText.detail, source: .provider, lifecycle: state))
                            continue
                        }
                        if part.type == "thinking" {
                            // Applied only while no stage exists yet.
                            derived.append(.thinkingPlaceholder(messageID: message.id))
                            continue
                        }
                        guard part.type == "tool_use" else { continue }
                        derived.append(.tool(part))
                    }
                }
                return derived
            }
            for step in steps {
                switch step {
                case .stage(let id, let stepPhase, let subject, let headline, let detail, let source, let lifecycle, let precleaned):
                    appendStage(id: id, phase: stepPhase, subject: subject, headline: headline,
                                detail: detail, source: source, lifecycle: lifecycle, precleaned: precleaned)
                case .thinkingPlaceholder(let messageID):
                    if stages.isEmpty {
                        appendStage(id: "stage:\(turnID):thinking:\(messageID)", phase: .exploring,
                                    subject: "", headline: L("分析任务"), detail: nil, source: .local)
                    }
                case .tool(let part):
                    guard let id = part.toolCallId, let tool = tools[id] else { continue }
                    // Round 38: the tool step's resolution is a pure function of
                    // the tool value AND the UI language; memoize it with
                    // full-value + language validation so a streaming delta
                    // only re-derives the tools that moved.
                    let resolution = cache.resolution(for: tool, language: resolutionLanguage) {
                        let phaseValue = toolPhase(tool)
                        let targetValue = ToolPresentation.compactTarget(tool)
                        let shellCommand = ShellActivity.command(tool)
                        let shell = shellCommand.flatMap(ShellActivity.parse)
                        let headlineValue: String
                        if shellCommand != nil, phaseValue != .blocked {
                            let description = tool.input?["description"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
                            headlineValue = description.flatMap { $0.isEmpty ? nil : $0 }
                                ?? shell?.headline ?? L("准备命令环境")
                        } else { headlineValue = localHeadline(phaseValue, target: targetValue) }
                        // Waiting/setup commands are evidence within the current task,
                        // not a new semantic stage that displaces explicit progress.
                        let incidentalValue = shellCommand != nil && (shell?.category == nil || shell?.category == "wait") && phaseValue != .blocked
                        return NarrativeTextCache.ToolResolution(phase: phaseValue, target: targetValue,
                                                                 headline: headlineValue, incidental: incidentalValue)
                    }
                    let nextPhase = resolution.phase
                    let target = resolution.target
                    let headline = resolution.headline
                    let incidental = resolution.incidental
                    let needsStage = stages.isEmpty || (!incidental && stages.last!.narrative.phase != nextPhase && !stages.last!.toolIDs.isEmpty)
                    if needsStage {
                        appendStage(id: "stage:\(turnID):tool:\(id)", phase: nextPhase, subject: target,
                                    headline: headline, detail: nil,
                                    source: .local, evidenceIDs: [id])
                    } else {
                        var current = stages.removeLast()
                        if current.narrative.source == .local && current.toolIDs.isEmpty {
                            current.narrative = ActivityNarrative(turnID: turnID, stageID: current.narrative.stageID,
                                phase: nextPhase, subject: target, headline: headline,
                                detail: nil, source: .local, evidenceIDs: [id], lifecycle: .streaming)
                        }
                        stages.append(current)
                    }
                    if !stages[stages.count - 1].toolIDs.contains(id) {
                        stages[stages.count - 1].toolIDs.append(id)
                    }
                }
            }
            if entry.isProcess || entry.presentation == .progress, !stages.isEmpty {
                let index = stages.count - 1
                if !stages[index].entryIDSet.contains(entry.id) { stages[index].entryIDs.append(entry.id); stages[index].entryIDSet.insert(entry.id) }
                entryStageIDs[entry.id] = stages[index].narrative.stageID
            }
        }

        let output = stages.enumerated().map { index, builder -> ActivityNarrativeStage in
            let closed = index < stages.count - 1 || !isRunning
            let narrative = ActivityNarrative(turnID: builder.narrative.turnID,
                stageID: builder.narrative.stageID, phase: builder.narrative.phase,
                subject: builder.narrative.subject, headline: builder.narrative.headline,
                detail: builder.narrative.detail, source: builder.narrative.source,
                evidenceIDs: builder.toolIDs.isEmpty ? builder.narrative.evidenceIDs : builder.toolIDs,
                lifecycle: closed ? .final : builder.narrative.lifecycle,
                revision: builder.narrative.revision)
            return ActivityNarrativeStage(narrative: narrative, entryIDs: builder.entryIDs,
                                          toolIDs: builder.toolIDs, closed: closed)
        }
        return ActivityNarrativeSnapshot(turnID: turnID, stages: output,
                                         entryStageIDs: entryStageIDs).applying(external)
    }
}

public extension ConversationTimelineEntry {
    /// Transcript prose keeps its original Markdown and paragraph boundaries.
    /// Provider summaries expose only their public summary parts, never thinking.
    func narrativeSourceText(for narrative: ActivityNarrative) -> String? {
        guard isNarrativeSource(for: narrative) else { return nil }
        let parts = messages.flatMap(\.content)
        switch narrative.source {
        case .commentary:
            return parts.filter { $0.type == "text" }.compactMap(\.visibleText).joined(separator: "\n\n")
        case .provider:
            return parts.filter { $0.type == "thinking" && $0.source?["kind"].string == "activity_summary" }
                .flatMap { $0.source?["summaryParts"].array.compactMap(\.string) ?? [] }.joined(separator: "\n\n")
        case .external, .local:
            return nil
        }
    }

    func isNarrativeSource(for narrative: ActivityNarrative) -> Bool {
        switch narrative.source {
        case .commentary:
            return presentation == .progress
        case .provider:
            return messages.contains { message in
                message.content.contains {
                    $0.type == "thinking" && $0.source?["kind"].string == "activity_summary"
                }
            }
        case .external, .local:
            return false
        }
    }
}
