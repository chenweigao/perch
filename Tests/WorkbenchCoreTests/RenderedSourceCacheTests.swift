import Foundation
import WorkbenchCore

/// Pins the round-27 cross-instance rendered-source cache.
///
/// Part 1 — cache mechanism: produce-once semantics, BYTE-EXACT keying (an
/// NFC and an NFD source are distinct entries; a canonical-equality key
/// would conflate them and return the wrong rendering — round 12's
/// sameRenderedUTF8 reasoning), bounded eviction correctness under churn,
/// oversized-source admission refusal, removeAll, and a bounded concurrency
/// smoke (results must be correct under parallel misses; double-render is
/// benign by design and not asserted against).
///
/// Part 2 — end-to-end purity through the public find-bar API: shared-cache
/// instances and fresh-cache instances must produce IDENTICAL
/// ConversationFindResults over a corpus whose sources include NFC and NFD
/// variants of the same text (so a key-conflation defect would change
/// results), a byte-identical duplicate source across turns (the within-pass
/// dedup path — the repeat must add its own occurrence at unchanged offsets),
/// URLs, code and math (the ReplyDocument.parse paths). This is the cache
/// analogue of round 12's warm-vs-fresh reuse invariant.
func checkRenderedSourceCache() throws {
    // MARK: Part 1 — mechanism

    // produce-once
    let basic = RenderedSourceCache()
    var produced = 0
    let first = basic.rendered("caf\u{00E9} 结论") { produced += 1; return "RENDERED" }
    let second = basic.rendered("caf\u{00E9} 结论") { produced += 1; return "OTHER" }
    precondition(first == "RENDERED" && second == "RENDERED" && produced == 1,
                 "cache must serve the stored render without re-producing")

    // byte-exact keys: NFC vs NFD are DIFFERENT entries
    let nfc = "caf\u{00E9}"
    let nfd = "cafe\u{0301}"
    precondition(Array(nfc.utf8) != Array(nfd.utf8) && nfc == nfd,
                 "fixture must be canonically equal with distinct bytes")
    let keying = RenderedSourceCache()
    var keyCalls: [String] = []
    let a1 = keying.rendered(nfc) { keyCalls.append("nfc"); return "A" }
    let b1 = keying.rendered(nfd) { keyCalls.append("nfd"); return "B" }
    let a2 = keying.rendered(nfc) { keyCalls.append("nfc-AGAIN"); return "X" }
    let b2 = keying.rendered(nfd) { keyCalls.append("nfd-AGAIN"); return "Y" }
    precondition(a1 == "A" && b1 == "B" && a2 == "A" && b2 == "B" && keyCalls == ["nfc", "nfd"],
                 "NFC and NFD sources must be distinct cache keys (canonical keys would conflate renders)")

    // bounded eviction under churn: every lookup stays correct, budget holds
    let small = RenderedSourceCache(byteBudget: 512)
    for i in 0..<200 {
        let source = "source-\(i)-" + String(repeating: "x", count: 40)
        precondition(small.rendered(source) { "R\(i)" } == "R\(i)")
    }
    precondition(small.estimatedByteCount <= 512,
                 "budget violated: \(small.estimatedByteCount)")
    for i in 0..<200 {
        let source = "source-\(i)-" + String(repeating: "x", count: 40)
        precondition(small.rendered(source) { "R\(i)" } == "R\(i)",
                     "post-eviction lookup returned the wrong render at \(i)")
    }
    precondition(small.estimatedByteCount <= 512)

    // oversized single source: rendered correctly, never stored
    let tiny = RenderedSourceCache(byteBudget: 64)
    let big = String(repeating: "长", count: 100)
    let before = tiny.estimatedByteCount
    precondition(tiny.rendered(big) { "BIG" } == "BIG")
    precondition(tiny.estimatedByteCount == before, "oversized source must not be stored")
    precondition(tiny.rendered(big) { "BIG-AGAIN" } == "BIG-AGAIN",
                 "oversized source must re-produce on every lookup")

    // removeAll
    let removable = RenderedSourceCache()
    var removes = 0
    _ = removable.rendered("s") { removes += 1; return "v" }
    _ = removable.rendered("s") { removes += 1; return "v" }
    precondition(removes == 1)
    removable.removeAll()
    _ = removable.rendered("s") { removes += 1; return "v" }
    precondition(removes == 2, "removeAll must drop entries")

    // bounded concurrency smoke: parallel misses on overlapping keys must all
    // observe the correct pure value (double renders are benign by design).
    let concurrent = RenderedSourceCache()
    DispatchQueue.concurrentPerform(iterations: 8) { worker in
        for i in 0..<200 {
            let key = "src-\((i + worker) % 50)"
            let value = concurrent.rendered(key) { "V\((i + worker) % 50)" }
            precondition(value == "V\((i + worker) % 50)",
                         "concurrent lookup returned a wrong render")
        }
    }

    // MARK: Part 2 — end-to-end purity through the public API

    func messages(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    let nfcAnswer = "结论：caf\u{00E9} 已完成，见 https://example.com/alpha 与 `let x = 1` 以及 $x^2$ 推导。"
    let nfdAnswer = nfcAnswer.decomposedStringWithCanonicalMapping
    precondition(Array(nfcAnswer.utf8) != Array(nfdAnswer.utf8))
    let window = try messages([
        ["id": "u0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "第 0 轮：请检查 ALPHA 实现。"]]],
        ["id": "a0", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": nfcAnswer]]],
        ["id": "u1", "role": "user", "created_at": "000003",
         "content": [["type": "text", "text": "第 1 轮：继续推进。"]]],
        ["id": "a1", "role": "assistant", "created_at": "000004",
         "content": [["type": "text", "text": nfdAnswer],
                     // Byte-identical duplicate of a0's answer: building this
                     // entry's sources must serve the repeat from the cache
                     // (the within-pass dedup path the bench fixture amplifies)
                     // with unchanged offsets and its own occurrence.
                     ["type": "text", "text": nfcAnswer],
                     ["type": "tool_use", "tool_call_id": "w1", "tool_name": "Write",
                      "input": ["file_path": "/fixture/Out.swift", "content": "let caf\u{00E9} = 1\n"]]],
         ],
    ])
    // Three cache regimes must agree exactly: shared (first, cold), fresh
    // (renders everything itself), shared again (warm reopens).
    for query in ["caf\u{00E9}", "cafe\u{0301}", "ALPHA", "example.com", "x^2", "结论"] {
        let viaSharedCold = ConversationSearch().hits(in: window, query: query, running: false)
        let viaFresh = ConversationSearch(renderedCache: RenderedSourceCache())
            .hits(in: window, query: query, running: false)
        let viaSharedWarm = ConversationSearch().hits(in: window, query: query, running: false)
        precondition(viaSharedCold == viaFresh && viaFresh == viaSharedWarm,
                     "rendered-source cache changed find-bar results for query \(query.debugDescription)")
    }
    // Sanity: the corpus actually produces hits (the equality assertions are
    // vacuous on all-empty results).
    let sanity = ConversationSearch(renderedCache: RenderedSourceCache())
        .hits(in: window, query: "caf\u{00E9}", running: false)
    precondition(!sanity.hits.isEmpty, "fixture must produce hits (non-vacuous pin)")
    let sanityShared = ConversationSearch().hits(in: window, query: "caf\u{00E9}", running: false)
    precondition(!sanityShared.hits.isEmpty && sanityShared.hits == sanity.hits)
    // Within-pass dedup pin: "café" (diacritic-insensitive) matches a0's answer
    // in the first turn and, in the second, a1's NFD answer, its byte-identical
    // duplicate and the Write content — so both turns must contribute hits and
    // the duplicate must add its OWN occurrence. A dedup that corrupted the
    // joined text's offsets would shift occurrences or excerpts.
    precondition(Set(sanity.hits.map(\.entryID)).count >= 2,
                 "both turns must contribute café hits, got \(Set(sanity.hits.map(\.entryID)))")
    precondition(sanity.hits.count >= 3,
                 "the duplicated answer must contribute its own occurrence, got \(sanity.hits.count)")

    print("PASS: rendered-source cache — produce-once, NFC/NFD byte-exact keys, bounded eviction (512B budget, 200-source churn), oversized refusal, removeAll, 8x200 concurrency smoke, shared/fresh/warm find-bar results identical on 6 queries (NFC+NFD corpus, non-vacuous), and within-pass duplicate-source dedup keeping its own occurrence with cross-regime parity")
}
