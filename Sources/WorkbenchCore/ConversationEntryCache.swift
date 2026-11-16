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
/// 2. **Byte-exact keys.** The key is a byte sequence: entryID, query UTF-8
///    bytes, option bits and the isRunning flag, zero-separated — hashed in
///    bulk (round-29 `Hasher.combine(bytes:)` pattern) and compared
///    byte-wise. A canonical String key would conflate NFC/NFD queries, the
///    exact defect round 12's `sameQueryKey` and round 27's byte-exact
///    render keys exist to prevent.
/// 3. **Bounded, payload-inclusive.** A node retains the verification
///    messages, so the cost estimate counts them: message metadata and
///    text/thinking/tool fields, plus sources, joined text (UTF-16 ×2) and
///    hit excerpts. The estimate is a cost convention (like the native math
///    cache and RenderedSourceCache), not exact RSS. Batch-LRU eviction;
///    honest churn note per round-29 F9: eviction stops AT the budget, so a
///    table at budget pays an O(N log N) sort under the lock per insert. A
///    single node costing more than the whole budget is built but not
///    stored.
/// 4. **Locale generation.** Hits and excerpts embed locale-sensitive
///    matching results (diacritic-insensitive search, composed-character
///    excerpt ranges), so `NSLocale.currentLocaleDidChangeNotification`
///    bumps the generation and drops the table — same defense-in-depth as
///    RenderedSourceCache.
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

    /// The byte-exact cache key for one entry search. Zero separators cannot
    /// appear inside the entryID/query UTF-8 streams of distinct inputs
    /// ambiguously: every field boundary is a 0x00 byte, which is not part of
    /// any field's encoding here (entryIDs and queries with embedded NULs
    /// would still be separated positionally — the option bits and running
    /// flag are fixed-width tail fields).
    public static func key(entryID: String, query: String,
                           options: ConversationFindOptions, isRunning: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: entryID.utf8)
        bytes.append(0)
        bytes.append(contentsOf: query.utf8)
        bytes.append(0)
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

    /// Stores a built entry. Cost is counted payload-inclusively (see the
    /// type comment); oversized nodes are refused; overflow evicts batch-LRU.
    public func store(payload: Payload, forKey keyBytes: [UInt8]) {
        let cost = Self.estimatedCost(of: payload)
        let key = Key(bytes: keyBytes)
        lock.lock()
        defer { lock.unlock() }
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

    /// The cost convention, exposed for pins: message metadata + text/
    /// thinking/tool payload fields + sources + joined text (UTF-16 ×2) +
    /// hit excerpts.
    public static func estimatedCost(of payload: Payload) -> Int {
        var cost = payload.text.length * 2
        for source in payload.sources { cost += source.utf8.count }
        for hit in payload.hits { cost += hit.excerpt.utf8.count }
        for message in payload.messages {
            cost += message.id.utf8.count + message.role.utf8.count + message.createdAt.utf8.count
            for part in message.content {
                cost += part.type.utf8.count
                if let text = part.text { cost += text.utf8.count }
                if let thinking = part.thinking { cost += thinking.utf8.count }
                if let name = part.name { cost += name.utf8.count }
                if let toolName = part.toolName { cost += toolName.utf8.count }
                if let toolCallId = part.toolCallId { cost += toolCallId.utf8.count }
            }
        }
        return cost
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
