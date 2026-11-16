    // Review-only executable probes, injected temporarily by run_retention.py.
    do {
        let hugeFileID = String(repeating: "F", count: 8 * 1024 * 1024)
        let retainedWindow = try messages([
            ["id": "fu0", "role": "user", "created_at": "0",
             "content": [["type": "text", "text": "prompt"]]],
            ["id": "fa0", "role": "assistant", "created_at": "0",
             "content": [["type": "text", "text": "answer", "file_id": hugeFileID]]],
            ["id": "fu1", "role": "user", "created_at": "0",
             "content": [["type": "text", "text": "tail"]]],
        ])
        let cache = ConversationPrefixCache(byteBudget: 256)
        var search: ConversationSearch? = ConversationSearch(
            renderedCache: RenderedSourceCache(byteBudget: 0),
            entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: cache)
        _ = search!.hits(in: retainedWindow, query: "z", running: false)
        search = nil
        let key = ConversationEntryCache.key(entryID: "", query: "z", options: opts, isRunning: false)
        let node = cache.node(forKey: key, prefix: retainedWindow[..<2])
        precondition(node != nil, "review fixture must be admitted")
        let retained = node!.source.flatMap(\.content).compactMap(\.fileId).reduce(0) { $0 + $1.utf8.count }
        print("REVIEW_FILE_ID budget=256 estimated=\(cache.estimatedByteCount) retained_file_id_utf8=\(retained) entries=\(node!.entryCount)")
        precondition(retained == 8 * 1024 * 1024 && cache.estimatedByteCount <= 256)
    }
    do {
        let queryBytes = 1024 * 1024
        let encodedQuery = try JSONEncoder().encode(String(repeating: "z", count: queryBytes))
        let cache = ConversationPrefixCache(byteBudget: 3 * queryBytes)
        var search: ConversationSearch? = ConversationSearch(
            renderedCache: RenderedSourceCache(byteBudget: 0),
            entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: cache)
        var retainedWindow: [KimiMessage] = []
        for i in 0..<8 {
            retainedWindow += try messages([
                ["id": "qu\(i)", "role": "user", "created_at": "0",
                 "content": [["type": "text", "text": "prompt"]]],
                ["id": "qa\(i)", "role": "assistant", "created_at": "0",
                 "content": [["type": "text", "text": "answer"]]],
            ])
            let freshQuery = try JSONDecoder().decode(String.self, from: encodedQuery)
            _ = search!.hits(in: retainedWindow, query: freshQuery, running: false)
        }
        search = nil
        let split = retainedWindow.lastIndex(where: \.isUserPrompt)!
        let finalQuery = try JSONDecoder().decode(String.self, from: encodedQuery)
        let key = ConversationEntryCache.key(entryID: "", query: finalQuery, options: opts, isRunning: false)
        let node = cache.node(forKey: key, prefix: retainedWindow[..<split])!
        func bufferAddress(_ text: String) -> UInt {
            text.utf8.withContiguousStorageIfAvailable { UInt(bitPattern: $0.baseAddress!) }!
        }
        var retainedBuffers: [UInt: Int] = [bufferAddress(node.query): node.query.utf8.count]
        var payloadBuffers: Set<UInt> = []
        for entry in ConversationTimelineEntry.make(Array(retainedWindow[..<split]), isRunning: false) {
            if let payload = node.payload(entryID: entry.id) {
                let pointer = bufferAddress(payload.query)
                retainedBuffers[pointer] = payload.query.utf8.count
                payloadBuffers.insert(pointer)
            }
        }
        let retainedBytes = retainedBuffers.values.reduce(0, +)
        print("REVIEW_QUERY_SHARING budget=\(cache.byteBudget) estimated=\(cache.estimatedByteCount) distinct_query_buffers=\(retainedBuffers.count) payload_query_buffers=\(payloadBuffers.count) payload_shares_node=\(payloadBuffers.contains(bufferAddress(node.query))) retained_query_utf8=\(retainedBytes) node_query_accounted=\(node.query.utf8.count) entries=\(node.entryCount)")
        precondition(retainedBuffers.count == 8 && retainedBytes == 8 * queryBytes,
                     "independently decoded equal queries retain their separate storage through per-entry adoption")
        precondition(cache.estimatedByteCount < cache.byteBudget && retainedBytes > cache.byteBudget)
    }
    do {
        let emptyParts = Array(repeating: ["type": ""], count: 65_536)
        let retainedWindow = try messages([
            ["id": "pu0", "role": "user", "created_at": "0",
             "content": [["type": "text", "text": "prompt"]]],
            ["id": "pa0", "role": "assistant", "created_at": "0", "content": emptyParts],
            ["id": "pu1", "role": "user", "created_at": "0",
             "content": [["type": "text", "text": "tail"]]],
        ])
        let cache = ConversationPrefixCache(byteBudget: 256)
        var search: ConversationSearch? = ConversationSearch(
            renderedCache: RenderedSourceCache(byteBudget: 0),
            entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: cache)
        _ = search!.hits(in: retainedWindow, query: "z", running: false)
        search = nil
        let key = ConversationEntryCache.key(entryID: "", query: "z", options: opts, isRunning: false)
        let node = cache.node(forKey: key, prefix: retainedWindow[..<2])!
        let partBytes = node.source[1].content.count * MemoryLayout<KimiPart>.stride
        print("REVIEW_PART_STORAGE public_search=true budget=256 estimated=\(cache.estimatedByteCount) retained_part_element_bytes=\(partBytes) parts=\(node.source[1].content.count)")
        precondition(partBytes > 8 * 1024 * 1024 && cache.estimatedByteCount <= 256)
    }
    do {
        let offsets = Array(repeating: 0, count: 1024 * 1024)
        let payload = ConversationEntryCache.Payload(messages: [], sources: [], text: "" as NSString,
            sourceEnds: offsets, role: .assistant, isRunning: false, query: "q", options: opts, hits: [])
        let cache = ConversationPrefixCache(byteBudget: 64)
        let key = ConversationEntryCache.key(entryID: "", query: "q", options: opts, isRunning: false)
        cache.store(source: [], query: "q", options: opts, hits: [], entries: ["e": payload],
                    forKey: key, generation: cache.generationNow)
        let node = cache.node(forKey: key, prefix: [KimiMessage]()[...])!
        print("REVIEW_OFFSETS synthetic_public_payload=true budget=64 estimated=\(cache.estimatedByteCount) retained_offsets_bytes=\(node.payload(entryID: "e")!.sourceEnds.count * MemoryLayout<Int>.stride)")
        print("REVIEW_LAYOUT message_stride=\(MemoryLayout<KimiMessage>.stride) part_stride=\(MemoryLayout<KimiPart>.stride) hit_stride=\(MemoryLayout<ConversationSearchHit>.stride)")
    }
