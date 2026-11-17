import Foundation
@testable import WorkbenchCore

/// Round 41: differential fuzz pinning the incremental commentary derivator.
///
/// Contract: at EVERY observation of a growing `.progress` entry, the
/// derivator path must produce the exact same ActivityNarrativeSnapshot as
/// the from-scratch path — run through the very same
/// ActivityNarrativeProjection.make() code with the pin-only kill switch
/// (`commentaryDerivationDisabled`) forcing the fallback branch. Sequences
/// grow one Character at a time, so every prefix of every corpus text is an
/// observation point: marker-gate flips, zone/holdback boundaries, phase
/// tail replay at every split, delimiter commitments, gate flips and kind
/// priority switches all execute under comparison.
///
/// Anti-blind: the derivator must demonstrably ENGAGE (observations,
/// committed phase bytes, delimiter frontier), strict-trigger corpus items
/// must demonstrably RETIRE (strict == true, results still equal), and the
/// reseed/transition shapes must demonstrably RUN (counters > 0).
func checkCommentaryDerivation() throws {
    func textMessages(_ texts: [String]) throws -> [KimiMessage] {
        var content: [[String: Any]] = []
        for text in texts { content.append(["type": "text", "text": text]) }
        let raw: [[String: Any]] = [
            ["id": "u1", "role": "user", "created_at": "1", "content": [["type": "text", "text": "检查文件"]]],
            ["id": "a1", "role": "assistant", "created_at": "2", "content": content],
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

    var observations = 0
    func run(_ sequence: [[String]], cache: NarrativeTextCache, label: String) throws {
        for parts in sequence {
            let messages = try textMessages(parts)
            let got = snapshot(messages, cache: cache)
            let want = oracle(messages)
            precondition(got == want,
                "commentary derivator diverged [\(label)] at parts \(parts)\n  got:  \(got)\n  want: \(want)")
            observations += 1
        }
    }
    /// Every scalar prefix of `final`, in order, on one persistent cache.
    func grow(_ final: String, label: String) throws -> NarrativeTextCache {
        let cache = NarrativeTextCache()
        let characters = Array(final)
        var sequence: [[String]] = []
        for count in 0...characters.count { sequence.append([String(characters[0..<count])]) }
        try run(sequence, cache: cache, label: label)
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
    ]

    var engaged = 0
    var strictConfirmed = 0
    var phaseCommittedSeen = 0
    var delimFrontierSeen = 0
    for item in incrementalCorpus {
        let cache = try grow(item.text, label: item.label)
        if let entryID = try progressEntryID(textMessages([item.text])) ,
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

    // ---- defensive gate + reseed shapes ----------------------------------
    var reseedsSeen = 0
    do {
        // A .progress entry is single-part by contract; multi-part input must
        // fall back defensively (direct unit coverage — make() never produces
        // this shape).
        let derivation = CommentaryDerivation()
        if case .step = derivation.observe(parts: ["a", "b"], firstMessageID: "m") {
            preconditionFailure("multi-part entries must fall back to the from-scratch path")
        }
        if case .step(nil) = derivation.observe(parts: [], firstMessageID: "m") {}
        else { preconditionFailure("empty parts must yield the empty-text step") }
        // After the defensive clear, the first single-part observation
        // classifies reseed and defers to from-scratch; the NEXT observation
        // seeds via .growth/.unchanged and engages.
        if case .fallback = derivation.observe(parts: ["验证：细节"], firstMessageID: "m") {}
        else { preconditionFailure("a reseed observation must fall back, not seed") }
        if case .step(let step) = derivation.observe(parts: ["验证：细节"], firstMessageID: "m"), step != nil {}
        else { preconditionFailure("the seeded observation must produce a stage step") }
    }
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
    precondition(observations > 500, "fuzz must actually run, got \(observations) observations")
    precondition(engaged >= 20, "derivator must engage on the incremental corpus, got \(engaged)")
    precondition(strictConfirmed >= 7, "strict triggers must demonstrably retire entries, got \(strictConfirmed)")
    precondition(phaseCommittedSeen > 0, "phase scan must commit below the holdback")
    precondition(delimFrontierSeen > 0, "delimiter scan must advance its frontier")
    precondition(reseedsSeen > 0, "reseed path must run")
    print("PASS: commentary derivator — \(observations) differential observations "
        + "(engaged \(engaged), strict-retired \(strictConfirmed), reseeds \(reseedsSeen)) "
        + "byte-equal to the from-scratch path")
}
