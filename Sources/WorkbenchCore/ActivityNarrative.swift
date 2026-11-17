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
    /// also records the resolved language and misses when it moved — a
    /// language switch re-derives every resolution (review F1).
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
    /// language/epoch reset as hygiene; correctness rides on the per-entry
    /// language validation above, which also covers a UserDefaults language
    /// change that never surfaces as an input.language change.
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
}

/// One entry's ordered contribution to the narrative fold. Text work happens at
/// derive time; tool steps resolve against the live tool table when applied.
enum NarrativeStep {
    case stage(id: String, phase: ActivityNarrativePhase, subject: String, headline: String,
               detail: String?, source: ActivityNarrativeSource, lifecycle: ActivityNarrativeLifecycle)
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
    private static func precedingScalar(in bytes: UnsafeBufferPointer<UInt8>, before index: Int) -> UInt32? {
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

    static func phase(in text: String) -> ActivityNarrativePhase {
        var confirmedValidating = false
        var confirmedEditing = false
        var confirmedIntegrating = false
        var confirmedExploring = false
        var inconclusive = [Bool](repeating: false, count: keywords.count)
        var compatibilityDetected = false
        var body = text
        body.withUTF8 { buffer in
            let count = buffer.count
            var offset = 0
            while offset < count {
                let lead = buffer[offset]
                // CJK compatibility ideographs canonically decompose to
                // ordinary ideographs (U+FA55→突 etc.), which the canonical
                // substring search folds but a byte scan cannot see. Detect
                // their UTF-8 lead patterns (conservatively) and defer the
                // whole text to the legacy chain.
                if lead == 0xE2 || lead == 0xEF || lead == 0xF0, offset + 1 < count {
                    let next = buffer[offset + 1]
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
                            let actual = buffer[offset + position]
                            if expected < 0x80 {
                                if fold(actual) != expected { matched = false; break }
                            } else if actual != expected {
                                matched = false
                                break
                            }
                        }
                        guard matched else { continue }
                        let leadingProven = offset == 0 || buffer[offset - 1] < 0x80
                        let trailingProven = offset + keyword.count == count || buffer[offset + keyword.count] < 0x80
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
        if compatibilityDetected { return legacyPhase(text) }
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
            let value = lowered ?? text.lowercased()
            lowered = value
            for index in keywords.indices where keywords[index].phase == phase && inconclusive[index] {
                if value.contains(keywords[index].text) { return true }
            }
            return false
        }
        if confirmedValidating { return .validating }
        if resolves(.validating) { return .validating }
        if confirmedEditing { return .editing }
        if resolves(.editing) { return .editing }
        if confirmedIntegrating { return .integrating }
        if resolves(.integrating) { return .integrating }
        if confirmedExploring { return .exploring }
        if resolves(.exploring) { return .exploring }
        return .mixed
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
        let resolutionLanguage = AppLanguage.current.localization

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
                         evidenceIDs: [String] = [], lifecycle: ActivityNarrativeLifecycle = .streaming) {
            let narrative = ActivityNarrative(turnID: turnID, stageID: id, phase: phase,
                subject: subject, headline: ActivityNarrativeSnapshot.clean(headline),
                detail: detail.map { ActivityNarrativeSnapshot.clean($0) },
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
                    let text = entry.messages.flatMap(\.content).compactMap(\.visibleText)
                        .map({ ActivityNarrativeSnapshot.clean($0) }).filter({ !$0.isEmpty }).joined(separator: " ")
                    if !text.isEmpty {
                        let narrativeText = ActivityNarrativeSnapshot.narrativeText(text)
                        derived.append(.stage(id: "commentary:\(entry.messages[0].id)", phase: phase(from: text),
                            subject: narrativeText.headline, headline: narrativeText.headline,
                            detail: narrativeText.detail, source: .commentary, lifecycle: .streaming))
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
                case .stage(let id, let stepPhase, let subject, let headline, let detail, let source, let lifecycle):
                    appendStage(id: id, phase: stepPhase, subject: subject, headline: headline,
                                detail: detail, source: source, lifecycle: lifecycle)
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
