import Foundation
import WorkbenchCore

/// Round 20: this pin was designed for a byte-keyed `NarrativeTextCache`
/// candidate (raw-UTF-8 table keys replacing `String`'s canonical
/// NFC-normalizing hash, ~50% of the narrative stage when the tail text is
/// multi-KB). In-context screening rejected that candidate: the bench's
/// tails are ≤280 bytes, where the NFC-hash share collapses to ~8% and the
/// stage is dominated by per-call L() locale resolution instead — the
/// candidate was reverted and the round continued on that mechanism.
/// The pin is KEPT (round-10 precedent: pins of existing behavior survive
/// the candidate they were built for): it densely covers the SHIPPED
/// String-keyed tables — snapshot golden over 1,500 fuzz texts captured on
/// the unmodified product, canonical-pair equality, repeat-hit stability,
/// marker stripping, limit separation and the whitespace-only no-stage rule.
///
/// The golden corpus drives commentary (progress) entries only, so every
/// serialized headline/subject/detail comes from the cleaned corpus text —
/// never from L()-localized fallback labels — keeping the digest
/// locale-independent and CI-enforceable. The corpus avoids URL shapes so no
/// link backend can feed the digest (round-16/17 lesson); clean()'s
/// Foundation trims are exercised on ASCII whitespace plus U+00A0, whose
/// cross-platform agreement the four-way capture verified before embedding
/// (4e46d66eff016205 on Mac/Linux × base/candidate). It also excludes
/// canonical-variant pairs: with String keys they share one entry and return
/// the first-computed byte form, so a byte-keyed variant would legitimately
/// diverge in bytes while staying canonically equal — pinned structurally by
/// the NFC/NFD case below instead (round-17 precedent).
func checkNarrativeByteKeyedTables() throws {
    func messages(_ value: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: value))
    }
    func user(_ id: String) -> [String: Any] {
        ["id": id, "role": "user", "created_at": "", "content": [["type": "text", "text": "第 20 轮问题"]]]
    }
    func progress(_ id: String, _ text: String) -> [String: Any] {
        ["id": id, "role": "assistant", "created_at": "", "content": [["type": "text", "text": text]]]
    }
    func snapshot(for text: String, id: String = "p") throws -> ActivityNarrativeSnapshot {
        let entries = ConversationTimelineEntry.make(try messages([user("u"), progress(id, text)]), isRunning: true)
        return ActivityNarrativeProjection.make(entries: entries, tools: [:], isRunning: true)
    }
    func ser(_ s: ActivityNarrativeSnapshot) -> String {
        var out = "turn:" + (s.turnID ?? "-") + ";"
        for stage in s.stages {
            let n = stage.narrative
            out += "st{id:\(n.stageID)|ph:\(n.phase.rawValue)|subj:\(n.subject)|hl:\(n.headline)"
                + "|det:\(n.detail ?? "-")|src:\(n.source.rawValue)|life:\(n.lifecycle.rawValue)"
                + "|rev:\(n.revision)|ev:\(n.evidenceIDs.joined(separator: ","))"
                + "|en:\(stage.entryIDs.joined(separator: ","))|tl:\(stage.toolIDs.joined(separator: ","))"
                + "|cl:\(stage.closed)};"
        }
        out += "map{" + s.entryStageIDs.keys.sorted()
            .map { "\($0)=\(s.entryStageIDs[$0] ?? "-")" }.joined(separator: ",") + "}"
        return out
    }
    func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    // --- structural: canonical coherence under byte keys ---
    // NFC "é" and NFD "e"+U+0301 are byte-distinct, canonically equal: with
    // byte keys they occupy separate table entries; the snapshots must still
    // compare equal (String's canonical ==), which is the invariant that
    // makes the recompute unobservable.
    let nfc = "验证 é accent 测试"
    let nfd = "验证 e\u{0301} accent 测试"
    precondition(Array(nfc.utf8) != Array(nfd.utf8), "pair must be byte-distinct")
    let snapNFC = try snapshot(for: nfc, id: "nfc")
    let snapNFD = try snapshot(for: nfd, id: "nfc")   // same entry id: only text differs
    precondition(snapNFC == snapNFD, "canonically equal texts must yield equal snapshots")
    precondition(snapNFC.current?.phase == .validating, "keyword phase survives cleaning")

    // Byte-identical repeat: second call hits the byte-keyed tables and must
    // return an identical snapshot (cache-hit correctness).
    let again = try snapshot(for: nfc, id: "nfc")
    precondition(again == snapNFC, "repeat lookup must be identical")

    // Markers and separators: clean() strips leading markers, narrativeText
    // splits on "："/": " — all through the byte-keyed tables.
    let marked = try snapshot(for: "### **结论**：全部通过 测试", id: "m")
    let headline = marked.current?.headline ?? ""
    precondition(!headline.contains("###") && !headline.contains("**"), "markers stripped: \(headline)")
    precondition(marked.current?.detail != nil, "colon splits headline and detail")

    // Limit separation via the tool path: localHeadline cleans the compact
    // target with limit 80, so a >80-char target truncates with an ellipsis
    // while a short target does not — distinct CleanKey.limit values must not
    // collide in the byte-keyed table. The assertion is on the ellipsis, so
    // it stays locale-independent (the label prefix goes through L()).
    func readSnapshot(_ path: String, id: String) throws -> ActivityNarrativeSnapshot {
        let callRaw: [String: Any] = ["id": "m-\(id)", "role": "assistant", "created_at": "", "content": [[
            "type": "tool_use", "tool_call_id": id, "tool_name": "Read",
            "input": ["path": path]]]]
        let entries = ConversationTimelineEntry.make(try messages([user("u"), callRaw]), isRunning: true)
        let tool = VisibleTool(id: id, name: "Read", input: .object(["path": .string(path)]),
                               output: .string("out"), status: .returned)
        return ActivityNarrativeProjection.make(entries: entries, tools: [id: tool], isRunning: true)
    }
    let longPath = "/project/" + String(repeating: "长", count: 90)
    let longToolSnap = try readSnapshot(longPath, id: "t-long")
    precondition(longToolSnap.current?.headline.hasSuffix("…") == true, "long tool target truncates")
    precondition((longToolSnap.current?.headline.count ?? 999) <= 80 + 8,
                 "truncated headline stays bounded")
    let shortToolSnap = try readSnapshot("/project/短.swift", id: "t-short")
    precondition(shortToolSnap.current?.headline.hasSuffix("…") == false, "short tool target untouched")

    // Whitespace-only text yields no stage (clean empties it): the tables
    // cache the empty result under its own byte key without inventing rows.
    let blank = try snapshot(for: "  \n\t\u{00A0} ", id: "b")
    precondition(blank.stages.isEmpty, "whitespace-only progress makes no stage")

    // --- fuzz corpus golden ---
    // The corpus deliberately contains NO canonically-equal variant pairs
    // (only precomposed U+00E9, no "e"+U+0301): with String keys the base
    // tables shared one entry across NFC/NFD variants and returned the
    // first-computed variant's byte form, while byte keys give each variant
    // its own entry — a legal byte-form divergence that is unobservable
    // through canonical ==, hashing and rendering, so it is pinned by the
    // structural NFC/NFD case above instead of tearing the single golden
    // (round-17 precedent for legitimate divergence).
    let pieces = ["说明", "验证测试", "构建", "edit fix", "git commit", "读取 search",
                  "### ", "**", "：", ": ", " ", "\n", "\t", "\u{00A0}", "增量",
                  "\u{00E9}", "…", "🎉", "a", "42", "推进",
                  String(repeating: "长", count: 90), "结论：通过", "分析查看"]
    precondition(!pieces.contains { $0.contains("://") || $0.contains("www") || $0.contains("@") },
                 "corpus must stay clear of URL shapes so one digest holds on every platform")
    var seed: UInt64 = 0x7231_3973_7000_0020
    func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 11
    }
    var corpus: [String] = []
    for _ in 0..<1500 {
        var text = ""
        for _ in 0..<(1 + Int(next() % 6)) { text += pieces[Int(next() % UInt64(pieces.count))] }
        corpus.append(text)
    }
    func digest() throws -> (UInt64, staged: Int, nonMixed: Int) {
        var digest: UInt64 = 0
        var staged = 0, nonMixed = 0
        for (index, text) in corpus.enumerated() {
            let snap = try snapshot(for: text, id: "f\(index)")
            let first = ser(snap)
            // Determinism: the second call is a full cache hit on byte keys.
            let repeatSnap = try snapshot(for: text, id: "f\(index)")
            precondition(ser(repeatSnap) == first,
                         "narrative derivation must be deterministic")
            if !snap.stages.isEmpty { staged += 1 }
            if snap.current?.phase != .mixed && !snap.stages.isEmpty { nonMixed += 1 }
            digest = (digest ^ fnv1a(first)) &* 0x100_0000_01b3
        }
        return (digest, staged: staged, nonMixed: nonMixed)
    }
    let first = try digest()
    precondition(first.staged > 1200, "corpus must densely produce stages, got \(first.staged)")
    precondition(first.nonMixed > 100, "corpus must exercise keyword phases, got \(first.nonMixed)")
    // Golden captured on the UNMODIFIED product (c085fd9 + this pin) and
    // required identical on Mac/Linux × baseline/candidate before embedding:
    // the tables are pure stdlib/Foundation text derivations with no link
    // backend, so ONE value pins every platform and CI can enforce it.
    let expected = "4e46d66eff016205"
    let got = String(format: "%016llx", first.0)
    print("GOLDEN_CAPTURE narrative-byte-key digest: \(got) (staged \(first.staged)/1500, keyword-phased \(first.nonMixed))")
    precondition(got == expected, "narrative byte-key corpus digest changed: \(got) != \(expected)")
    print("PASS: narrative byte-keyed tables preserve snapshots across canonical pairs and 1500 fuzz texts (digest \(got), \(first.staged) staged, \(first.nonMixed) keyword-phased)")
}
