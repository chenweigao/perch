import Foundation
import WorkbenchCore

/// Round 41: differential fuzz pinning the incremental commentary derivator.
///
/// Contract: at EVERY observation of a growing `.progress` entry, the
/// derivator path must produce the same ActivityNarrativeSnapshot as the
/// from-scratch path — run through the very same
/// ActivityNarrativeProjection.make() code with the pin-only kill switch
/// (`commentaryDerivationDisabled`) forcing the fallback branch. Sequences
/// grow one SCALAR at a time (finer than Character growth: it observes the
/// step immediately before a combining mark attaches — review M1), so every
/// scalar prefix of every corpus text is an observation point. Output
/// strings are compared at UTF-8 byte level on top of the canonical
/// Snapshot ==, except for deliberate re-encoding sequences (see run()).
///
/// Anti-blind: the derivator must demonstrably ENGAGE (observations,
/// committed phase bytes, delimiter frontier), strict-trigger corpus items
/// must demonstrably RETIRE (strict == true, results still equal), and the
/// reseed path must demonstrably RUN (counter > 0).
func checkCommentaryDerivation() throws {
    func textMessages(_ texts: [String], createdAt: String = "2") throws -> [KimiMessage] {
        var content: [[String: Any]] = []
        for text in texts { content.append(["type": "text", "text": text]) }
        let raw: [[String: Any]] = [
            ["id": "u1", "role": "user", "created_at": "1", "content": [["type": "text", "text": "检查文件"]]],
            ["id": "a1", "role": "assistant", "created_at": createdAt, "content": content],
        ]
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func snapshot(_ messages: [KimiMessage], cache: NarrativeTextCache) -> ActivityNarrativeSnapshot {
        let entries = ConversationTimelineEntry.make(messages, isRunning: true)
        return ActivityNarrativeProjection.make(entries: entries, tools: [:], isRunning: true, cache: cache)
    }
    func oracle(_ messages: [KimiMessage]) -> ActivityNarrativeSnapshot {
        let disabled = NarrativeTextCache()
        disabled.commentaryDerivationDisabled = true
        return snapshot(messages, cache: disabled)
    }

    // Byte-level serialization: Snapshot Equatable is canonical String ==,
    // which would accept NFC/NFD encoding drift in outputs.
    func snapshotBytes(_ s: ActivityNarrativeSnapshot) -> [UInt8] {
        var out: [UInt8] = []
        func add(_ t: String?) {
            if let t { out.append(contentsOf: Array(t.utf8)); out.append(0) } else { out.append(1) }
        }
        for stage in s.stages {
            add(stage.narrative.stageID); add(stage.narrative.phase.rawValue)
            add(stage.narrative.subject); add(stage.narrative.headline)
            add(stage.narrative.detail); add(stage.narrative.source.rawValue)
            add(stage.narrative.lifecycle == .final ? "f" : "s")
            for id in stage.entryIDs { add(id) }
            for id in stage.toolIDs { add(id) }
            add(stage.closed ? "closed" : "open")
        }
        return out
    }

    var observations = 0
    /// byteCompare: compare UTF-8 bytes of every output string, not just the
    /// canonical Snapshot ==. Disabled for re-encoding sequences: the SHARED
    /// static tables are canonical-keyed, so earlier checks' canonical-pair
    /// corpora make the from-scratch oracle return whichever encoding was
    /// inserted first — an insertion-history dependence the BASE product
    /// already has. The derivator returns the raw part bytes; both are
    /// canonically equal, which is the product contract (round-22 pin:
    /// narrative tables "preserve snapshots across canonical pairs").
    func run(_ sequence: [[String]], cache: NarrativeTextCache, label: String,
             varyMetadata: Bool = false, byteCompare: Bool = true) throws {
        for (index, parts) in sequence.enumerated() {
            // varyMetadata defeats the steps-cache deep-equality hit (message
            // == is canonical on text), forcing derive — and therefore the
            // derivator's byte-prefix classification — on every observation
            // (review F2 reproduction shape).
            let messages = try textMessages(parts, createdAt: varyMetadata ? "\(2 + index)" : "2")
            let got = snapshot(messages, cache: cache)
            let want = oracle(messages)
            if byteCompare {
                let gotBytes = snapshotBytes(got)
                let wantBytes = snapshotBytes(want)
                if got == want && gotBytes != wantBytes {
                    var i = 0
                    while i < min(gotBytes.count, wantBytes.count), gotBytes[i] == wantBytes[i] { i += 1 }
                    let lo = max(0, i - 4)
                    let gctx = gotBytes[lo..<min(gotBytes.count, i + 8)].map { String(format: "%02X", $0) }.joined(separator: " ")
                    let wctx = wantBytes[lo..<min(wantBytes.count, i + 8)].map { String(format: "%02X", $0) }.joined(separator: " ")
                    preconditionFailure("byte-level divergence [\(label)] at parts \(parts) offset \(i)\n  got:  \(gctx)\n  want: \(wctx)")
                }
            }
            precondition(got == want,
                "commentary derivator diverged [\(label)] at parts \(parts)\n  got:  \(got)\n  want: \(want)")
            observations += 1
        }
    }
    /// Every SCALAR prefix of `final`, in order, on one persistent cache.
    func grow(_ final: String, label: String, byteCompare: Bool = true) throws -> NarrativeTextCache {
        let cache = NarrativeTextCache()
        let scalars = Array(final.unicodeScalars)
        var sequence: [[String]] = []
        for count in 0...scalars.count { sequence.append([String(String.UnicodeScalarView(scalars[0..<count]))]) }
        try run(sequence, cache: cache, label: label, byteCompare: byteCompare)
        return cache
    }
    func progressEntryID(_ messages: [KimiMessage]) -> String? {
        let entries = ConversationTimelineEntry.make(messages, isRunning: true)
        return entries.first { $0.presentation == .progress }?.id
    }

    // ---- single growing part: the corpus --------------------------------
    let incrementalCorpus: [(label: String, text: String)] = [
        ("bench-shape", "第 1 段结论:实现满足约束,继续推进验证与收尾工作。第 2 段:合并检查"),
        ("cjk-separator", "标题：细节内容,验证构建"),
        ("ascii-separator", "head: tail words with test keyword"),
        ("kind-priority-flip", "a: b：c"),
        ("detail-empty-flip", "h：：x"),
        ("colon-flood", "：：：：x：：y"),
        ("ascii-colon-run", "a::::b:: c"),
        ("phase-flip", "read\n\ntest"),
        ("phase-upper", "Running TESTS and BUILD"),
        ("phase-inconclusive-tail", "验证test\u{0301}"),
        ("phase-prepend", "\u{0600}test flow"),
        ("compat-ideograph", "冲\u{FA55}构建"),
        ("marker-hash-flip", "# # x 检查"),
        ("marker-hash-grow", "# 标题：内容"),
        ("marker-h2", "## 构建：验证中"),
        ("marker-h3", "### t"),
        ("marker-lone-hash", "###"),
        ("marker-hash-only", "#"),
        ("ws-runs", "a  b\t\nc   验证"),
        ("ws-leading-trailing", "  leading and trailing  "),
        ("nbsp-trailing", "a\u{00A0}"),
        ("zwj-plain", "a\u{200D}b c"),
        ("interior-asterisks", "x**y** z"),
        ("long-headline", String(repeating: "长", count: 60) + "：detail"),
        ("limit-80", String(repeating: "x", count: 100) + "：tail 验证"),
        ("headline-48", String(repeating: "y", count: 48) + "：d"),
        ("headline-49", String(repeating: "y", count: 49) + "：d"),
        ("double-sep", "a：b: c：d"),
        ("trailing-sep", "abc："),
        ("trailing-colon-space", "abc: "),
        ("empty", ""),
        ("ws-only", "   "),
        // Review F4: U+200B is in Foundation whitespacesAndNewlines on BOTH
        // toolchains but is not Unicode White_Space (stdlib isWhitespace
        // excludes it) — trim runs must mirror Foundation, the collapse
        // machine's strict set must mirror the stdlib.
        ("zwsp-trailing", "a\u{200B}"),
        ("zwsp-interior", "a\u{200B}b"),
        ("zwsp-leading", "\u{200B}a 验证"),
        ("zwsp-colon-mix", "：\u{200B}：x"),
    ]
    // Inputs whose collapse/delimiter strict triggers must retire the entry
    // to the from-scratch path — equality must hold through the retirement.
    let strictCorpus: [(label: String, text: String)] = [
        ("nbsp-interior", "a\u{00A0}b"),
        ("ideographic-space", "a\u{3000}b"),
        ("binding-after-ws", "a \u{0301}b"),
        ("prepend-before-ws", "a\u{0600} b"),
        ("fuser-thai", "a \u{0E33}b"),
        ("skin-tone", "a \u{1F3FB}b"),
        ("bold-prefix", "**bold** 验证"),
        ("nested-bold-head", "## # **x"),
        ("delim-binding-successor", "h：\u{0301}x"),
        // Review F3: the rejected "# " marker routes ws+binding into the
        // collapse machine's strict trigger (retire, still equal).
        ("marker-binding-mark", "# \u{0301}x"),
    ]

    var engaged = 0
    var strictConfirmed = 0
    var phaseCommittedSeen = 0
    var delimFrontierSeen = 0
    // Corpus items containing scalars with canonical duals (U+FA55 → 突,
    // NFC/NFD pairs): earlier checks' canonical-keyed table insertions make
    // the from-scratch oracle return the FIRST-STORED encoding — a history
    // dependence the base product already has. Canonical == remains the
    // contract; byte comparison is disabled for exactly these items.
    let canonicalAmbiguous: Set<String> = ["compat-ideograph"]
    for item in incrementalCorpus {
        let cache = try grow(item.text, label: item.label,
                             byteCompare: !canonicalAmbiguous.contains(item.label))
        if let entryID = try progressEntryID(textMessages([item.text])),
           let stats = cache.commentaryStats(entryID: entryID) {
            if stats.observations > 0, !stats.strict { engaged += 1 }
            if stats.phaseCommittedBytes > 0 { phaseCommittedSeen += 1 }
            if stats.delimFrontier > 0 { delimFrontierSeen += 1 }
            precondition(!stats.strict, "non-strict corpus item retired the derivator [\(item.label)]")
        }
    }
    for item in strictCorpus {
        let cache = try grow(item.text, label: item.label)
        if let entryID = try progressEntryID(textMessages([item.text])),
           let stats = cache.commentaryStats(entryID: entryID), stats.strict {
            strictConfirmed += 1
        }
    }

    // ---- explicit multi-observation sequences (review reproductions) -----
    // Prefix growth alone cannot express re-encoding or whole-string marker
    // shapes: scalar growth through "**"/"# " prefixes legitimately retires
    // strict BEFORE any binding rejection is reached, so the review-F3
    // shapes arrive as whole-string observations.
    let reviewSequences: [(label: String, steps: [[String]], varyMetadata: Bool)] = [
        ("review-F1-colon", [["# # ："], ["# # ：x"]], false),
        ("review-F1-colon-space", [["# # : "], ["# # : x"]], false),
        ("review-F3-marker-bind", [["# \u{0301}x"], ["# \u{0301}xy"]], false),
        ("review-F3-bold-bind", [["**\u{0301}x"], ["**\u{0301}xy"], ["**\u{0301}xy验证"]], false),
        ("review-F4-zwsp", [["a"], ["a\u{200B}"], ["a\u{200B}b"]], false),
    ]
    for item in reviewSequences {
        let cache = NarrativeTextCache()
        try run(item.steps, cache: cache, label: item.label, varyMetadata: item.varyMetadata,
                byteCompare: !item.varyMetadata)
    }
    // The F2 reproduction proper: a byte-level NFC↔NFD re-encoding mid-stream
    // (built from explicit escapes so the two encodings are guaranteed
    // distinct regardless of source-file normalization) with metadata churn
    // so the steps cache never masks the derivator's byte-prefix
    // classification. Byte comparison is off here (canonical-table encoding
    // history, see run()); canonical equality plus a follow-up growth step
    // still kill any state corruption: the pre-fix code produced "éxx".
    do {
        let cache = NarrativeTextCache()
        try run([["e\u{0301}"], ["e\u{0301}x"], ["\u{00E9}x"], ["\u{00E9}xy"], ["e\u{0301}xyz"]],
                cache: cache, label: "review-F2-canonical-reencode", varyMetadata: true, byteCompare: false)
    }

    // Kind-priority flip, spelled out: at "a: b" the ": " kind passes its
    // gate and wins; once "：" appears with a <=48 headline and nonempty
    // detail, the FULLWIDTH kind outranks it again — gates must never freeze.
    do {
        let cache = NarrativeTextCache()
        let sequence = ["a", "a:", "a: ", "a: b", "a: b：", "a: b：c"].map { [$0] }
        try run(sequence, cache: cache, label: "kind-priority-steps")
        let final = try snapshot(textMessages(["a: b：c"]), cache: cache)
        let stage = final.stages.first { $0.narrative.source == .commentary }?.narrative
        precondition(stage?.subject == "a: b" && stage?.detail == "c",
                     "kind priority must re-evaluate per observation, got \(String(describing: stage))")
    }

    // ---- reseed shapes ----------------------------------------------------
    // (The multi-part defensive gate and the two-step reseed-then-seed
    // contract are internal to CommentaryDerivation; they are covered
    // end-to-end by the edit/shrink sequences below, whose reseed counters
    // must be positive while every observation stays equal.)
    var reseedsSeen = 0
    do {
        // Mid-stream EDIT of the growing part (non-prefix) → reseed.
        let cache = NarrativeTextCache()
        try run([
            ["构建"],
            ["构建中"],
            ["完全不同的正文：验证"],
            ["完全不同的正文：验证继续"],
        ], cache: cache, label: "edit-reseed")
        if let entryID = try progressEntryID(textMessages(["完全不同的正文：验证继续"])),
           let stats = cache.commentaryStats(entryID: entryID) {
            reseedsSeen += stats.reseeds
            precondition(stats.reseeds > 0, "a non-prefix edit must reseed")
        }
    }
    do {
        // Shrink + regrow shapes → reseed, still equal at every observation.
        let cache = NarrativeTextCache()
        try run([
            ["稳定：增长"],
            ["单"],
            ["单段继续 read"],
        ], cache: cache, label: "shrink-regrow")
        if let entryID = try progressEntryID(textMessages(["单段继续 read"])),
           let stats = cache.commentaryStats(entryID: entryID) {
            reseedsSeen += stats.reseeds
        }
    }

    // ---- anti-blind ------------------------------------------------------
    precondition(observations > 600, "fuzz must actually run, got \(observations) observations")
    precondition(engaged >= 20, "derivator must engage on the incremental corpus, got \(engaged)")
    precondition(strictConfirmed >= 8, "strict triggers must demonstrably retire entries, got \(strictConfirmed)")
    precondition(phaseCommittedSeen > 0, "phase scan must commit below the holdback")
    precondition(delimFrontierSeen > 0, "delimiter scan must advance its frontier")
    precondition(reseedsSeen > 0, "reseed path must run")
    print("PASS: commentary derivator — \(observations) differential observations "
        + "(engaged \(engaged), strict-retired \(strictConfirmed), reseeds \(reseedsSeen)) "
        + "equal to the from-scratch path (byte-level except canonical-table re-encodings)")
}
