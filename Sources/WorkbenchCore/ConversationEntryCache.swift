import Foundation

/// Cross-instance cache of find-bar entry search results (round 30).
///
/// Round-12 proved an entry's hits are a pure function of
/// (messages, isRunning, query, options) and reuses them WITHIN one
/// `ConversationSearch` instance under a byte-level verification predicate
/// (`KimiMessage.sameSearchableWindow` + `sameQueryKey` + options/isRunning
/// equality). Round-29's corrected attribution showed a reopened find bar —
/// a fresh instance — still rebuilds everything the predicate would have
/// allowed it to skip: tool-input display JSON serialization (14.37% of the
/// reopen profile), rendered-source lookups, the joined-text build and the
/// locale matching itself. This cache lifts round-12's reuse across
/// instances: a verified node returns its stored entry payload (sources,
/// joined text, offsets, hits), so a reopen or a repeated explicit history
/// search pays verification and copies instead of rebuilds.
///
/// Design argument (the queue gate for WorkbenchCore-wide caches, "no
/// global memo") — the same five-point shape as RenderedSourceCache:
///
/// 1. **Purity, via round-12's exact predicate.** A node is reused only when
///    the caller's entry messages pass `KimiMessage.sameSearchableWindow`
///    against the stored copy (bitwise storage identity, else value equality
///    PLUS byte-identical rendered fields — strictly stronger than canonical
///    value equality, built and pinned in round 12 for exactly this reuse),
///    the query is byte-exact equal (`sameQueryKey` reasoning: canonically
///    equal NFC/NFD queries are different literal/regex patterns), options
///    and isRunning are equal. The stored `messages` are adopted from the
///    caller on reuse (round-12 adoption semantics) so the next verification
///    reads the freshest payload copy.
/// 2. **Byte-exact, injective keys.** The key is a byte sequence: LENGTH-
///    PREFIXED (8-byte big-endian) entryID and query UTF-8 bytes, then the
///    option/running flag byte — hashed in bulk (round-29
///    `Hasher.combine(bytes:)` pattern) and compared byte-wise. Length
///    prefixes make the encoding injective for ARBITRARY field contents:
///    Swift strings may embed U+0000, whose UTF-8 byte is 0x00, so a plain
///    zero separator would be ambiguous (review finding: entryID "a\0b" +
///    query "c" and entryID "a" + query "b\0c" would collide). A canonical
///    String key would conflate NFC/NFD queries, the exact defect round 12's
///    `sameQueryKey` and round 27's byte-exact render keys exist to prevent.
/// 3. **Bounded, retention-inclusive.** A node retains the verification
///    messages (INCLUDING their tool input/output/source JSONValue trees and
///    message metadata — a text-phase entry keeps its message's whole content
///    array), its key bytes and the query string, so the ADMISSION cost
///    counts all of them: message metadata fields, recursive JSONValue sizes,
///    sources, joined text (UTF-16 ×2), hit excerpts, key bytes and query
///    UTF-8 bytes. Two review rounds shaped this: Codex P2 (excluding
///    key/query storage let 100 × 100KB query keys pass a 1KB budget while
///    reporting 800B) and the closure review (excluding JSONValue payloads
///    let ~8MiB of tool-input metadata retain inside a 128B budget reporting
///    77B — not an estimate error, an uncounted field class). The estimate is
///    a cost convention (like the native math cache and RenderedSourceCache),
///    not exact RSS. Batch-LRU eviction;
///    honest churn note per round-29 F9: eviction stops AT the budget, so a
///    table at budget pays an O(N log N) sort under the lock per insert. A
///    single node costing more than the whole budget is built but not
///    stored.
/// 4. **Locale generation, including the build window.** Hits and excerpts
///    embed locale-sensitive matching results (diacritic-insensitive search,
///    composed-character excerpt ranges), so `NSLocale.currentLocaleDidChangeNotification`
///    bumps the generation and drops the table — same defense-in-depth as
///    RenderedSourceCache. A rebuild runs OUTSIDE the lock, so `store`
///    carries the generation captured before the build and REFUSES the
///    payload when a notification landed in between (review finding: without
///    it, a stale-locale build could enter the fresh generation — the
///    RenderedSourceCache insert guard, which round-27's supplement pinned,
///    applies here too).
/// 5. **Thread safety.** One lock guards the table; the verification walk
///    and any rebuild run OUTSIDE the lock (they touch only the caller's
///    messages and an immutable copied node). Concurrent misses may rebuild
///    the same entry twice; both payloads are the same pure value and the
///    last insert wins — benign, and accounting stays single-copy (an
///    insert subtracts any replaced node's cost).
public final class ConversationEntryCache: @unchecked Sendable {
    /// The process-wide cache `ConversationSearch` uses by default. Benchmarks
    /// and tests observing true per-instance rebuilds inject a fresh instance
    /// (or a byteBudget-0 one, which stores nothing and therefore reproduces
    /// the pre-cache product exactly — the round-27 oracle pattern).
    public static let shared = ConversationEntryCache()

    /// Estimated byte budget for stored nodes (estimate convention above).
    public let byteBudget: Int

    /// The stored payload of one verified entry search. Mirrors the fields of
    /// ConversationSearch's private Entry; conversion lives in
    /// ConversationSearch (same module).
    public struct Payload {
        public let messages: [KimiMessage]
        public let sources: [String]
        public let text: NSString
        public let sourceEnds: [Int]
        public let role: ConversationFindOptions.Role
        public let isRunning: Bool
        public let query: String
        public let options: ConversationFindOptions
        public let hits: [ConversationSearchHit]
        public init(messages: [KimiMessage], sources: [String], text: NSString, sourceEnds: [Int],
                    role: ConversationFindOptions.Role, isRunning: Bool, query: String,
                    options: ConversationFindOptions, hits: [ConversationSearchHit]) {
            self.messages = messages; self.sources = sources; self.text = text
            self.sourceEnds = sourceEnds; self.role = role; self.isRunning = isRunning
            self.query = query; self.options = options; self.hits = hits
        }
    }

    private struct Node {
        let payload: Payload
        let cost: Int
        var lastUse: UInt64
        let generation: Int
    }

    private struct Key: Hashable {
        let bytes: [UInt8]
        func hash(into hasher: inout Hasher) {
            bytes.withUnsafeBufferPointer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
        static func == (lhs: Key, rhs: Key) -> Bool { lhs.bytes == rhs.bytes }
    }

    private let lock = NSLock()
    private var table: [Key: Node] = [:]
    private var estimatedBytes = 0
    private var tick: UInt64 = 0
    private var generation = 0
    private var localeObserver: NSObjectProtocol?

    public init(byteBudget: Int = 64 * 1024 * 1024) {
        self.byteBudget = byteBudget
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.generation += 1
            self.table.removeAll()
            self.estimatedBytes = 0
            self.lock.unlock()
        }
    }

    deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
    }

    /// Current estimated stored bytes (cost-estimate convention above).
    public var estimatedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return estimatedBytes
    }

    /// The byte-exact cache key for one entry search: 8-byte big-endian
    /// length prefixes make the (entryID, query) encoding INJECTIVE for
    /// arbitrary contents — Swift strings may embed U+0000 (UTF-8 byte
    /// 0x00), so a plain zero separator would be ambiguous (review finding;
    /// pinned by checkConversationEntryCache's NUL-collision case). The
    /// option bits and running flag are a fixed-width tail byte.
    public static func key(entryID: String, query: String,
                           options: ConversationFindOptions, isRunning: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        appendLengthPrefixed(&bytes, entryID)
        appendLengthPrefixed(&bytes, query)
        var flags: UInt8 = 0
        if options.caseSensitive { flags |= 1 }
        if options.regex { flags |= 2 }
        switch options.role {
        case .all: flags |= 0
        case .user: flags |= 4
        case .assistant: flags |= 8
        case .tool: flags |= 12
        }
        if isRunning { flags |= 64 }
        bytes.append(flags)
        return bytes
    }

    private static func appendLengthPrefixed(_ bytes: inout [UInt8], _ field: String) {
        var length = UInt64(field.utf8.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: length >> shift))
        }
        bytes.append(contentsOf: field.utf8)
    }

    /// The current invalidation generation. Callers capture it BEFORE
    /// rebuilding an entry and pass it to `store`, which refuses payloads
    /// built under a superseded generation (a locale notification landing
    /// mid-build must not admit stale-locale results).
    public var generationNow: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// The verified payload for `keyBytes`, or nil. Verification runs OUTSIDE
    /// the lock against an immutable copy: round-12's window predicate on the
    /// caller's entry messages. On success the node's stored messages are
    /// adopted by the caller (round-12 semantics) and lastUse is refreshed.
    public func payload(forKey keyBytes: [UInt8],
                        messages: ArraySlice<KimiMessage>) -> Payload? {
        let key = Key(bytes: keyBytes)
        lock.lock()
        tick &+= 1
        let stamp = tick
        let currentGeneration = generation
        guard let node = table[key], node.generation == currentGeneration else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        // Byte-level reuse predicate (round 12): bitwise storage identity,
        // else value equality plus byte-identical rendered fields.
        guard KimiMessage.sameSearchableWindow(messages, node.payload.messages[...]) else {
            return nil
        }

        lock.lock()
        if var fresh = table[key], fresh.generation == currentGeneration {
            fresh.lastUse = stamp
            table[key] = fresh
        }
        lock.unlock()
        return node.payload
    }

    /// Stores a built entry under the generation captured before the build;
    /// a generation bump in between (locale notification) refuses the stale
    /// payload. Admission cost includes the retained key and query bytes
    /// (Codex P2); oversized nodes are refused; overflow evicts batch-LRU.
    public func store(payload: Payload, forKey keyBytes: [UInt8], generation builtAt: Int) {
        let cost = Self.admissionCost(of: payload, forKey: keyBytes)
        let key = Key(bytes: keyBytes)
        lock.lock()
        defer { lock.unlock() }
        guard generation == builtAt else { return }
        guard cost <= byteBudget else { return }
        if let replaced = table[key] {
            estimatedBytes -= replaced.cost
        }
        tick &+= 1
        table[key] = Node(payload: payload, cost: cost, lastUse: tick, generation: generation)
        estimatedBytes += cost
        if estimatedBytes > byteBudget {
            evictLocked()
        }
    }

    /// The ADMISSION cost convention, exposed for pins: payload cost + the
    /// retained key bytes + the retained query string's UTF-8 bytes. Every
    /// byte the node retains counts against the budget (Codex P2).
    public static func admissionCost(of payload: Payload, forKey keyBytes: [UInt8]) -> Int {
        estimatedCost(of: payload) + keyBytes.count + payload.query.utf8.count
    }

    /// The payload-only part of the cost convention: message metadata fields
    /// + recursive JSONValue sizes (input/output/source/metadata — the
    /// retained trees a text-phase entry carries with its message's full
    /// content array) + part fileId bytes + sources + joined text
    /// (UTF-16 ×2) + hit excerpts + STRUCTURAL element storage (the array
    /// slots retaining messages, parts, sources, offsets and hits, priced at
    /// MemoryLayout stride — count×stride is a lower-bound estimate since
    /// arrays may hold spare capacity; round-32 v3 closure after the review
    /// probes measured 8MiB fileId / 8MiB offset / 12MiB part-element
    /// retentions inside tiny accounted costs — the same uncounted-field-
    /// class defect as round-30 v5's JSONValue finding, in the classes it
    /// missed; fixed here and in the prefix window walk together so both
    /// conventions stay identical). Fixed-size fields (isError, role,
    /// isRunning, option flags) stay unpriced like other in-struct scalars.
    public static func estimatedCost(of payload: Payload) -> Int {
        var cost = payload.text.length * 2
        cost += payload.sources.count * MemoryLayout<String>.stride
        cost += payload.sourceEnds.count * MemoryLayout<Int>.stride
        cost += payload.hits.count * MemoryLayout<ConversationSearchHit>.stride
        cost += payload.messages.count * MemoryLayout<KimiMessage>.stride
        for source in payload.sources { cost += source.utf8.count }
        for hit in payload.hits { cost += hit.excerpt.utf8.count }
        for message in payload.messages {
            cost += message.id.utf8.count + message.role.utf8.count + message.createdAt.utf8.count
            cost += message.content.count * MemoryLayout<KimiPart>.stride
            if let metadata = message.metadata { cost += jsonValueSize(metadata) }
            for part in message.content {
                cost += part.type.utf8.count
                if let text = part.text { cost += text.utf8.count }
                if let thinking = part.thinking { cost += thinking.utf8.count }
                if let name = part.name { cost += name.utf8.count }
                if let toolName = part.toolName { cost += toolName.utf8.count }
                if let toolCallId = part.toolCallId { cost += toolCallId.utf8.count }
                if let fileId = part.fileId { cost += fileId.utf8.count }
                if let input = part.input { cost += jsonValueSize(input) }
                if let output = part.output { cost += jsonValueSize(output) }
                if let source = part.source { cost += jsonValueSize(source) }
            }
        }
        return cost
    }

    /// Recursive retained-size estimate of a JSONValue tree: string leaves by
    /// UTF-8 length, numbers 8, bool/null 1, containers 16 + children (the
    /// container constant approximates dictionary/array storage overhead —
    /// estimate convention, not exact RSS).
    public static func jsonValueSize(_ value: JSONValue) -> Int {
        switch value {
        case .null: return 1
        case .bool: return 1
        case .number: return 8
        case .string(let text): return text.utf8.count
        case .array(let items): return items.reduce(16) { $0 + jsonValueSize($1) }
        case .object(let map): return map.reduce(16) { $0 + $1.key.utf8.count + jsonValueSize($1.value) }
        }
    }

    /// Drops every entry (budget and generation unchanged; diagnostic
    /// semantics — NOT the locale invalidation path, which also bumps the
    /// generation).
    public func removeAll() {
        lock.lock()
        table.removeAll()
        estimatedBytes = 0
        lock.unlock()
    }

    /// Batch LRU with the round-29 F9 honest-cost note: no low-water margin,
    /// so sustained churn at budget pays the sort per insert.
    private func evictLocked() {
        guard estimatedBytes > byteBudget else { return }
        let ordered = table.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, node) in ordered {
            guard estimatedBytes > byteBudget else { break }
            table.removeValue(forKey: key)
            estimatedBytes -= node.cost
        }
    }
}
