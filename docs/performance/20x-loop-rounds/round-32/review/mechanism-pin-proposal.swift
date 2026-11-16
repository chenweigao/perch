    do {
        let probeWindow = try messages([
            ["id": "su0", "role": "user", "created_at": "0",
             "content": [["type": "text", "text": "prompt"]]],
            ["id": "sa0", "role": "assistant", "created_at": "0",
             "content": [["type": "text", "text": "answer"]]],
            ["id": "su1", "role": "user", "created_at": "0",
             "content": [["type": "text", "text": "tail"]]],
        ])
        let query = "NO_MATCH_REVIEW_SENTINEL"
        let key = ConversationEntryCache.key(entryID: "", query: query, options: opts, isRunning: false)
        let cache = ConversationPrefixCache()
        let sentinel = ConversationSearchHit(entryID: "shared-hit-sentinel", occurrence: 0, excerpt: "CACHE-SERVED")
        cache.store(source: Array(probeWindow[..<2]), query: query, options: opts, hits: [sentinel], entries: [:],
                    forKey: key, generation: cache.generationNow)
        let served = ConversationSearch(renderedCache: RenderedSourceCache(byteBudget: 0),
                                        entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: cache)
            .hits(in: probeWindow, query: query, running: false)
        precondition(served.hits.count == 1 && Array(served.hits[0].excerpt.utf8) == Array("CACHE-SERVED".utf8),
                     "mechanism: hits() must consume the injected shared node, not merely leave it retrievable")
        print("REVIEW_SENTINEL_SHARED_HIT consumed=true")

        let payloadCache = ConversationPrefixCache()
        let entry = ConversationTimelineEntry.make(Array(probeWindow[..<2]), isRunning: false)
            .first { $0.messages.contains(where: { $0.id == "sa0" }) }!
        let entrySentinel = ConversationSearchHit(entryID: entry.id, occurrence: 0, excerpt: "CONVERSION-SERVED")
        let payload = ConversationEntryCache.Payload(messages: entry.messages, sources: ["answer"],
            text: "answer" as NSString, sourceEnds: [7], role: .assistant,
            isRunning: false, query: query, options: opts, hits: [entrySentinel])
        payloadCache.store(source: Array(probeWindow[..<2]), query: query, options: opts, hits: [],
                           entries: [entry.id: payload], forKey: key, generation: payloadCache.generationNow)
        let adopting = ConversationSearch(renderedCache: RenderedSourceCache(byteBudget: 0),
                                         entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: payloadCache)
        _ = adopting.hits(in: probeWindow, query: query, running: false)
        let advanced = probeWindow + (try messages([
            ["id": "su2", "role": "user", "created_at": "0",
             "content": [["type": "text", "text": "next turn"]]],
        ]))
        let converted = adopting.hits(in: advanced, query: query, running: false)
        precondition(converted.hits.count == 1 && Array(converted.hits[0].excerpt.utf8) == Array("CONVERSION-SERVED".utf8),
                     "mechanism: advancing over Entries.shared must convert and reuse the stored payload")
        print("REVIEW_SENTINEL_CONVERSION consumed=true")
    }
