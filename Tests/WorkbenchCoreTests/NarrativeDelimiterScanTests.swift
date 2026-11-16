import Foundation
import WorkbenchCore

/// Pins the round-26 byte-level delimiter scan in `narrativeText`:
/// same-platform differential of the public projection surface (headline /
/// detail of the current narrative) against a verbatim copy of the previous
/// `range(of:)`-based computation, plus the exhaustive canonical-bridge sweep
/// that underpins the scan's completeness argument (no scalar other than the
/// atoms themselves is canonically equal to U+FF1A, U+003A or U+0020, so a
/// byte search cannot miss an occurrence), the separator byte-pattern sync
/// assert, structural boundary cases (Prepend before / binding scalars after
/// each separator — the `.inconclusive` fallback shapes), and a seeded fuzz
/// corpus with unique prefixes so every text is a NarrativeTextCache miss and
/// the scan actually executes.
func checkNarrativeDelimiterScan() throws {
    // MARK: - Verbatim reference: the pre-round-26 computation chain.
    // `clean` copied statement-for-statement (the product's NarrativeTextCache
    // wrapper is value-transparent); `narrativeText` copied with the original
    // grapheme-aware range(of:) loop.

    func referenceClean(_ value: String, limit: Int? = nil) -> String {
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
    func referenceNarrativeText(_ value: String) -> (headline: String, detail: String?) {
        let text = referenceClean(value)
        for separator in ["：", ": "] {
            guard let range = text.range(of: separator) else { continue }
            let headline = referenceClean(String(text[..<range.lowerBound]), limit: 80)
            let detail = referenceClean(String(text[range.upperBound...]))
            if !headline.isEmpty, headline.count <= 48, !detail.isEmpty {
                return (headline, detail)
            }
        }
        return (text, nil)
    }

    // MARK: - Public-path harness (round-22 projectedPhase pattern).

    func messages(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func projected(_ text: String) throws -> (headline: String, detail: String?)? {
        let raw: [[String: Any]] = [
            ["id": "u", "role": "user", "created_at": "", "content": [["type": "text", "text": "u"]]],
            ["id": "p", "role": "assistant", "created_at": "", "content": [["type": "text", "text": text]]],
        ]
        let entries = ConversationTimelineEntry.make(try messages(raw), isRunning: true)
        guard let current = ActivityNarrativeProjection.make(entries: entries, tools: [:], isRunning: true).current
        else { return nil }
        return (current.headline, current.detail)
    }
    /// The projection pipeline around narrativeText, replicated on the
    /// reference side: the progress branch PRE-CLEANS each visible text and
    /// joins with " " before calling narrativeText (ActivityNarrative.swift
    /// ~483-490), and appendStage CLEANS the resulting headline/detail once
    /// more (~530). The differential must compare against the full pipeline,
    /// not narrativeText alone — clean() is not idempotent on fused-cluster
    /// edge shapes (e.g. detail "**" cleans to "" via the marker strip).
    func referenceProjected(_ text: String) -> (headline: String, detail: String?)? {
        let pre = referenceClean(text)
        guard !pre.isEmpty else { return nil }
        let nt = referenceNarrativeText(pre)
        let headline = referenceClean(nt.headline)
        return (headline, nt.detail.map { referenceClean($0) })
    }

    // MARK: - Separator byte-pattern encodings.
    // The assertions pin the literals' expected UTF-8 encodings; they do not
    // access this private table. Source inspection and behavioral differential
    // tests cover the product table. (review F7)

    precondition(Array("：".utf8) == [0xEF, 0xBC, 0x9A], "fullwidth colon UTF-8 pattern drifted")
    precondition(Array(": ".utf8) == [0x3A, 0x20], "colon-space UTF-8 pattern drifted")

    // MARK: - Exhaustive operational canonical-bridge sweep (completeness of
    // the byte search: no hidden occurrences behind different bytes).

    var bridgeCount = 0
    var sweep: UInt32 = 0
    while sweep < 0x110000 {
        if sweep >= 0xD800 && sweep <= 0xDFFF { sweep = 0xE000; continue }
        if let scalar = Unicode.Scalar(sweep) {
            let s = String(scalar)
            for atom in ["：", ":", " "] where s == atom && Array(s.utf8) != Array(atom.utf8) {
                bridgeCount += 1
                print("DELIMITER BRIDGE U+\(String(sweep, radix: 16, uppercase: true)) == \(atom.debugDescription)")
            }
        }
        sweep += 1
    }
    precondition(bridgeCount == 0,
                 "canonical bridges to separator atoms exist (\(bridgeCount)) — byte search is incomplete; route them like round-22 compatibility ranges")

    // MARK: - Structural cases (differential vs reference through projection).

    let structural: [String] = [
        "标题：内容",                       // basic fullwidth split
        "title: detail text",              // basic ascii split
        "no delimiter here",               // absent both
        "：leading fullwidth",             // leading trimmed by clean
        ": leading colon-space",           // leading colon trimmed by clean
        "trailing：",                      // trailing trimmed by clean
        "a：b：c",                          // first occurrence wins
        "a: b: c",                         // first occurrence wins (ascii)
        "a：: b",                           // mixed, fullwidth first
        "a: ：b",                           // mixed, ascii first
        "x\u{0600}：y",                     // Prepend before separator -> inconclusive -> fallback (no match)
        "x\u{0600}: y",                     // Prepend before colon -> fallback
        "标题：\u{0301}内容",               // Extend after separator -> fallback
        "title: \u{0301}detail",           // Extend after the space -> fallback
        "标题：\u{200D}内容",               // ZWJ after separator -> fallback
        "标题：\u{0E33}内容",               // pinned fuser (Sara-Am) after separator -> fallback
        "title: \u{1F3FB}detail",          // pinned fuser (skin tone) after the space -> fallback
        "标题：👍内容",                     // emoji after separator: confirmed match (emoji does not bind)
        "标题：中文内容保持完整",            // CJK after separator: confirmed match
        "### 前缀：内容",                   // marker stripped then split
        "**加粗**: 内容",                   // bold marker stripped then split
        String(repeating: "长", count: 60) + "：detail",   // headline > 48 -> condition fails -> ": " pass -> (text, nil)
        "short：",                          // empty detail after clean -> falls through to (text, nil)
        "：detail",                         // empty headline after clean -> falls through
        "a\u{301}：b",                      // combining mark before separator (binds backward, not forward) -> confirmed
        "👍\u{1F3FB}：内容",                // skin tone fused on emoji base BEFORE separator -> confirmed (modifier not adjacent to separator)
        "colon:no-space then: with space", // ":" without space is not the ascii separator
        "多  空格：内容",                    // collapsed whitespace before separator
        "tab\t分隔: 内容",                  // tab collapsed then split
    ]
    var structuralChecked = 0
    for text in structural {
        let expected = referenceProjected(text)
        let got = try projected(text)
        precondition(got != nil && expected != nil, "projection produced no narrative for \(text.debugDescription)")
        precondition(got?.headline == expected?.headline && got?.detail == expected?.detail,
                     "structural mismatch for \(text.debugDescription): got \(String(describing: got)) want \(String(describing: expected))")
        structuralChecked += 1
    }

    // MARK: - Seeded differential fuzz (unique prefixes keep every text a
    // cache miss so the scan executes; the reference sees the same text).

    let fragments = ["a", "标题", "：", ": ", ":", " ", "x", "\u{0301}", "\u{0600}", "\u{200D}",
                     "\u{0E33}", "\u{1F3FB}", "👍", "中", "### ", "**", "\n", "\t", "detail",
                     "说明", "…", "\u{3000}", "\u{2028}", "é", "e\u{301}", String(repeating: "长", count: 30)]
    var seed: UInt64 = 0x2026_1116_0026_7231
    func next() -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) & 0x7FFF_FFFF)
    }
    var mismatchCount = 0
    var firstMismatch = ""
    var mismatchLog: [String] = []
    // Corpus classification counters (shapes present in the corpus; these are
    // NOT execution counts of the scan's internal branches — round-24 F1
    // discipline): texts containing each separator, texts with a Prepend or
    // binding scalar adjacent to a separator occurrence (fallback shapes),
    // and texts where the reference splits vs returns whole.
    var containsFullwidth = 0, containsColonSpace = 0, adjacentHazard = 0
    var referenceSplit = 0, referenceWhole = 0
    let total = 2000
    for index in 0..<total {
        var text = "z\(index)z "   // unique prefix: cache-miss guarantee
        for _ in 0..<(1 + next() % 24) { text += fragments[next() % fragments.count] }
        guard let expected = referenceProjected(text) else {
            preconditionFailure("reference pipeline produced no narrative for fuzz text \(text.debugDescription)")
        }
        guard let got = try projected(text) else {
            mismatchCount += 1
            if firstMismatch.isEmpty { firstMismatch = "nil projection for index \(index)" }
            continue
        }
        if got.headline != expected.headline || got.detail != expected.detail {
            mismatchCount += 1
            let line = "index \(index) text=\(text.debugDescription) got=(\(got.headline.debugDescription), \(String(describing: got.detail?.debugDescription))) want=(\(expected.headline.debugDescription), \(String(describing: expected.detail?.debugDescription)))"
            if firstMismatch.isEmpty { firstMismatch = line }
            if mismatchLog.count < 5 { mismatchLog.append(line) }
        }
        let cleaned = referenceClean(text)
        if cleaned.contains("：") { containsFullwidth += 1 }
        if cleaned.contains(": ") { containsColonSpace += 1 }
        if cleaned.range(of: "\u{0600}：") != nil || cleaned.range(of: "：\u{0301}") != nil
            || cleaned.range(of: ": \u{0301}") != nil || cleaned.range(of: "：\u{200D}") != nil
            || cleaned.range(of: "：\u{0E33}") != nil || cleaned.range(of: ": \u{1F3FB}") != nil
            || cleaned.range(of: "\u{0600}: ") != nil { adjacentHazard += 1 }
        if expected.detail != nil { referenceSplit += 1 } else { referenceWhole += 1 }
    }
    for line in mismatchLog { print("DELIMITER-SCAN MISMATCH \(line)") }
    precondition(mismatchCount == 0,
                 "delimiter-scan differential: \(mismatchCount) mismatches; first: \(firstMismatch)")
    precondition(containsFullwidth > 100 && containsColonSpace > 100,
                 "fuzz corpus under-covers separators: \(containsFullwidth)/\(containsColonSpace)")
    precondition(adjacentHazard > 20,
                 "fuzz corpus under-covers boundary-hazard (fallback) shapes: \(adjacentHazard)")
    precondition(referenceSplit > 100 && referenceWhole > 100,
                 "fuzz corpus under-covers outcomes: split \(referenceSplit) whole \(referenceWhole)")

    print("PASS: narrative delimiter scan — exhaustive sweep 0 canonical bridges to separator atoms; "
        + "\(structuralChecked) structural cases + \(total) fuzz texts zero mismatches vs the previous "
        + "range(of:) chain (corpus classification: fullwidth \(containsFullwidth), colon-space "
        + "\(containsColonSpace), boundary-hazard \(adjacentHazard), reference split \(referenceSplit) / whole \(referenceWhole))")
}
