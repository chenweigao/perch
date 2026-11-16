import Foundation
import WorkbenchCore

/// Pins the round-32 cross-instance prefix cache.
///
/// Part 1 — mechanism: the reused round-30 key encoding at the PREFIX table
/// level (NFC/NFD-distinct queries; the canonical-reorder pair refused by
/// DICTIONARY-LEVEL retrieval, the round-30 v4 lesson — pins are placed at
/// the layer a mutant actually breaks), the round-12 window predicate as the
/// ONLY reuse gate (same-count edit, NFD rebuild and count change must all
/// refuse), reference adoption (a repeated verified lookup returns the SAME
/// immutable node), exact retention-inclusive admission accounting with a
/// hand-computed formula (window walk + node hit excerpts + every entry
/// payload's full round-30 cost + its entry-ID dictionary key + node key +
/// query bytes; the deliberate window/entries double count is part of the
/// convention), replace
/// accounting under one key, generation-guarded store, budget-0 oracle,
/// concrete LRU, oversized node AND oversized key refusal, heavy JSONValue
/// retention (window AND payload trees counted), locale invalidation,
/// removeAll, and single-copy accounting under a concurrent same-key storm.
///
/// Part 2 — end-to-end purity through the public find-bar API over the
/// round-27 corpus: FOUR regimes (budget-0 on ALL THREE tiers = the
/// pre-round-27/30/32 product exactly, shared cold, fresh, shared warm) must
/// agree at canonical AND per-hit UTF-8 byte level; the shared-warm regime
/// must be genuinely served by a stored node (non-vacuity); the staleness
/// matrix (same-count prefix edit, options change, running flag, turn-
/// boundary advance across instances AND within one instance that adopted a
/// shared node — exercising the payload→Entry conversion path) must equal
/// the budget-0 oracle byte-for-byte.
func checkConversationPrefixCache() throws {
    func messages(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    let windowP = try messages([
        ["id": "u0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "第一问"]]],
        ["id": "a0", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": "caf\u{00E9} 结论甲"]]],
    ])
    // Same-count edit: a0's text changes; reuse must be refused.
    let windowPEdited = try messages([
        ["id": "u0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "第一问"]]],
        ["id": "a0", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": "caf\u{00E9} 结论乙"]]],
    ])
    // Canonically equal but byte-different rebuild: sameSearchableWindow's
    // rendered-bytes tier must refuse reuse (round-12/30 reasoning).
    let windowPNFD = try messages([
        ["id": "u0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "第一问"]]],
        ["id": "a0", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": "cafe\u{0301} 结论甲"]]],
    ])

    // MARK: Part 1 — mechanism

    let opts = ConversationFindOptions()
    let entryPayload = ConversationEntryCache.Payload(
        messages: Array(windowP[1...]), sources: ["渲染文本"], text: "渲染文本" as NSString,
        sourceEnds: [5], role: .assistant, isRunning: false, query: "q",
        options: opts, hits: [])
    let nodeHits = [ConversationSearchHit(entryID: "text:a0:0", occurrence: 0, excerpt: "摘录")]
    func store(_ cache: ConversationPrefixCache, query: String = "q",
               options: ConversationFindOptions = opts,
               source: [KimiMessage] = windowP,
               hits: [ConversationSearchHit] = nodeHits,
               entries: [String: ConversationEntryCache.Payload] = ["text:a0:0": entryPayload]) -> [UInt8] {
        let key = ConversationEntryCache.key(entryID: "", query: query, options: options, isRunning: false)
        cache.store(source: source, query: query, options: options, hits: hits,
                    entries: entries, forKey: key, generation: cache.generationNow)
        return key
    }

    // key surface: the prefix key IS round-30's encoding with an empty
    // entryID — NFC and NFD queries are distinct nodes.
    let nfcQ = "caf\u{00E9}", nfdQ = "cafe\u{0301}"
    precondition(nfcQ == nfdQ && Array(nfcQ.utf8) != Array(nfdQ.utf8), "fixture: canonically equal, bytes distinct")
    let kNFC = ConversationEntryCache.key(entryID: "", query: nfcQ, options: opts, isRunning: false)
    let kNFD = ConversationEntryCache.key(entryID: "", query: nfdQ, options: opts, isRunning: false)
    precondition(kNFC != kNFD, "NFC and NFD queries must be distinct prefix keys")
    // DICTIONARY-LEVEL retrieval pin at the PREFIX table (round-30 v4
    // lesson: byte-builder assertions are the wrong layer — a canonical
    // Key.== mutant keeps key() bytes distinct and dies only here). The
    // reorder pair is canonically equal, SAME byte length, distinct bytes.
    let orderA = "a\u{0301}\u{0327}"  // acute (CCC 230) then cedilla (CCC 202)
    let orderB = "a\u{0327}\u{0301}"  // canonical reordering of orderA
    precondition(orderA == orderB && orderA.utf8.count == orderB.utf8.count
                 && !Array(orderA.utf8).elementsEqual(orderB.utf8),
                 "fixture: canonically equal, equal length, distinct bytes")
    let reorderCache = ConversationPrefixCache()
    let kOrderA = store(reorderCache, query: orderA)
    let kOrderB = ConversationEntryCache.key(entryID: "", query: orderB, options: opts, isRunning: false)
    precondition(reorderCache.node(forKey: kOrderB, prefix: windowP[...]) == nil,
                 "a canonically-equal reorder query must NOT retrieve the other query's node (dictionary-level conflation)")
    precondition(reorderCache.node(forKey: kOrderA, prefix: windowP[...]) != nil,
                 "the stored key itself must still retrieve")

    // store + verified retrieval + exact RETENTION-INCLUSIVE accounting
    let basic = ConversationPrefixCache()
    let kBasic = store(basic, query: nfcQ)
    let cost = basic.estimatedByteCount
    guard let node = basic.node(forKey: kBasic, prefix: windowP[...]) else {
        fatalError("verified prefix lookup must return the node")
    }
    precondition(node.hits == nodeHits && node.entryCount == 1
                 && node.payload(entryID: "text:a0:0")?.text == "渲染文本"
                 && node.payload(entryID: "missing") == nil,
                 "the node exposes its stored hits and payloads")
    // REFERENCE adoption: a repeated verified lookup returns the SAME
    // immutable node — instances adopt by reference, no per-entry copying.
    precondition(basic.node(forKey: kBasic, prefix: windowP[...]) === node,
                 "a verified lookup must adopt the stored node BY REFERENCE")
    precondition(cost == ConversationPrefixCache.admissionCost(of: node, forKey: kBasic),
                 "the table accounts exactly the admission cost")
    precondition(cost == ConversationPrefixCache.estimatedCost(of: node) + kBasic.count + nfcQ.utf8.count,
                 "admission cost must include key and query bytes (Codex P2 pattern)")
    // hand-computed full formula: window walk + node hit excerpts + every
    // payload's round-30 cost (the double count of window messages inside
    // payloads is part of the convention — conservative by design).
    var manualWindow = 0
    for m in windowP {
        manualWindow += m.id.utf8.count + m.role.utf8.count + m.createdAt.utf8.count
        if let md = m.metadata { manualWindow += ConversationEntryCache.jsonValueSize(md) }
        for part in m.content {
            manualWindow += part.type.utf8.count
            if let t = part.text { manualWindow += t.utf8.count }
            if let th = part.thinking { manualWindow += th.utf8.count }
            if let n = part.name { manualWindow += n.utf8.count }
            if let tn = part.toolName { manualWindow += tn.utf8.count }
            if let tc = part.toolCallId { manualWindow += tc.utf8.count }
            if let i = part.input { manualWindow += ConversationEntryCache.jsonValueSize(i) }
            if let o = part.output { manualWindow += ConversationEntryCache.jsonValueSize(o) }
            if let src = part.source { manualWindow += ConversationEntryCache.jsonValueSize(src) }
        }
    }
    precondition(ConversationPrefixCache.windowCost(windowP) == manualWindow,
                 "windowCost must equal the hand-computed per-message walk")
    let manual = manualWindow
        + nodeHits.reduce(0) { $0 + $1.excerpt.utf8.count }
        + ConversationEntryCache.estimatedCost(of: entryPayload)
        + "text:a0:0".utf8.count  // the retained dictionary key (entry ID)
    precondition(ConversationPrefixCache.estimatedCost(of: node) == manual,
                 "exact node cost formula: \(ConversationPrefixCache.estimatedCost(of: node)) != \(manual)")

    // the verification predicate is the ONLY reuse gate:
    // (a) same-count edited window — value tier fails;
    precondition(basic.node(forKey: kBasic, prefix: windowPEdited[...]) == nil,
                 "a same-count edited prefix must NOT reuse the stored node (skip-verification mutations die here)")
    // (b) canonically-equal NFD rebuild — value tier passes, rendered-bytes
    // tier must refuse;
    precondition(basic.node(forKey: kBasic, prefix: windowPNFD[...]) == nil,
                 "a canonically-equal but byte-different rebuild must NOT reuse (rendered-bytes tier)")
    // (c) count change (turn boundary) — refused before the structural walk.
    precondition(basic.node(forKey: kBasic, prefix: windowP[..<1]) == nil,
                 "a count mismatch must NOT reuse (turn-boundary moves refuse)")

    // budget-0 stores nothing (the no-cache oracle regime)
    let zero = ConversationPrefixCache(byteBudget: 0)
    let kZero = store(zero)
    precondition(zero.estimatedByteCount == 0 && zero.node(forKey: kZero, prefix: windowP[...]) == nil,
                 "budget-0 prefix cache must store nothing")

    // replace accounting under one key: the old node's cost is subtracted
    let replaceable = ConversationPrefixCache()
    let kReplace = store(replaceable, hits: nodeHits)
    let firstCost = replaceable.estimatedByteCount
    let biggerHits = [ConversationSearchHit(entryID: "text:a0:0", occurrence: 0,
                                            excerpt: String(repeating: "摘", count: 100))]
    _ = store(replaceable, hits: biggerHits)
    precondition(replaceable.estimatedByteCount > firstCost, "the replacement is larger")
    guard let replacedNode = replaceable.node(forKey: kReplace, prefix: windowP[...]) else {
        fatalError("the replaced node must retrieve")
    }
    precondition(replaceable.estimatedByteCount == ConversationPrefixCache.admissionCost(of: replacedNode, forKey: kReplace),
                 "replace must keep accounting single-copy (old cost subtracted)")

    // concrete LRU with admission-cost arithmetic (qA/qB/qC are same-byte-
    // length queries over identical node shapes ⇒ uniform costs)
    let probeEach = ConversationPrefixCache()
    _ = store(probeEach, query: "qA")
    let costEach = probeEach.estimatedByteCount
    let two = ConversationPrefixCache(byteBudget: 2 * costEach)
    let kA = store(two, query: "qA")
    let kB = store(two, query: "qB")
    precondition(two.estimatedByteCount == 2 * costEach,
                 "uniform node costs: \(two.estimatedByteCount) != \(2 * costEach)")
    _ = two.node(forKey: kA, prefix: windowP[...])  // touch A
    _ = store(two, query: "qC")                    // over budget → evicts B
    let kC = ConversationEntryCache.key(entryID: "", query: "qC", options: opts, isRunning: false)
    precondition(two.node(forKey: kA, prefix: windowP[...]) != nil, "touched A must survive")
    precondition(two.node(forKey: kB, prefix: windowP[...]) == nil, "B was the LRU victim (reversed order dies)")
    precondition(two.node(forKey: kC, prefix: windowP[...]) != nil, "C must stay (evicting the new insert dies)")
    precondition(two.estimatedByteCount <= 2 * costEach)

    // oversized NODE against a NON-EMPTY table: refused, sentinel untouched
    let sentinelCache = ConversationPrefixCache(byteBudget: 2 * costEach + 10)
    let kSentinel = store(sentinelCache, query: "qA")
    let sentinelBytes = sentinelCache.estimatedByteCount
    let hugeHits = [ConversationSearchHit(entryID: "text:a0:0", occurrence: 0,
                                          excerpt: String(repeating: "长", count: 5000))]
    _ = store(sentinelCache, query: "qB", hits: hugeHits)
    precondition(sentinelCache.estimatedByteCount == sentinelBytes, "oversized node must not change accounting")
    precondition(sentinelCache.node(forKey: kSentinel, prefix: windowP[...]) != nil, "sentinel must survive")

    // oversized KEY (Codex P2 demo shape): the retained key alone exceeds
    // the whole budget — refused, never admitted-then-evicted
    let tinyBudget = ConversationPrefixCache(byteBudget: 64)
    let longQuery = String(repeating: "查", count: 200)  // 600 UTF-8 bytes
    _ = store(tinyBudget, query: longQuery)
    precondition(tinyBudget.estimatedByteCount == 0,
                 "a key larger than the budget must be refused: \(tinyBudget.estimatedByteCount)")

    // heavy JSONValue retention (round-30 v5 lesson applied at BOTH retained
    // field classes): the node keeps the window messages AND the entry
    // payloads, each possibly carrying huge tool-input trees. Both count —
    // the payload-fields-exclusion and window-exclusion mutants die here.
    let heavyWindow = try messages([
        ["id": "h0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "q"]]],
        ["id": "h1", "role": "assistant", "created_at": "000002",
         "content": [["type": "tool_use", "tool_call_id": "t1", "tool_name": "Write",
                      "input": ["content": String(repeating: "重", count: 4000)]]]],
    ])
    let heavyPayload = ConversationEntryCache.Payload(
        messages: heavyWindow, sources: ["Write"], text: "小" as NSString,
        sourceEnds: [2], role: .tool, isRunning: false, query: "q",
        options: opts, hits: [])
    let heavyKey = ConversationEntryCache.key(entryID: "", query: "q", options: opts, isRunning: false)
    // window walk alone ≥ 12000 (the tool input), payload adds its own copy
    let tightBudget = ConversationPrefixCache(byteBudget: 23_999)
    tightBudget.store(source: heavyWindow, query: "q", options: opts, hits: [],
                      entries: ["activity:tool:t1": heavyPayload],
                      forKey: heavyKey, generation: tightBudget.generationNow)
    precondition(tightBudget.estimatedByteCount == 0
                 && tightBudget.node(forKey: heavyKey, prefix: heavyWindow[...]) == nil,
                 "window AND payload JSONValue trees must count against the budget (multi-MB-in-24KB shape refused)")
    let heavyOK = ConversationPrefixCache()
    heavyOK.store(source: heavyWindow, query: "q", options: opts, hits: [],
                  entries: ["activity:tool:t1": heavyPayload],
                  forKey: heavyKey, generation: heavyOK.generationNow)
    guard let heavyNode = heavyOK.node(forKey: heavyKey, prefix: heavyWindow[...]) else {
        fatalError("the heavy node must be admitted by the default budget")
    }
    precondition(ConversationPrefixCache.estimatedCost(of: heavyNode) >= 24_000,
                 "the double-counted heavy trees must dominate the cost: \(ConversationPrefixCache.estimatedCost(of: heavyNode))")

    // locale generation: notification drops every node
    let locale = ConversationPrefixCache()
    let kLocale = store(locale)
    precondition(locale.node(forKey: kLocale, prefix: windowP[...]) != nil)
    NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    precondition(locale.estimatedByteCount == 0 && locale.node(forKey: kLocale, prefix: windowP[...]) == nil,
                 "the locale notification must drop every node")

    // generation-guarded store: a notification landing DURING an
    // outside-lock rebuild must make store() refuse the stale node
    // (round-27 insert guard / round-30 v2 contract).
    let racing = ConversationPrefixCache()
    let capturedGeneration = racing.generationNow
    NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    racing.store(source: windowP, query: nfcQ, options: opts, hits: nodeHits,
                 entries: ["text:a0:0": entryPayload], forKey: kBasic, generation: capturedGeneration)
    precondition(racing.estimatedByteCount == 0 && racing.node(forKey: kBasic, prefix: windowP[...]) == nil,
                 "store must refuse a node built under a superseded generation")
    racing.store(source: windowP, query: nfcQ, options: opts, hits: nodeHits,
                 entries: ["text:a0:0": entryPayload], forKey: kBasic, generation: racing.generationNow)
    precondition(racing.estimatedByteCount > 0, "store under the current generation must succeed")

    // removeAll (diagnostic; no generation bump)
    let removable = ConversationPrefixCache()
    let kRemove = store(removable)
    precondition(removable.node(forKey: kRemove, prefix: windowP[...]) != nil)
    removable.removeAll()
    precondition(removable.estimatedByteCount == 0 && removable.node(forKey: kRemove, prefix: windowP[...]) == nil)

    // concurrency smoke + single-copy accounting (query ids k0…k24 have
    // DIFFERENT byte lengths, so the expectation sums each key's own cost)
    let concurrent = ConversationPrefixCache()
    let perNode = ConversationPrefixCache.windowCost(windowP)
        + nodeHits.reduce(0) { $0 + $1.excerpt.utf8.count }
        + ConversationEntryCache.estimatedCost(of: entryPayload)
        + "text:a0:0".utf8.count
    let expected = (0..<25).reduce(0) { acc, i in
        acc + perNode
            + ConversationEntryCache.key(entryID: "", query: "k\(i)", options: opts, isRunning: false).count
            + "k\(i)".utf8.count
    }
    DispatchQueue.concurrentPerform(iterations: 8) { worker in
        for i in 0..<100 {
            let query = "k\((i + worker) % 25)"
            let key = ConversationEntryCache.key(entryID: "", query: query, options: opts, isRunning: false)
            concurrent.store(source: windowP, query: query, options: opts, hits: nodeHits,
                             entries: ["text:a0:0": entryPayload], forKey: key,
                             generation: concurrent.generationNow)
            _ = concurrent.node(forKey: key, prefix: windowP[...])
        }
    }
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
                           entryCache: ConversationEntryCache(byteBudget: 0),
                           prefixCache: ConversationPrefixCache(byteBudget: 0))
    }
    func freshCaches() -> ConversationSearch {
        ConversationSearch(renderedCache: RenderedSourceCache(),
                           entryCache: ConversationEntryCache(),
                           prefixCache: ConversationPrefixCache())
    }

    for query in ["caf\u{00E9}", "cafe\u{0301}", "a\u{0301}\u{0327}", "a\u{0327}\u{0301}",
                  "ALPHA", "example.com", "x^2 + 1", "结论"] {
        let oracle = noCache().hits(in: window, query: query, running: false)
        let sharedCold = ConversationSearch().hits(in: window, query: query, running: false)
        let fresh = freshCaches().hits(in: window, query: query, running: false)
        let sharedWarm = ConversationSearch().hits(in: window, query: query, running: false)
        precondition(oracle == sharedCold && sharedCold == fresh && fresh == sharedWarm,
                     "prefix cache changed find-bar results for \(query.debugDescription)")
        precondition(byteShape(oracle) == byteShape(sharedWarm) && byteShape(fresh) == byteShape(sharedWarm),
                     "regimes must agree BYTE-for-byte for \(query.debugDescription)")
        if !["a\u{0301}\u{0327}", "a\u{0327}\u{0301}"].contains(query) {
            precondition(!oracle.hits.isEmpty, "non-vacuous: \(query.debugDescription)")
        }
    }

    // shared-warm NON-VACUITY: after a default-instance search, the shared
    // prefix table must actually hold a verified node for that (query,
    // options) — kills "the prefix branch never runs" shapes and anchors the
    // A/B claim that reopens are served by the shared node.
    let splitIndex = window.lastIndex(where: \.isUserPrompt) ?? 0
    let warmKey = ConversationEntryCache.key(entryID: "", query: "ALPHA", options: opts, isRunning: false)
    precondition(ConversationPrefixCache.shared.node(forKey: warmKey, prefix: window[..<splitIndex]) != nil,
                 "the shared-warm regime must be served by a stored prefix node (non-vacuous adoption)")

    // staleness matrix against the budget-0 oracle — every reuse gate the
    // shared node could get wrong, each compared byte-for-byte.
    func assertOracleEqual(_ shared: ConversationFindResult, _ oracle: ConversationFindResult, _ label: String) {
        precondition(shared == oracle && byteShape(shared) == byteShape(oracle), label)
    }
    // (a) same-count prefix EDIT across instances: warm on `window`, then a
    // new instance over the edited window must never see the stale node.
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
    assertOracleEqual(ConversationSearch().hits(in: editedWindow, query: "ALPHA", running: false),
                      noCache().hits(in: editedWindow, query: "ALPHA", running: false),
                      "a same-count prefix edit must never be served from a warm node")
    // (b) OPTIONS change over a warm window (case sensitivity flips matches)
    var caseOpts = ConversationFindOptions(); caseOpts.caseSensitive = true
    assertOracleEqual(ConversationSearch().hits(in: window, query: "ALPHA", running: false, options: caseOpts),
                      noCache().hits(in: window, query: "ALPHA", running: false, options: caseOpts),
                      "an options change must not reuse the insensitive node")
    // (c) RUNNING flag over a warm window
    assertOracleEqual(ConversationSearch().hits(in: window, query: "结论", running: true),
                      noCache().hits(in: window, query: "结论", running: true),
                      "the running flag must not cross-contaminate prefix adoption")
    // (d) TURN-BOUNDARY advance across instances: the extended window's
    // prefix (now the whole original window) has no stored node; the rebuild
    // must equal the oracle, and a SECOND new instance then adopts the
    // extended node.
    let extended = try messages([
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
        ["id": "u2", "role": "user", "created_at": "000006",
         "content": [["type": "text", "text": "第 2 轮：请收尾 ALPHA。"]]],
        ["id": "a2", "role": "assistant", "created_at": "000007",
         "content": [["type": "text", "text": "结论：ALPHA 收尾完成，café 已验证。"]]],
    ])
    assertOracleEqual(ConversationSearch().hits(in: extended, query: "ALPHA", running: true),
                      noCache().hits(in: extended, query: "ALPHA", running: true),
                      "a turn-boundary advance must rebuild equal to the oracle")
    assertOracleEqual(ConversationSearch().hits(in: extended, query: "ALPHA", running: true),
                      noCache().hits(in: extended, query: "ALPHA", running: true),
                      "the extended prefix node must serve the next instance identically")
    // (d2) WITHIN-INSTANCE advance after adopting a SHARED node: the second
    // search's prefix rebuild reads previous entries through the
    // payload→Entry conversion path (Entries.shared) — the converted entries
    // must verify and reuse exactly like instance-owned ones. First store
    // the extended (5-message) "结论" node, then let a NEW instance adopt it
    // (.shared), then advance that instance past the adopted node.
    _ = ConversationSearch().hits(in: extended, query: "结论", running: false)  // stores the 5-message node
    let adopting = ConversationSearch()
    _ = adopting.hits(in: extended, query: "结论", running: false)      // adopts the shared node (.shared)
    let advanced = try messages([
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
        ["id": "u2", "role": "user", "created_at": "000006",
         "content": [["type": "text", "text": "第 2 轮：请收尾 ALPHA。"]]],
        ["id": "a2", "role": "assistant", "created_at": "000007",
         "content": [["type": "text", "text": "结论：ALPHA 收尾完成，café 已验证。"]]],
        ["id": "u3", "role": "user", "created_at": "000008",
         "content": [["type": "text", "text": "第 3 轮：最后确认。"]]],
        ["id": "a3", "role": "assistant", "created_at": "000009",
         "content": [["type": "text", "text": "结论：全部完成。"]]],
    ])
    assertOracleEqual(adopting.hits(in: advanced, query: "结论", running: false),
                      noCache().hits(in: advanced, query: "结论", running: false),
                      "a within-instance advance over an ADOPTED shared node must reuse converted entries exactly")
    assertOracleEqual(ConversationSearch().hits(in: advanced, query: "结论", running: false),
                      noCache().hits(in: advanced, query: "结论", running: false),
                      "the advanced prefix must serve the next instance identically")

    print("PASS: prefix cache — round-30 key encoding at prefix-table level (canonical-reorder DICTIONARY-LEVEL retrieval refusal), round-12 window predicate as the only reuse gate (same-count edit / NFD rebuild / count change refused), reference adoption (=== node), exact retention-inclusive accounting (hand-computed window walk + node excerpts + payload costs + entry-ID dictionary keys + node key + query bytes), replace accounting, generation-guarded store, budget-0 oracle, concrete LRU, oversized node AND key refusal, heavy window+payload JSONValue retention (24KB-budget refusal), locale invalidation, removeAll, 8x100 concurrency single-copy accounting, four-regime (all-three-tiers budget-0 oracle/shared-cold/fresh/shared-warm) find-bar equality on 8 queries at canonical AND byte level, shared-warm non-vacuity, and the staleness matrix (prefix edit/options/running/turn-boundary across instances + within-instance advance over an adopted shared node) against the budget-0 oracle")
}
