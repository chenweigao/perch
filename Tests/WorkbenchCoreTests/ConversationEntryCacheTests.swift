import Foundation
import WorkbenchCore

/// Pins the round-30 cross-instance entry cache.
///
/// Part 1 — mechanism: byte-exact keys (an NFC and an NFD query are distinct
/// nodes; a canonical key would return the wrong query's hits), the round-12
/// verification predicate as the ONLY reuse gate (edited or re-encoded
/// messages must NOT reuse — a skip-verification mutation dies here), exact
/// payload-inclusive cost accounting, concrete LRU (touch-retention + victim
/// identity), oversized refusal against a non-empty table, locale-generation
/// invalidation through the real notification, removeAll, and single-copy
/// accounting under a concurrent same-key storm.
///
/// Part 2 — end-to-end purity through the public find-bar API over the
/// round-27 corpus (NFC/NFD variants, byte-identical duplicate source in its
/// own message, display math, URLs, code): FOUR regimes must agree at both
/// canonical and per-hit UTF-8 byte level — budget-0 caches on both tiers
/// (nothing stored anywhere: the pre-round-27/30 product exactly), shared
/// cold, fresh, shared warm. Staleness across instances: a same-ID edit
/// after a warm search must produce the edited window's results, never the
/// stale node (the mutation "reuse without verification" dies on the byte
/// comparison against the budget-0 oracle). Query/running/options variations
/// must not cross-contaminate nodes.
func checkConversationEntryCache() throws {
    func messages(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    let windowA = try messages([
        ["id": "u0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "第一问"]]],
        ["id": "a0", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": "caf\u{00E9} 结论甲"]]],
    ])
    // Same-ID edit: a0's text changes; reuse must be refused.
    let windowAEdited = try messages([
        ["id": "u0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "第一问"]]],
        ["id": "a0", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": "caf\u{00E9} 结论乙"]]],
    ])
    // Canonically equal but byte-different rebuild (NFD swap in a rendered
    // field): sameSearchableWindow's rendered-bytes tier must refuse reuse.
    let windowANFD = try messages([
        ["id": "u0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "第一问"]]],
        ["id": "a0", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": "cafe\u{0301} 结论甲"]]],
    ])

    // MARK: Part 1 — mechanism

    let entryMessages = Array(windowA[1...])  // the a0 entry's messages
    func payload(_ text: String, hits: [ConversationSearchHit] = []) -> ConversationEntryCache.Payload {
        .init(messages: entryMessages, sources: [text], text: text as NSString,
              sourceEnds: [(text as NSString).length + 1], role: .assistant,
              isRunning: false, query: "q", options: ConversationFindOptions(), hits: hits)
    }

    // byte-exact query keys: NFC vs NFD queries are DISTINCT nodes
    let nfcQ = "caf\u{00E9}", nfdQ = "cafe\u{0301}"
    precondition(nfcQ == nfdQ && Array(nfcQ.utf8) != Array(nfdQ.utf8), "fixture: canonically equal, bytes distinct")
    let opts = ConversationFindOptions()
    let kNFC = ConversationEntryCache.key(entryID: "e0", query: nfcQ, options: opts, isRunning: false)
    let kNFD = ConversationEntryCache.key(entryID: "e0", query: nfdQ, options: opts, isRunning: false)
    precondition(kNFC != kNFD, "NFC and NFD queries must be distinct cache keys")
    // key field separation: entryID/query boundary and flags are positional
    precondition(ConversationEntryCache.key(entryID: "a", query: "bc", options: opts, isRunning: false)
                 != ConversationEntryCache.key(entryID: "ab", query: "c", options: opts, isRunning: false),
                 "key must separate entryID from query bytes")
    var regexOpts = ConversationFindOptions(); regexOpts.regex = true
    precondition(ConversationEntryCache.key(entryID: "e", query: "q", options: opts, isRunning: false)
                 != ConversationEntryCache.key(entryID: "e", query: "q", options: regexOpts, isRunning: false))
    precondition(ConversationEntryCache.key(entryID: "e", query: "q", options: opts, isRunning: false)
                 != ConversationEntryCache.key(entryID: "e", query: "q", options: opts, isRunning: true))

    // store + verified reuse + exact cost accounting
    let basic = ConversationEntryCache()
    let p0 = payload("渲染文本", hits: [.init(entryID: "e0", occurrence: 0, excerpt: "摘录")])
    basic.store(payload: p0, forKey: kNFC)
    precondition(basic.estimatedByteCount == ConversationEntryCache.estimatedCost(of: p0),
                 "exact cost accounting: \(basic.estimatedByteCount) != \(ConversationEntryCache.estimatedCost(of: p0))")
    guard let got = basic.payload(forKey: kNFC, messages: windowA[1...]) else {
        fatalError("verified reuse must return the payload")
    }
    precondition(got.text == p0.text && got.hits == p0.hits)
    // The verification predicate is the ONLY reuse gate:
    // (a) same-ID edited messages — value tier fails;
    precondition(basic.payload(forKey: kNFC, messages: windowAEdited[1...]) == nil,
                 "same-ID edited messages must NOT reuse the stored node (skip-verification mutations die here)")
    // (b) canonically-equal NFD rebuild — value tier PASSES but the
    // rendered-bytes tier must refuse (round-12 sameRenderedMessages reasoning).
    precondition(basic.payload(forKey: kNFC, messages: windowANFD[1...]) == nil,
                 "a canonically-equal but byte-different rebuild must NOT reuse (rendered-bytes tier)")

    // concrete LRU with payload-inclusive costs
    let lru = ConversationEntryCache(byteBudget: 0)  // refuses everything
    lru.store(payload: p0, forKey: kNFC)
    precondition(lru.estimatedByteCount == 0 && lru.payload(forKey: kNFC, messages: windowA[1...]) == nil,
                 "budget-0 cache must store nothing (the no-cache oracle regime)")
    let c1 = ConversationEntryCache.estimatedCost(of: p0)
    let two = ConversationEntryCache(byteBudget: c1 * 2)
    let pB = payload("乙文本")
    let pC = payload("丙文本")
    let kB = ConversationEntryCache.key(entryID: "eB", query: "q", options: opts, isRunning: false)
    let kC = ConversationEntryCache.key(entryID: "eC", query: "q", options: opts, isRunning: false)
    let kA2 = ConversationEntryCache.key(entryID: "eA", query: "q", options: opts, isRunning: false)
    two.store(payload: p0, forKey: kA2)
    two.store(payload: pB, forKey: kB)
    precondition(two.estimatedByteCount == c1 + ConversationEntryCache.estimatedCost(of: pB))
    _ = two.payload(forKey: kA2, messages: windowA[1...])  // touch A
    two.store(payload: pC, forKey: kC)  // over budget → evicts B (LRU victim)
    precondition(two.payload(forKey: kA2, messages: windowA[1...]) != nil, "touched A must survive")
    precondition(two.payload(forKey: kB, messages: windowA[1...]) == nil, "B was the LRU victim (reversed order dies)")
    precondition(two.payload(forKey: kC, messages: windowA[1...]) != nil, "C must stay (evicting the new insert dies)")
    precondition(two.estimatedByteCount <= c1 * 2)

    // oversized node against a NON-EMPTY table: refused, sentinel untouched
    let sentinelCache = ConversationEntryCache(byteBudget: c1 + 10)
    sentinelCache.store(payload: p0, forKey: kA2)
    let huge = payload(String(repeating: "长", count: 5000))
    precondition(ConversationEntryCache.estimatedCost(of: huge) > c1 + 10)
    sentinelCache.store(payload: huge, forKey: kB)
    precondition(sentinelCache.estimatedByteCount == c1, "oversized must not change accounting")
    precondition(sentinelCache.payload(forKey: kA2, messages: windowA[1...]) != nil, "sentinel must survive")

    // locale generation
    let locale = ConversationEntryCache()
    locale.store(payload: p0, forKey: kNFC)
    precondition(locale.payload(forKey: kNFC, messages: windowA[1...]) != nil)
    NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    precondition(locale.estimatedByteCount == 0 && locale.payload(forKey: kNFC, messages: windowA[1...]) == nil,
                 "the locale notification must drop every node")

    // removeAll (diagnostic; no generation bump)
    let removable = ConversationEntryCache()
    removable.store(payload: p0, forKey: kNFC)
    removable.removeAll()
    precondition(removable.estimatedByteCount == 0 && removable.payload(forKey: kNFC, messages: windowA[1...]) == nil)

    // concurrency smoke + single-copy accounting
    let concurrent = ConversationEntryCache()
    let shared = payload("共享文本")
    DispatchQueue.concurrentPerform(iterations: 8) { worker in
        for i in 0..<100 {
            let key = ConversationEntryCache.key(entryID: "k\((i + worker) % 25)", query: "q",
                                                 options: opts, isRunning: false)
            concurrent.store(payload: shared, forKey: key)
            _ = concurrent.payload(forKey: key, messages: windowA[1...])
        }
    }
    let expected = 25 * ConversationEntryCache.estimatedCost(of: shared)
    precondition(concurrent.estimatedByteCount == expected,
                 "single-copy accounting under concurrent same-key stores: \(concurrent.estimatedByteCount) != \(expected)")

    // MARK: Part 2 — end-to-end purity through the public API

    let nfcAnswer = "结论：caf\u{00E9} 已完成，见 https://example.com/alpha 与 `let x = 1` 以及 $x^2$ 推导。\n\n$$x^2 + 1$$"
    let nfdAnswer = nfcAnswer.decomposedStringWithCanonicalMapping
    let window = try messages([
        ["id": "u0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "第 0 轮：请检查 ALPHA 实现。"]]],
        ["id": "a0", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": nfcAnswer]]],
        ["id": "u1", "role": "user", "created_at": "000003",
         "content": [["type": "text", "text": "第 1 轮：继续推进。"]]],
        ["id": "a1", "role": "assistant", "created_at": "000004",
         "content": [["type": "text", "text": nfdAnswer],
                     ["type": "tool_use", "tool_call_id": "w1", "tool_name": "Write",
                      "input": ["file_path": "/fixture/Out.swift", "content": "let caf\u{00E9} = 1\n"]]],
         ],
        ["id": "repeat-a0", "role": "assistant", "created_at": "000005",
         "content": [["type": "text", "text": nfcAnswer]]],
    ])

    func byteShape(_ result: ConversationFindResult) -> [[UInt8]] {
        result.hits.map { hit in
            var bytes: [UInt8] = []
            bytes.append(contentsOf: hit.entryID.utf8); bytes.append(0)
            bytes.append(contentsOf: hit.excerpt.utf8); bytes.append(0)
            bytes.append(contentsOf: String(hit.occurrence).utf8); bytes.append(0)
            bytes.append(contentsOf: (hit.toolID ?? "").utf8); bytes.append(0)
            bytes.append(contentsOf: String(hit.toolOccurrence ?? -1).utf8)
            return bytes
        }
    }
    func noCache() -> ConversationSearch {
        ConversationSearch(renderedCache: RenderedSourceCache(byteBudget: 0),
                           entryCache: ConversationEntryCache(byteBudget: 0))
    }
    func freshCaches() -> ConversationSearch {
        ConversationSearch(renderedCache: RenderedSourceCache(), entryCache: ConversationEntryCache())
    }

    for query in ["caf\u{00E9}", "cafe\u{0301}", "ALPHA", "example.com", "x^2 + 1", "结论"] {
        let oracle = noCache().hits(in: window, query: query, running: false)
        let sharedCold = ConversationSearch().hits(in: window, query: query, running: false)
        let fresh = freshCaches().hits(in: window, query: query, running: false)
        let sharedWarm = ConversationSearch().hits(in: window, query: query, running: false)
        precondition(oracle == sharedCold && sharedCold == fresh && fresh == sharedWarm,
                     "entry cache changed find-bar results for \(query.debugDescription)")
        precondition(byteShape(oracle) == byteShape(sharedWarm) && byteShape(fresh) == byteShape(sharedWarm),
                     "regimes must agree BYTE-for-byte for \(query.debugDescription)")
        precondition(!oracle.hits.isEmpty, "non-vacuous: \(query.debugDescription)")
    }

    // cross-instance staleness: warm the shared caches, then search a
    // same-ID-EDITED window through a NEW instance — a skip-verification
    // mutation returns the stale node's hits and dies on the oracle compare.
    let editedWindow = try messages([
        ["id": "u0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "第 0 轮：请检查 ALPHA 实现。"]]],
        ["id": "a0", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": "结论：ALPHA 已重写为 BETA 实现。"]]],
        ["id": "u1", "role": "user", "created_at": "000003",
         "content": [["type": "text", "text": "第 1 轮：继续推进。"]]],
        ["id": "a1", "role": "assistant", "created_at": "000004",
         "content": [["type": "text", "text": nfdAnswer],
                     ["type": "tool_use", "tool_call_id": "w1", "tool_name": "Write",
                      "input": ["file_path": "/fixture/Out.swift", "content": "let caf\u{00E9} = 1\n"]]],
         ],
        ["id": "repeat-a0", "role": "assistant", "created_at": "000005",
         "content": [["type": "text", "text": "ALPHA 与 BETA 都在此。"]]],
    ])
    _ = ConversationSearch().hits(in: window, query: "ALPHA", running: false)          // warm
    _ = ConversationSearch().hits(in: window, query: "结论", running: false)          // warm
    let staleCheckShared = ConversationSearch().hits(in: editedWindow, query: "ALPHA", running: false)
    let staleCheckOracle = noCache().hits(in: editedWindow, query: "ALPHA", running: false)
    precondition(staleCheckShared == staleCheckOracle
                 && byteShape(staleCheckShared) == byteShape(staleCheckOracle),
                 "a same-ID edit must never be served from a warm node")
    precondition(staleCheckOracle.hits.contains { $0.excerpt.contains("BETA") },
                 "the edited window must contribute its new hits")
    // running-flag variation must not cross-contaminate
    let runShared = ConversationSearch().hits(in: window, query: "结论", running: true)
    let runOracle = noCache().hits(in: window, query: "结论", running: true)
    precondition(runShared == runOracle && byteShape(runShared) == byteShape(runOracle))

    print("PASS: entry cache — byte-exact (entryID,query,options,running) keys with field separation, round-12 verification as the only reuse gate (same-ID edit and NFD rebuild refused), exact payload-inclusive accounting, budget-0 stores nothing, concrete LRU (touch/victim/new-insert), oversized refusal against a non-empty table, locale-generation invalidation, removeAll, 8x100 concurrency with single-copy accounting, and four-regime (budget-0 oracle/shared-cold/fresh/shared-warm) find-bar equality on 6 queries at canonical AND byte level plus cross-instance staleness and running-flag isolation")
}
