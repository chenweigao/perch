import Foundation
import WorkbenchCore

/// Pins the round-30 cross-instance entry cache (v2 = review + Codex P2 fixes).
///
/// Part 1 — mechanism: injective length-prefixed byte-exact keys (an NFC and
/// an NFD query are distinct nodes; a canonical key would return the wrong
/// query's hits; an embedded-NUL field pair that collides under a plain zero
/// separator is pinned distinct), the round-12 verification predicate as the
/// ONLY reuse gate (edited or re-encoded messages must NOT reuse — a
/// skip-verification mutation dies here), exact retention-inclusive admission
/// accounting (payload + key + query bytes — Codex P2), generation-guarded
/// store (a locale notification landing mid-build refuses the stale payload —
/// review finding), concrete LRU (touch-retention + victim identity),
/// oversized payload AND oversized key refusal against a non-empty table,
/// locale-generation invalidation through the real notification, removeAll,
/// and single-copy accounting under a concurrent same-key storm.
///
/// Part 2 — end-to-end purity through the public find-bar API over the
/// round-27 corpus (NFC/NFD variants, byte-identical duplicate source in its
/// own message, display math, URLs, code): FOUR regimes must agree at both
/// canonical and per-hit UTF-8 byte level — budget-0 caches on all three
/// tiers (nothing stored anywhere: the pre-round-27/30/32 product exactly),
/// shared cold, fresh, shared warm. Staleness across instances: a same-ID edit
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
    func payload(_ text: String, query: String = "q",
                 hits: [ConversationSearchHit] = []) -> ConversationEntryCache.Payload {
        .init(messages: entryMessages, sources: [text], text: text as NSString,
              sourceEnds: [(text as NSString).length + 1], role: .assistant,
              isRunning: false, query: query, options: ConversationFindOptions(), hits: hits)
    }

    // byte-exact query keys: NFC vs NFD queries are DISTINCT nodes
    let nfcQ = "caf\u{00E9}", nfdQ = "cafe\u{0301}"
    precondition(nfcQ == nfdQ && Array(nfcQ.utf8) != Array(nfdQ.utf8), "fixture: canonically equal, bytes distinct")
    let opts = ConversationFindOptions()
    let kNFC = ConversationEntryCache.key(entryID: "e0", query: nfcQ, options: opts, isRunning: false)
    let kNFD = ConversationEntryCache.key(entryID: "e0", query: nfdQ, options: opts, isRunning: false)
    precondition(kNFC != kNFD, "NFC and NFD queries must be distinct cache keys")
    // key field separation + injectivity for NUL-containing fields (a plain
    // zero separator collides on these two pairs — the v1 encoding dies here)
    precondition(ConversationEntryCache.key(entryID: "a", query: "bc", options: opts, isRunning: false)
                 != ConversationEntryCache.key(entryID: "ab", query: "c", options: opts, isRunning: false),
                 "key must separate entryID from query bytes")
    precondition(ConversationEntryCache.key(entryID: "a\u{0}b", query: "c", options: opts, isRunning: false)
                 != ConversationEntryCache.key(entryID: "a", query: "b\u{0}c", options: opts, isRunning: false),
                 "key must be injective for embedded NULs (zero-separator ambiguity)")
    // Canonically equal, SAME-byte-length queries: combining marks in
    // different canonical order. Length-prefixed keys make NFC/NFD (different
    // lengths) distinct even under a canonical comparison — the v2
    // canonical-string-key mutant SURVIVED until this case was added. Only
    // byte-wise key equality refuses the reorder pair.
    let orderA = "a\u{0301}\u{0327}"  // acute (CCC 230) then cedilla (CCC 202)
    let orderB = "a\u{0327}\u{0301}"  // canonical reordering of orderA
    precondition(orderA == orderB && orderA.utf8.count == orderB.utf8.count
                 && !Array(orderA.utf8).elementsEqual(orderB.utf8),
                 "fixture: canonically equal, equal length, distinct bytes")
    precondition(ConversationEntryCache.key(entryID: "e0", query: orderA, options: opts, isRunning: false)
                 != ConversationEntryCache.key(entryID: "e0", query: orderB, options: opts, isRunning: false),
                 "canonically-equal reorder queries must be distinct keys (byte-wise equality only)")
    // DICTIONARY-LEVEL retrieval pin: distinct key BYTES are necessary but
    // not sufficient — conflation would happen inside the table's Key
    // equality, which a canonical-comparison mutant keeps correct at the
    // byte-builder level (the v3 canonical-string-key mutant survived the
    // byte-level assertion above; only retrieval through the table catches
    // it). Store under orderA's key; orderB's key must NOT retrieve it.
    let reorderCache = ConversationEntryCache()
    let kOrderA = ConversationEntryCache.key(entryID: "e0", query: orderA, options: opts, isRunning: false)
    let kOrderB = ConversationEntryCache.key(entryID: "e0", query: orderB, options: opts, isRunning: false)
    reorderCache.store(payload: payload("重排文本", query: orderA), forKey: kOrderA,
                       generation: reorderCache.generationNow)
    precondition(reorderCache.payload(forKey: kOrderB, messages: windowA[1...]) == nil,
                 "a canonically-equal reorder query must NOT retrieve the other query's node (dictionary-level conflation)")
    precondition(reorderCache.payload(forKey: kOrderA, messages: windowA[1...]) != nil,
                 "the stored key itself must still retrieve")
    var regexOpts = ConversationFindOptions(); regexOpts.regex = true
    precondition(ConversationEntryCache.key(entryID: "e", query: "q", options: opts, isRunning: false)
                 != ConversationEntryCache.key(entryID: "e", query: "q", options: regexOpts, isRunning: false))
    precondition(ConversationEntryCache.key(entryID: "e", query: "q", options: opts, isRunning: false)
                 != ConversationEntryCache.key(entryID: "e", query: "q", options: opts, isRunning: true))

    // store + verified reuse + exact RETENTION-INCLUSIVE accounting (Codex P2)
    let basic = ConversationEntryCache()
    let p0 = payload("渲染文本", query: nfcQ, hits: [.init(entryID: "e0", occurrence: 0, excerpt: "摘录")])
    basic.store(payload: p0, forKey: kNFC, generation: basic.generationNow)
    let cost0 = ConversationEntryCache.admissionCost(of: p0, forKey: kNFC)
    precondition(cost0 == ConversationEntryCache.estimatedCost(of: p0) + kNFC.count + nfcQ.utf8.count,
                 "admission cost must include key and query bytes")
    // hand-computed full formula on the text-only fixture (pins every term of
    // the convention, including the recursive JSONValue walk being zero here;
    // round-32 v3 closure: structural element storage at MemoryLayout stride
    // and part fileId bytes are terms of the convention too — the review
    // probes measured multi-MB fileId/offset/element retentions inside tiny
    // accounted costs under the v5 formula)
    var manual = p0.text.length * 2
    manual += p0.sources.count * MemoryLayout<String>.stride
    manual += p0.sourceEnds.count * MemoryLayout<Int>.stride
    manual += p0.hits.count * MemoryLayout<ConversationSearchHit>.stride
    manual += p0.messages.count * MemoryLayout<KimiMessage>.stride
    for source in p0.sources { manual += source.utf8.count }
    for hit in p0.hits { manual += hit.excerpt.utf8.count }
    for m in entryMessages {
        manual += m.id.utf8.count + m.role.utf8.count + m.createdAt.utf8.count
        manual += m.content.count * MemoryLayout<KimiPart>.stride
        if let md = m.metadata { manual += ConversationEntryCache.jsonValueSize(md) }
        for part in m.content {
            manual += part.type.utf8.count
            if let t = part.text { manual += t.utf8.count }
            if let th = part.thinking { manual += th.utf8.count }
            if let n = part.name { manual += n.utf8.count }
            if let tn = part.toolName { manual += tn.utf8.count }
            if let tc = part.toolCallId { manual += tc.utf8.count }
            if let fid = part.fileId { manual += fid.utf8.count }
            if let i = part.input { manual += ConversationEntryCache.jsonValueSize(i) }
            if let o = part.output { manual += ConversationEntryCache.jsonValueSize(o) }
            if let src = part.source { manual += ConversationEntryCache.jsonValueSize(src) }
        }
    }
    precondition(ConversationEntryCache.estimatedCost(of: p0) == manual,
                 "exact cost formula: \(ConversationEntryCache.estimatedCost(of: p0)) != \(manual)")
    precondition(basic.estimatedByteCount == cost0,
                 "exact cost accounting: \(basic.estimatedByteCount) != \(cost0)")
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

    // budget-0 stores nothing (the no-cache oracle regime)
    let zero = ConversationEntryCache(byteBudget: 0)
    zero.store(payload: p0, forKey: kNFC, generation: zero.generationNow)
    precondition(zero.estimatedByteCount == 0 && zero.payload(forKey: kNFC, messages: windowA[1...]) == nil,
                 "budget-0 cache must store nothing")

    // concrete LRU with admission-cost arithmetic (equal-length keys keep it exact)
    let pB = payload("乙文本")
    let pC = payload("丙文本")
    let kB = ConversationEntryCache.key(entryID: "eB", query: "q", options: opts, isRunning: false)
    let kC = ConversationEntryCache.key(entryID: "eC", query: "q", options: opts, isRunning: false)
    let kA2 = ConversationEntryCache.key(entryID: "eA", query: "q", options: opts, isRunning: false)
    precondition(kA2.count == kB.count && kB.count == kC.count, "uniform key lengths")
    let aCost = ConversationEntryCache.admissionCost(of: p0, forKey: kA2)
    let bCost = ConversationEntryCache.admissionCost(of: pB, forKey: kB)
    let cCost = ConversationEntryCache.admissionCost(of: pC, forKey: kC)
    precondition(bCost == cCost, "B and C payloads are the same size")
    let two = ConversationEntryCache(byteBudget: aCost + bCost)
    two.store(payload: p0, forKey: kA2, generation: two.generationNow)
    two.store(payload: pB, forKey: kB, generation: two.generationNow)
    precondition(two.estimatedByteCount == aCost + bCost)
    _ = two.payload(forKey: kA2, messages: windowA[1...])  // touch A
    two.store(payload: pC, forKey: kC, generation: two.generationNow)  // over budget → evicts B
    precondition(two.payload(forKey: kA2, messages: windowA[1...]) != nil, "touched A must survive")
    precondition(two.payload(forKey: kB, messages: windowA[1...]) == nil, "B was the LRU victim (reversed order dies)")
    precondition(two.payload(forKey: kC, messages: windowA[1...]) != nil, "C must stay (evicting the new insert dies)")
    precondition(two.estimatedByteCount <= aCost + bCost)

    // oversized PAYLOAD against a NON-EMPTY table: refused, sentinel untouched
    let sentinelCache = ConversationEntryCache(byteBudget: aCost + 10)
    sentinelCache.store(payload: p0, forKey: kA2, generation: sentinelCache.generationNow)
    let huge = payload(String(repeating: "长", count: 5000))
    precondition(ConversationEntryCache.admissionCost(of: huge, forKey: kB) > aCost + 10)
    sentinelCache.store(payload: huge, forKey: kB, generation: sentinelCache.generationNow)
    precondition(sentinelCache.estimatedByteCount == aCost, "oversized must not change accounting")
    precondition(sentinelCache.payload(forKey: kA2, messages: windowA[1...]) != nil, "sentinel must survive")

    // oversized KEY (Codex P2 demo shape): the retained key alone exceeds the
    // whole budget — refused, never admitted-then-evicted
    let tinyBudget = ConversationEntryCache(byteBudget: 64)
    let longQuery = String(repeating: "查", count: 200)  // 600 UTF-8 bytes
    let longKey = ConversationEntryCache.key(entryID: "e0", query: longQuery, options: opts, isRunning: false)
    let pLong = payload("小载荷", query: longQuery)
    precondition(ConversationEntryCache.admissionCost(of: pLong, forKey: longKey) > 64)
    tinyBudget.store(payload: pLong, forKey: longKey, generation: tinyBudget.generationNow)
    precondition(tinyBudget.estimatedByteCount == 0,
                 "a key larger than the budget must be refused: \(tinyBudget.estimatedByteCount)")

    // message JSONValue payload retention (closure-review finding): a node
    // whose rendered surface is tiny but whose retained messages carry a
    // huge tool input must NOT fit a small budget — v4 counted ~77B while
    // retaining megabytes. The recursive jsonValueSize walk makes the
    // admission cost see it; the payload-fields-exclusion mutant (v4 cost
    // formula) dies here.
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
    precondition(ConversationEntryCache.estimatedCost(of: heavyPayload) >= 12000,
                 "the tool-input JSONValue tree must dominate the cost: \(ConversationEntryCache.estimatedCost(of: heavyPayload))")
    let heavyCache = ConversationEntryCache(byteBudget: 128)
    let heavyKey = ConversationEntryCache.key(entryID: "h1", query: "q", options: opts, isRunning: false)
    heavyCache.store(payload: heavyPayload, forKey: heavyKey, generation: heavyCache.generationNow)
    precondition(heavyCache.estimatedByteCount == 0
                 && heavyCache.payload(forKey: heavyKey, messages: heavyWindow[1...]) == nil,
                 "message JSONValue payload must count against the budget (multi-MB-in-128B shape refused)")

    // part fileId retention (round-32 v3 closure, review probe REVIEW_FILE_ID):
    // an arbitrary-size field the v5 formula missed — a payload whose only
    // heavy surface is fileId must NOT fit a small budget.
    let fileIdWindow = try messages([
        ["id": "f0", "role": "user", "created_at": "000001",
         "content": [["type": "text", "text": "q"]]],
        ["id": "f1", "role": "assistant", "created_at": "000002",
         "content": [["type": "text", "text": "a", "file_id": String(repeating: "重", count: 4000)]]],
    ])
    let fileIdPayload = ConversationEntryCache.Payload(
        messages: fileIdWindow, sources: ["a"], text: "a" as NSString,
        sourceEnds: [2], role: .assistant, isRunning: false, query: "q",
        options: opts, hits: [])
    precondition(ConversationEntryCache.estimatedCost(of: fileIdPayload) >= 12000,
                 "the fileId bytes must dominate the cost: \(ConversationEntryCache.estimatedCost(of: fileIdPayload))")
    let fileIdCache = ConversationEntryCache(byteBudget: 128)
    let fileIdKey = ConversationEntryCache.key(entryID: "f1", query: "q", options: opts, isRunning: false)
    fileIdCache.store(payload: fileIdPayload, forKey: fileIdKey, generation: fileIdCache.generationNow)
    precondition(fileIdCache.estimatedByteCount == 0
                 && fileIdCache.payload(forKey: fileIdKey, messages: fileIdWindow[1...]) == nil,
                 "fileId payload must count against the budget (review REVIEW_FILE_ID shape refused)")
    // sourceEnds offset array retention (review probe REVIEW_OFFSETS)
    let offsetsPayload = ConversationEntryCache.Payload(
        messages: [], sources: [], text: "" as NSString,
        sourceEnds: Array(repeating: 0, count: 4096), role: .assistant,
        isRunning: false, query: "q", options: opts, hits: [])
    precondition(ConversationEntryCache.estimatedCost(of: offsetsPayload)
                 >= 4096 * MemoryLayout<Int>.stride,
                 "the offset array's element storage must count")
    let offsetsCache = ConversationEntryCache(byteBudget: 256)
    let offsetsKey = ConversationEntryCache.key(entryID: "o1", query: "q", options: opts, isRunning: false)
    offsetsCache.store(payload: offsetsPayload, forKey: offsetsKey, generation: offsetsCache.generationNow)
    precondition(offsetsCache.estimatedByteCount == 0,
                 "a multi-KB offset array must not fit a 256B budget (review REVIEW_OFFSETS shape refused)")

    // locale generation: notification drops every node
    let locale = ConversationEntryCache()
    locale.store(payload: p0, forKey: kNFC, generation: locale.generationNow)
    precondition(locale.payload(forKey: kNFC, messages: windowA[1...]) != nil)
    NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    precondition(locale.estimatedByteCount == 0 && locale.payload(forKey: kNFC, messages: windowA[1...]) == nil,
                 "the locale notification must drop every node")

    // generation-guarded store: a notification landing DURING an outside-lock
    // rebuild must make store() refuse the stale payload (review finding; v1
    // had no generation parameter and a stale-locale build could enter the
    // fresh generation — the RenderedSourceCache insert-guard contract).
    let racing = ConversationEntryCache()
    let capturedGeneration = racing.generationNow
    NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    racing.store(payload: p0, forKey: kNFC, generation: capturedGeneration)
    precondition(racing.estimatedByteCount == 0 && racing.payload(forKey: kNFC, messages: windowA[1...]) == nil,
                 "store must refuse a payload built under a superseded generation")
    racing.store(payload: p0, forKey: kNFC, generation: racing.generationNow)
    precondition(racing.estimatedByteCount == cost0, "store under the current generation must succeed")

    // removeAll (diagnostic; no generation bump)
    let removable = ConversationEntryCache()
    removable.store(payload: p0, forKey: kNFC, generation: removable.generationNow)
    removable.removeAll()
    precondition(removable.estimatedByteCount == 0 && removable.payload(forKey: kNFC, messages: windowA[1...]) == nil)

    // concurrency smoke + single-copy accounting (uniform key lengths)
    let concurrent = ConversationEntryCache()
    let shared = payload("共享文本")
    // key ids k0…k24 have DIFFERENT byte lengths (k10+ gain a byte), so the
    // expectation sums each key's own admission cost.
    let expected = (0..<25).reduce(0) { acc, i in
        acc + ConversationEntryCache.admissionCost(
            of: shared,
            forKey: ConversationEntryCache.key(entryID: "k\(i)", query: "q", options: opts, isRunning: false))
    }
    DispatchQueue.concurrentPerform(iterations: 8) { worker in
        for i in 0..<100 {
            let key = ConversationEntryCache.key(entryID: "k\((i + worker) % 25)", query: "q",
                                                 options: opts, isRunning: false)
            concurrent.store(payload: shared, forKey: key, generation: concurrent.generationNow)
            _ = concurrent.payload(forKey: key, messages: windowA[1...])
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
        ConversationSearch(renderedCache: RenderedSourceCache(), entryCache: ConversationEntryCache(),
                           prefixCache: ConversationPrefixCache())
    }

    for query in ["caf\u{00E9}", "cafe\u{0301}", "a\u{0301}\u{0327}", "a\u{0327}\u{0301}",
                  "ALPHA", "example.com", "x^2 + 1", "结论"] {
        let oracle = noCache().hits(in: window, query: query, running: false)
        let sharedCold = ConversationSearch().hits(in: window, query: query, running: false)
        let fresh = freshCaches().hits(in: window, query: query, running: false)
        let sharedWarm = ConversationSearch().hits(in: window, query: query, running: false)
        precondition(oracle == sharedCold && sharedCold == fresh && fresh == sharedWarm,
                     "entry cache changed find-bar results for \(query.debugDescription)")
        precondition(byteShape(oracle) == byteShape(sharedWarm) && byteShape(fresh) == byteShape(sharedWarm),
                     "regimes must agree BYTE-for-byte for \(query.debugDescription)")
        if !["a\u{0301}\u{0301}", "a\u{0301}\u{0327}", "a\u{0327}\u{0301}"].contains(query) {
            precondition(!oracle.hits.isEmpty, "non-vacuous: \(query.debugDescription)")
        }
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

    print("PASS: entry cache — injective length-prefixed byte-exact keys (NUL-collision pair, canonical-reorder pair AND dictionary-level reorder-retrieval refusal pinned), round-12 verification as the only reuse gate (same-ID edit and NFD rebuild refused), exact retention-inclusive admission accounting (payload incl. recursive message JSONValue trees + fileId + offset/element-stride storage + key + query bytes — Codex P2 + closure-review + round-32 v3 closure, hand-computed formula pinned; REVIEW_FILE_ID/REVIEW_OFFSETS shapes refused), generation-guarded store (stale-locale build refused), budget-0 stores nothing, concrete LRU (touch/victim/new-insert), oversized payload AND oversized key refusal against a non-empty table, locale-generation invalidation, removeAll, 8x100 concurrency with single-copy accounting, and four-regime (budget-0 oracle/shared-cold/fresh/shared-warm) find-bar equality on 6 queries at canonical AND byte level plus cross-instance staleness and running-flag isolation")
}
