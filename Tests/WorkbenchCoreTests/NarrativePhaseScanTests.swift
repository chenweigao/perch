import Foundation
import WorkbenchCore

/// Round 22: the phase keyword scan moved from `lowercased()` + up to 32
/// grapheme-aware `contains` searches to a single byte pass with
/// proven-boundary fast accepts and a canonical fallback for
/// boundary-inconclusive matches (NarrativePhaseScan). Three-layer pin:
///
/// 1. Exhaustive scalar bridge sweep: the no-false-negative argument rests on
///    "the only non-ASCII scalar whose lowercased form is pure ASCII is
///    U+212A (KELVIN SIGN → 'k'), and no keyword contains 'k'". Both halves
///    are asserted here — the sweep over all 1,112,064 valid scalars, and a
///    static check of the keyword list.
/// 2. In-run differential fuzz (round-16 v2 pattern — version-robust, no
///    golden needed): the reference predicate chain (verbatim copy of the
///    replaced code) versus the shipped projection over adversarial texts —
///    keywords in every case pattern, GB9b Prepend adjacency (platform-
///    divergent in the OLD predicate; the fallback must reproduce each
///    platform's own behavior, so the differential runs per platform against
///    the same-platform reference), Extend/ZWJ adjacency, interior combining
///    marks, İ/Kelvin bridges, CJK mixing. Corpus texts are clean-stable
///    (no whitespace/markers/edge colons) so the phase under test is
///    computed from exactly the injected text.
/// 3. The pre-existing narrative golden (4e46d66eff016205) covers the messy
///    end-to-end corpus (markers, whitespace, NBSP, emoji, ZWJ, Prepend
///    pieces) and must pass unchanged.
func checkNarrativePhaseSinglePass() throws {
    // --- 1. exhaustive scalar bridge sweep ---
    var bridges: [UInt32] = []
    var value: UInt32 = 0
    while value <= 0x10FFFF {
        if !(value >= 0xD800 && value <= 0xDFFF), let scalar = Unicode.Scalar(value) {
            let lowered = String(scalar).lowercased()
            if lowered.utf8.allSatisfy({ $0 < 0x80 }) {
                bridges.append(value)
            }
        }
        value += 1
    }
    let unexpected = bridges.filter { $0 >= 0x80 && $0 != 0x212A }
    precondition(unexpected.isEmpty,
                 "non-ASCII scalars lowering to pure ASCII beyond U+212A: \(unexpected.prefix(8).map { String(format: "U+%04X", $0) })")
    precondition(bridges.contains(0x212A) && String(Unicode.Scalar(0x212A)!).lowercased() == "k",
                 "U+212A must lowercase to ASCII 'k'")
    precondition(bridges.allSatisfy { $0 < 0x80 || $0 == 0x212A }, "sweep consistency")

    // The keyword list (mirrored from the product table) must not contain 'k'
    // in any case — the only bridge scalar lowers to 'k', so no keyword can
    // gain bytes from lowercasing a non-ASCII scalar.
    let keywordList = ["test", "build", "lint", "verify", "测试", "构建", "验证", "检查",
                       "edit", "implement", "write", "fix", "修改", "实现", "修复", "编写",
                       "git", "commit", "merge", "integrat", "提交", "合并", "整合", "冲突",
                       "read", "search", "inspect", "explor", "读取", "搜索", "查看", "分析"]
    precondition(keywordList.count == 32)
    precondition(!keywordList.contains { $0.utf8.contains(0x6B) || $0.utf8.contains(0x4B) },
                 "a keyword contains 'k' — the Kelvin bridge argument breaks")

    // --- reference implementation: verbatim copy of the replaced chain ---
    func referencePhase(_ text: String) -> ActivityNarrativePhase {
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

    // --- projection path helper (commentary entries keep clean() identity) ---
    func messages(_ value: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: value))
    }
    func projectedPhase(_ text: String) throws -> ActivityNarrativePhase? {
        let raw: [[String: Any]] = [
            ["id": "u", "role": "user", "created_at": "", "content": [["type": "text", "text": "u"]]],
            ["id": "p", "role": "assistant", "created_at": "", "content": [["type": "text", "text": text]]],
        ]
        let entries = ConversationTimelineEntry.make(try messages(raw), isRunning: true)
        return ActivityNarrativeProjection.make(entries: entries, tools: [:], isRunning: true).current?.phase
    }

    // --- structural: every keyword maps to its category; priority holds ---
    let expectations: [(String, ActivityNarrativePhase)] = [
        ("test", .validating), ("BUILD", .validating), ("Lint", .validating), ("verify", .validating),
        ("测试", .validating), ("构建完成", .validating), ("验证", .validating), ("检查", .validating),
        ("edit", .editing), ("IMPLEMENT", .editing), ("write", .editing), ("fix", .editing),
        ("修改", .editing), ("实现", .editing), ("修复", .editing), ("编写", .editing),
        ("git", .integrating), ("COMMIT", .integrating), ("merge", .integrating), ("integrat", .integrating),
        ("提交", .integrating), ("合并", .integrating), ("整合", .integrating), ("冲突", .integrating),
        ("read", .exploring), ("SEARCH", .exploring), ("inspect", .exploring), ("explor", .exploring),
        ("读取", .exploring), ("搜索", .exploring), ("查看", .exploring), ("分析", .exploring),
        ("git commit 后 running tests", .validating),        // validating outranks integrating
        ("edit then merge", .editing),                        // editing outranks integrating
        ("read the merge notes", .integrating),               // integrating outranks exploring
        ("普通推进说明", .mixed),
    ]
    for (text, expected) in expectations {
        let got = try projectedPhase(text)
        precondition(got == expected, "phase(\(text)) = \(String(describing: got)), expected \(expected)")
        precondition(referencePhase(text) == expected, "reference disagreement on structural case \(text)")
    }

    // --- 2. differential fuzz ---
    let pieces = ["test", "TEST", "build", "verify", "git", "COMMIT", "merge", "edit", "write",
                  "read", "search", "explor", "integrat", "lint", "fix", "implement", "inspect",
                  "测试", "构建", "验证", "检查", "修改", "实现", "修复", "编写",
                  "提交", "合并", "整合", "冲突", "读取", "搜索", "查看", "分析",
                  "tes", "tesing", "commitx", "xcommit", "re", "gitx", "est", "esting",
                  "\u{0600}test", "\u{0600}git", "\u{06DD}merge", "\u{0600}测试", "\u{08E2}read",
                  "test\u{0308}", "git\u{0301}", "测试\u{0308}", "read\u{200D}",
                  "te\u{0301}st", "ver\u{0308}ify", "edi\u{0301}t",
                  "\u{0130}test", "ED\u{0130}T", "\u{212A}test", "\u{212A}ommit", "\u{212A}git",
                  "🎉test🎉", "test🎉", "🎉git",
                  "推进", "说明", "abc", "xyz", "正文", "English"]
    precondition(!pieces.contains { $0.contains("://") || $0.contains("www") || $0.contains("@") },
                 "corpus must stay clear of URL shapes")
    var seed: UInt64 = 0x7231_3973_7000_0022
    func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 11
    }
    var counts: [ActivityNarrativePhase: Int] = [:]
    var adversarial = 0
    for index in 0..<2000 {
        var text = ""
        for _ in 0..<(1 + Int(next() % 4)) { text += pieces[Int(next() % UInt64(pieces.count))] }
        // clean()-stability guard: reject generated texts that clean() would alter
        if text != text.trimmingCharacters(in: .whitespacesAndNewlines) { continue }
        if text.hasPrefix("#") || text.hasPrefix("**") { continue }
        let expected = referencePhase(text)
        let got = try projectedPhase(text)
        precondition(got == expected,
                     "differential mismatch #\(index) on \(text.debugDescription): scan=\(String(describing: got)) reference=\(expected)")
        counts[expected, default: 0] += 1
        if text.unicodeScalars.contains(where: { $0.value == 0x0600 || $0.value == 0x06DD || $0.value == 0x08E2
                || $0.value == 0x0308 || $0.value == 0x0301 || $0.value == 0x200D || $0.value == 0x0130 || $0.value == 0x212A }) {
            adversarial += 1
        }
    }
    precondition(adversarial > 200, "corpus must densely hit fusion/boundary corners, got \(adversarial)")
    for required in [ActivityNarrativePhase.validating, .editing, .integrating, .exploring, .mixed] {
        precondition((counts[required] ?? 0) > 20, "phase \(required) underrepresented: \(counts[required] ?? 0)")
    }
    print("PASS: phase single-pass scan — scalar bridge sweep (only U+212A), 32 keywords verified k-free, differential fuzz zero mismatches (\(adversarial) adversarial texts, categories \(counts.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: " ")))")
}
