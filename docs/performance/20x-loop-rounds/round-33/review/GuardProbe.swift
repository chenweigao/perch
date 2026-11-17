import Foundation
import WorkbenchCore

func decode(_ rows: [[String: Any]]) throws -> [KimiMessage] {
    try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
}
func row(_ id: String, _ role: String, _ text: String, metadata: Any? = nil) -> [String: Any] {
    var r: [String: Any] = ["id": id, "role": role, "created_at": "0", "content": [["type": "text", "text": text]]]
    if let metadata { r["metadata"] = metadata }
    return r
}
func shape(_ result: ConversationFindResult) -> Data {
    var data = Data()
    for hit in result.hits {
        for value in [hit.entryID, String(hit.occurrence), hit.excerpt, hit.toolID ?? "<nil>", hit.toolOccurrence.map(String.init) ?? "<nil>"] {
            var length = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: value.utf8)
        }
    }
    data.append(contentsOf: (result.queryError ?? "<nil>").utf8)
    return data
}
func addr<T>(_ values: [T]) -> UInt {
    values.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
}

@main struct GuardProbe {
    static func main() throws {
        let warmRows = [row("u0", "user", "history prompt"), row("a0", "assistant", "HISTORY café a\u{301}\u{327} twice HISTORY"), row("u1", "user", "tail"), row("a1", "assistant", "nothing here")]
        let warm = try decode(warmRows)
        let both = try decode(Array(warmRows.prefix(2)) + [row("u1", "user", "HISTORY"), row("a1", "assistant", "HISTORY café")])
        let advanced = try decode(warmRows + [row("u2", "user", "tail2"), row("a2", "assistant", "nothing here either")])
        let windows: [[KimiMessage]] = [[], try decode([row("a", "assistant", "HISTORY")]), try decode([row("u", "user", "HISTORY")]), warm, both, advanced]
        let queries = ["", "HISTORY", "tail", "NO_MATCH", "caf\u{E9}", "cafe\u{301}", "a\u{301}\u{327}", "[", "HISTORY|tail", ".*"]
        var comparisons = 0
        for prefixBudget in [0, 128 * 1024 * 1024] {
            let pc = ConversationPrefixCache(byteBudget: prefixBudget)
            let bc = ConversationPrefixCache(byteBudget: prefixBudget)
            let candidate = ConversationSearch(renderedCache: RenderedSourceCache(byteBudget: 0), entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: pc)
            let baseline = Round32ReviewSearch(renderedCache: RenderedSourceCache(byteBudget: 0), entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: bc)
            for running in [false, true] {
                for regex in [false, true] {
                    for sensitive in [false, true] {
                        for role in ConversationFindOptions.Role.allCases {
                            let options = ConversationFindOptions(caseSensitive: sensitive, regex: regex, role: role)
                            for query in queries {
                                for window in windows {
                                    let c = candidate.hits(in: window, query: query, running: running, options: options)
                                    let b = baseline.hits(in: window, query: query, running: running, options: options)
                                    precondition(shape(c) == shape(b), "byte mismatch in reused instances")
                                    comparisons += 1
                                    let reopened = ConversationSearch(renderedCache: RenderedSourceCache(byteBudget: 0), entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: pc)
                                    let r = reopened.hits(in: window, query: query, running: running, options: options)
                                    precondition(shape(c) == shape(r), "byte mismatch after shared adoption")
                                    comparisons += 1
                                    var mutated = r.hits
                                    if !mutated.isEmpty {
                                        mutated[0] = .init(entryID: "poison", occurrence: 99, excerpt: "changed")
                                        mutated.reverse()
                                        mutated.append(.init(entryID: "poison2", occurrence: 100, excerpt: "append"))
                                        mutated.removeFirst()
                                        precondition(shape(reopened.hits(in: window, query: query, running: running, options: options)) == shape(r), "caller mutation poisoned earlier/cache")
                                        comparisons += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        print("PASS byte-shape comparisons and caller mutation isolation count=\(comparisons)")
        for running in [false, true] {
            let pc = ConversationPrefixCache()
            let search = ConversationSearch(renderedCache: RenderedSourceCache(byteBudget: 0), entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: pc)
            let first = search.hits(in: warm, query: "HISTORY", running: running)
            let key = ConversationEntryCache.key(entryID: "", query: "HISTORY", options: .init(), isRunning: false)
            let node = pc.node(forKey: key, prefix: warm[..<2])!
            let repeatResult = search.hits(in: warm, query: "HISTORY", running: running)
            let reopened = ConversationSearch(renderedCache: RenderedSourceCache(byteBudget: 0), entryCache: ConversationEntryCache(byteBudget: 0), prefixCache: pc).hits(in: warm, query: "HISTORY", running: running)
            let advancedResult = search.hits(in: advanced, query: "HISTORY", running: running)
            let advancedNode = pc.node(forKey: key, prefix: advanced[..<4])!
            let identities = [addr(first.hits) == addr(node.hits), addr(repeatResult.hits) == addr(node.hits), addr(reopened.hits) == addr(node.hits), addr(advancedResult.hits) == addr(advancedNode.hits)]
            print("storage running=\(running) rebuild/earlier/shared/advance=\(identities)")
            if ProcessInfo.processInfo.environment["REVIEW_REQUIRE_GUARD"] == "1" {
                precondition(identities.allSatisfy { $0 }, "review consumption: all four routes must preserve empty-suffix storage")
            }
        }
        print("KimiMessage size=\(MemoryLayout<KimiMessage>.size) stride=\(MemoryLayout<KimiMessage>.stride)")
        var bitwiseCopies = 0
        let metadataCases: [Any?] = [nil, ["x": "value"], "text", 42, true]
        for metadata in metadataCases {
            let input = try decode([row("u0", "user", "history prompt", metadata: metadata), row("a0", "assistant", "HISTORY", metadata: metadata), row("u1", "user", "tail")])
            let copy = Array(input[..<2])
            precondition(addr(input) != addr(copy), "must materialize distinct buffers")
            let sameBits = round33ReviewSameWindowBits(input[..<2], copy[...])
            let sameWindow = round33ReviewSameWindow(input[..<2], copy[...])
            var diffs: [Int] = []
            input.withUnsafeBufferPointer { left in
                copy.withUnsafeBufferPointer { right in
                    let a = UnsafeRawPointer(left.baseAddress!)
                    let b = UnsafeRawPointer(right.baseAddress!)
                    for i in 0..<2 {
                        for j in 0..<MemoryLayout<KimiMessage>.size where a.load(fromByteOffset: i * MemoryLayout<KimiMessage>.stride + j, as: UInt8.self) != b.load(fromByteOffset: i * MemoryLayout<KimiMessage>.stride + j, as: UInt8.self) {
                            diffs.append(i * MemoryLayout<KimiMessage>.stride + j)
                        }
                    }
                }
            }
            if sameBits { bitwiseCopies += 1 }
            print("materialized metadata=\(String(describing: metadata)) sameWindowBits=\(sameBits) sameWindow=\(sameWindow) compared_byte_differences=\(diffs)")
        }
        print("materialized bitwise_equal_cases=\(bitwiseCopies)/5")
        let retained = (0..<1_000_000).map { $0 }
        var appended = retained
        let old = addr(retained)
        let start = DispatchTime.now().uptimeNanoseconds
        appended.append(contentsOf: [Int]())
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("shared-array empty append copied=\(addr(appended) != old) count=\(appended.count) elapsed_ms=\(elapsed)")
        precondition(appended == retained)
    }
}
