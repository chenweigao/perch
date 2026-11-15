import Foundation
import WorkbenchCore

/// Round 22: the phase keyword scan moved from `lowercased()` + up to 32
/// grapheme-aware `contains` searches to a single byte pass with
/// proven-boundary fast accepts and a canonical fallback for
/// boundary-inconclusive matches (NarrativePhaseScan). Three-layer pin:
///
/// 1. Exhaustive scalar sweeps: the no-false-negative argument rests on
///    (a) "the only non-ASCII scalar whose lowercased form is pure ASCII is
///    U+212A (KELVIN SIGN → 'k'), and no keyword contains 'k'" and
///    (b) "every scalar CANONICALLY EQUAL to a CJK keyword character lies in
///    the compatibility blocks the scanner detects" (review F1: U+FA55→突,
///    U+FA8E→搜, U+F96A→索 fold under canonical substring search), tested
///    operationally via String's canonical == — the same equality the legacy
///    search uses. Note (re-review F7'): non-ASCII scalars CANONICALLY
///    EQUAL TO ASCII do exist (U+037E→';', U+1FEF→'`', U+212A→'K'), but no
///    keyword contains ';', '`' or 'k'/'K', so no keyword can arise from
///    them — the keyword-specific argument replaces any blanket claim.
///    Both sweeps run over all 1,112,064 valid scalars, plus the static
///    keyword checks.
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
///    end-to-end corpus (markers, whitespace, NBSP, emoji, keyword pieces)
///    and must pass unchanged; the Prepend/combining-mark/ZWJ and
///    compatibility-ideograph corners belong to the differential fuzz below,
///    NOT to that golden (re-review F3' — coverage boundaries stated as
///    they actually are).
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

    // --- 1b. exhaustive canonical-equivalence sweep (review F1) ---
    // Corrected probe finding (re-review F1', byte-level comparison, archived):
    // decomposedStringWithCanonicalMapping DOES change the bytes of
    // compatibility ideographs on BOTH platforms (460 byte-changing scalars in
    // U+F900–FAFF; U+FA55→U+7A81, U+FA8E→U+641C, U+F96A→U+7D22), and the
    // canonical substring search folds them on BOTH ("冲\u{FA55}".contains("冲突")
    // == true). The sweep still tests canonical equivalence OPERATIONALLY via
    // String's canonical == (Set<String> membership) — the same equality the
    // legacy search relies on, independent of decomposition-API behavior:
    // every non-ASCII scalar canonically equal to a CJK keyword character —
    // other than the character itself — must lie inside the compatibility byte
    // ranges the scanner detects (U+2F00–2FFF / U+F900–FAFF / U+2F800–2FFFF).
    // Multi-scalar sequences cannot produce an ideograph under canonical
    // composition (CJK ideographs have no primary composites; Hangul composes
    // syllables), so the scalar sweep is complete; the differential fuzz below
    // covers the combinations empirically.
    let keywordScalars = Set("测试构建验证检查修改实现修复编写提交合并整合冲突读取搜索查看分析".unicodeScalars)
    let keywordCharStrings: Set<String> = Set(keywordScalars.map { String($0) })
    var canonicalBridges = 0
    var scan: UInt32 = 0x80
    while scan <= 0x10FFFF {
        if !(scan >= 0xD800 && scan <= 0xDFFF), let scalar = Unicode.Scalar(scan) {
            if !keywordScalars.contains(scalar), keywordCharStrings.contains(String(scalar)) {
                canonicalBridges += 1
                let detected = (0x2F00...0x2FFF).contains(scan)
                    || (0xF900...0xFAFF).contains(scan)
                    || (0x2F800...0x2FFFF).contains(scan)
                precondition(detected,
                             "U+\(String(scan, radix: 16, uppercase: true)) is canonically equal to a keyword character outside the detected compatibility ranges")
            }
        }
        scan += 1
    }
    precondition(canonicalBridges > 0, "sweep must encounter compatibility bridges (probe: U+FA55/U+FA8E/U+F96A fold under canonical search)")

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

    // Review F1 counterexamples: CJK COMPATIBILITY ideographs canonically
    // fold to keyword characters (U+FA55→突, U+FA8E→搜, U+F96A→索), which
    // the legacy canonical substring search matches but literal keyword
    // bytes do not exist. The scanner must detect the compatibility blocks
    // and defer the whole text to the legacy chain. Each case is asserted
    // against the reference on the same platform (the legacy predicate is
    // itself platform-divergent under GB9b — the differential, not a fixed
    // expectation, is the contract).
    let compatibilityCases = ["QZ0 冲\u{FA55}.", "QZ1 \u{FA8E}索.", "QZ2 搜\u{F96A}.",
                              "QZ4 冲\u{FA55} read.", "QZ5 冲\u{FA55}.", "\u{FA8E}\u{F96A}验证",
                              "test\u{2F00}", "\u{F900}verify", "分析\u{2F800}", "z\u{2FA1F}提交"]
    for (caseIndex, text) in compatibilityCases.enumerated() {
        let expected = referencePhase(text)
        let got = try projectedPhase(text)
        precondition(got == expected,
                     "compatibility-ideograph differential mismatch #\(caseIndex) on \(text.debugDescription): scan=\(String(describing: got)) reference=\(expected)")
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
                  // CJK compatibility ideographs (review F1): canonical folds
                  // into keyword characters without literal keyword bytes.
                  "冲\u{FA55}", "\u{FA8E}索", "搜\u{F96A}", "\u{FA55}", "\u{2F00}", "\u{2F800}", "冲",
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
        // Unique keyword-free prefix: the static text tables survive across
        // calls (a fresh NarrativeTextCache does not clear them — review F2
        // note), so every differential text must be table-cold.
        text = "z\(index)z" + text
        // clean()-stability guard: reject generated texts that clean() would alter
        if text != text.trimmingCharacters(in: .whitespacesAndNewlines) { continue }
        if text.hasPrefix("#") || text.hasPrefix("**") { continue }
        let expected = referencePhase(text)
        let got = try projectedPhase(text)
        precondition(got == expected,
                     "differential mismatch #\(index) on \(text.debugDescription): scan=\(String(describing: got)) reference=\(expected)")
        counts[expected, default: 0] += 1
        if text.unicodeScalars.contains(where: { $0.value == 0x0600 || $0.value == 0x06DD || $0.value == 0x08E2
                || $0.value == 0x0308 || $0.value == 0x0301 || $0.value == 0x200D || $0.value == 0x0130 || $0.value == 0x212A
                || $0.value == 0xFA55 || $0.value == 0xFA8E || $0.value == 0xF96A || $0.value == 0x2F00 || $0.value == 0x2F800 }) {
            adversarial += 1
        }
    }
    precondition(adversarial > 200, "corpus must densely hit fusion/boundary corners, got \(adversarial)")
    for required in [ActivityNarrativePhase.validating, .editing, .integrating, .exploring, .mixed] {
        precondition((counts[required] ?? 0) > 20, "phase \(required) underrepresented: \(counts[required] ?? 0)")
    }
    print("PASS: phase single-pass scan — scalar bridge sweep (only U+212A) + canonical-equivalence sweep (\(canonicalBridges) compatibility bridges, all in detected ranges), 32 keywords verified k-free, differential fuzz zero mismatches (\(adversarial) adversarial texts, categories \(counts.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: " ")))")
}
