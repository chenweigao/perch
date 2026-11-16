import Foundation

/// Cross-instance cache of find-bar PREFIX results (round 32).
///
/// Round 12 lets one `ConversationSearch` instance reuse the whole earlier
/// turn range (everything before the latest user prompt) when the query,
/// options and the searchable window are unchanged; round 30 lifted the
/// PER-ENTRY reuse across instances. Round-31's attribution showed a
/// reopened find bar — a fresh instance — still pays, per prefix entry,
/// timeline construction, a cache-key build + lookup, the verification
/// predicate, Entry adoption copies, the instance dictionary insert and its
/// later teardown (~85-90% of the reopen profile is this per-instance
/// structural churn). This cache lifts round-12's PREFIX-level reuse across
/// instances: a verified node returns the stored hits array and its entries
/// dictionary BY REFERENCE, so a reopen pays one window verification and
/// copies instead of any per-prefix-entry work.
///
/// Design argument (the queue gate for WorkbenchCore-wide caches, "no
/// global memo") — the same five-point shape as RenderedSourceCache and
/// ConversationEntryCache, finalized in the round-31 report:
///
/// 1. **Purity, via round-12's exact predicate.** A node is reused only when
///    the caller's prefix window passes `KimiMessage.sameSearchableWindow`
///    against the stored copy (bitwise storage identity, else value equality
///    PLUS byte-identical rendered fields), the query is byte-exact equal
///    (the key encodes its UTF-8 bytes) and the options are equal (the key's
///    flag byte). The reuse contract the reviewer replayed before this
///    implementation (faithful-prefix-lift: 605 byte-shape comparisons across
///    same-query A/B alternation, query/options/running regimes, turn
///    boundary and page prepend) is round-12's, whose within-instance
///    equivalence is already pinned; crossing instances changes only WHERE
///    the verified value is stored. Adoption semantics follow round 12/30:
///    the instance adopts the caller's prefix slice for its own `earlier`,
///    and a later per-entry lookup converts a stored payload against the
///    caller's entry under the same predicate.
/// 2. **Byte-exact, injective keys — round-30's encoding, reused.** The key
///    is `ConversationEntryCache.key(entryID: "", query:, options:,
///    isRunning: false)`: length-prefixed (8-byte big-endian) query UTF-8
///    bytes plus the option flag byte. The prefix always searches with
///    isRunning false and has no entry identity, so the fixed empty entryID
///    and running flag make the encoding exactly (query bytes, options) —
///    injective for arbitrary query contents, including embedded U+0000 and
///    NFC/NFD-distinct patterns (pinned at the byte level since round 30).
///    The prefix identity is NOT in the key; the verification predicate
///    guards it, exactly as round 12/30 guard the window.
/// 3. **Bounded, retention-inclusive — with the slice boundary.** A node
///    retains the MATERIALIZED prefix window (`Array(prefix)`, never the
///    caller's slice: the review replay measured a stored prefix slice
///    retaining the whole backing storage INCLUDING the live-turn suffix
///    until the slice is dropped, which would extend tail-message lifetimes
///    across searches and evade the cost model), the prefix hits, and the
///    entries dictionary — each payload keeping its messages with their
///    JSONValue trees, sources, joined text, offsets and hit excerpts. The
///    admission cost counts ALL of them: the window-message walk mirrors
///    ConversationEntryCache.estimatedCost's per-message terms, each entry
///    payload adds its full round-30 estimatedCost PLUS its dictionary-key
///    (entry ID) UTF-8 bytes — the retained [String: Payload] keys are a
///    field class of their own (round-30 v5 lesson), and the dictionary's
///    bucket storage stays excluded exactly like round-30's table buckets —
///    plus node hit excerpts, key bytes and query UTF-8 bytes. The payloads'
///    query strings COW-share the node's single storage and are counted once
///    through it. Window messages and their per-entry copies are therefore
///    counted MORE THAN ONCE, and payload texts may double-count with the
///    entry cache's own nodes — a deliberate conservative overestimate (an
///    UNCOUNTED field class is blocking; an overcount only shrinks effective
///    capacity).
///    Batch-LRU eviction with the round-29 F9 honest churn note; a node
///    costing more than the whole budget is built but not stored.
/// 4. **Locale generation, including the build window.** Prefix hits and
///    excerpts embed locale-sensitive matching, so
///    `NSLocale.currentLocaleDidChangeNotification` bumps the generation and
///    drops the table. The rebuild runs OUTSIDE the lock, so `store` carries
///    the generation captured before the build and REFUSES a node whose
///    build a notification outlived (round-27 insert guard / round-30 v2
///    contract).
/// 5. **Thread safety.** One lock guards the table; the window verification
///    and any rebuild run OUTSIDE the lock against the caller's messages and
///    an IMMUTABLE node (class reference, all fields `let` — adoption needs
///    no copying and concurrent readers never race). Concurrent misses may
///    rebuild the same prefix twice; both nodes are the same pure value and
///    the last insert wins — benign, and accounting stays single-copy (an
///    insert subtracts any replaced node's cost).
public final class ConversationPrefixCache: @unchecked Sendable {
    /// The process-wide cache `ConversationSearch` uses by default.
    /// Benchmarks and tests observing true per-instance rebuilds inject a
    /// fresh instance (or a byteBudget-0 one, which stores nothing and
    /// therefore reproduces the pre-cache product exactly — the round-27
    /// oracle pattern). The default budget is larger than the entry cache's
    /// because one node holds a whole window's entries (round-31 sizing:
    /// 16k-message windows land in the tens of MiB under the conservative
    /// cost convention; final value A/B-confirmed).
    public static let shared = ConversationPrefixCache()

    /// Estimated byte budget for stored nodes (estimate convention above).
    public let byteBudget: Int

    /// One stored, verified prefix result. Immutable after construction:
    /// instances adopt it by reference (the entries dictionary is NOT
    /// rebuilt per instance — a payload converts to the searcher's private
    /// Entry only when a later search actually looks one up).
    public final class Node: @unchecked Sendable {
        /// The MATERIALIZED prefix window the hits were verified against
        /// (slice boundary — see design point 3).
        public let source: [KimiMessage]
        public let query: String
        public let options: ConversationFindOptions
        public let hits: [ConversationSearchHit]
        fileprivate let entries: [String: ConversationEntryCache.Payload]
        fileprivate init(source: [KimiMessage], query: String,
                         options: ConversationFindOptions,
                         hits: [ConversationSearchHit],
                         entries: [String: ConversationEntryCache.Payload]) {
            self.source = source; self.query = query; self.options = options
            self.hits = hits; self.entries = entries
        }
        /// The stored payload for one prefix timeline entry, or nil.
        public func payload(entryID: String) -> ConversationEntryCache.Payload? {
            entries[entryID]
        }
        /// Number of stored entry payloads (pins and diagnostics).
        public var entryCount: Int { entries.count }
    }

    private struct TableEntry {
        let node: Node
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
    private var table: [Key: TableEntry] = [:]
    private var estimatedBytes = 0
    private var tick: UInt64 = 0
    private var generation = 0
    private var localeObserver: NSObjectProtocol?

    public init(byteBudget: Int = 128 * 1024 * 1024) {
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

    /// The current invalidation generation. Callers capture it BEFORE
    /// rebuilding a prefix and pass it to `store`, which refuses nodes
    /// built under a superseded generation (round-30 discipline).
    public var generationNow: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// The verified node for `keyBytes`, or nil. Verification runs OUTSIDE
    /// the lock against the immutable node: a count guard then round-12's
    /// window predicate on the caller's prefix slice. On success lastUse is
    /// refreshed and the node is adopted by reference — no copying of its
    /// hits or entries happens here.
    public func node(forKey keyBytes: [UInt8], prefix: ArraySlice<KimiMessage>) -> Node? {
        let key = Key(bytes: keyBytes)
        lock.lock()
        tick &+= 1
        let stamp = tick
        let currentGeneration = generation
        guard let entry = table[key], entry.generation == currentGeneration else {
            lock.unlock()
            return nil
        }
        let node = entry.node
        lock.unlock()

        // Byte-level reuse predicate (round 12), whole-window: bitwise
        // storage identity, else value equality plus byte-identical
        // rendered fields. The count guard rejects turn-boundary moves
        // before the structural walk.
        guard node.source.count == prefix.count,
              KimiMessage.sameSearchableWindow(prefix, node.source[...]) else {
            return nil
        }

        lock.lock()
        if var fresh = table[key], fresh.generation == currentGeneration {
            fresh.lastUse = stamp
            table[key] = fresh
        }
        lock.unlock()
        return node
    }

    /// Stores a rebuilt prefix under the generation captured before the
    /// build; a generation bump in between (locale notification) refuses
    /// the stale node. Admission cost includes every retained field class
    /// (design point 3); oversized nodes are refused; overflow evicts
    /// batch-LRU. `source` must be the MATERIALIZED window array.
    public func store(source: [KimiMessage], query: String,
                      options: ConversationFindOptions,
                      hits: [ConversationSearchHit],
                      entries: [String: ConversationEntryCache.Payload],
                      forKey keyBytes: [UInt8], generation builtAt: Int) {
        let node = Node(source: source, query: query, options: options,
                        hits: hits, entries: entries)
        let cost = Self.admissionCost(of: node, forKey: keyBytes)
        let key = Key(bytes: keyBytes)
        lock.lock()
        defer { lock.unlock() }
        guard generation == builtAt else { return }
        guard cost <= byteBudget else { return }
        if let replaced = table[key] {
            estimatedBytes -= replaced.cost
        }
        tick &+= 1
        table[key] = TableEntry(node: node, cost: cost, lastUse: tick, generation: generation)
        estimatedBytes += cost
        if estimatedBytes > byteBudget {
            evictLocked()
        }
    }

    /// The ADMISSION cost convention, exposed for pins: node cost + the
    /// retained key bytes + the retained query string's UTF-8 bytes
    /// (Codex P2 pattern — every byte the node retains counts).
    public static func admissionCost(of node: Node, forKey keyBytes: [UInt8]) -> Int {
        estimatedCost(of: node) + keyBytes.count + node.query.utf8.count
    }

    /// The node-only part of the cost convention: the materialized window
    /// walk (mirrors ConversationEntryCache.estimatedCost's per-message
    /// terms — metadata fields and recursive JSONValue sizes included) +
    /// the node-level hit excerpts + every entry payload's full round-30
    /// estimatedCost + every dictionary-key (entry ID) UTF-8 byte length.
    /// Window messages and their per-entry copies count more than once BY
    /// DESIGN (conservative overestimate, design point 3).
    public static func estimatedCost(of node: Node) -> Int {
        var cost = windowCost(node.source)
        for hit in node.hits { cost += hit.excerpt.utf8.count }
        // The dictionary is walked here where its fileprivate storage is in
        // scope; the payload query strings COW-share node.query's single
        // storage and are counted once through it (design point 3).
        for (id, payload) in node.entries {
            cost += ConversationEntryCache.estimatedCost(of: payload) + id.utf8.count
        }
        return cost
    }

    /// The per-message retention walk for a window: id/role/createdAt,
    /// metadata JSONValue trees, every content part's fields including
    /// recursive input/output/source JSONValue sizes and fileId bytes, plus
    /// the STRUCTURAL element storage (message and part array slots at
    /// MemoryLayout stride). Same terms and same estimate convention as
    /// ConversationEntryCache.estimatedCost's message loop (duplicated
    /// deliberately: both are frozen cost conventions pinned by
    /// hand-computed assertions; the round-32 v3 closure extended both
    /// together — the review probes' fileId and part-element findings were
    /// inherited from the round-30 formula).
    public static func windowCost(_ messages: [KimiMessage]) -> Int {
        var cost = messages.count * MemoryLayout<KimiMessage>.stride
        for message in messages {
            cost += message.id.utf8.count + message.role.utf8.count + message.createdAt.utf8.count
            cost += message.content.count * MemoryLayout<KimiPart>.stride
            if let metadata = message.metadata { cost += ConversationEntryCache.jsonValueSize(metadata) }
            for part in message.content {
                cost += part.type.utf8.count
                if let text = part.text { cost += text.utf8.count }
                if let thinking = part.thinking { cost += thinking.utf8.count }
                if let name = part.name { cost += name.utf8.count }
                if let toolName = part.toolName { cost += toolName.utf8.count }
                if let toolCallId = part.toolCallId { cost += toolCallId.utf8.count }
                if let fileId = part.fileId { cost += fileId.utf8.count }
                if let input = part.input { cost += ConversationEntryCache.jsonValueSize(input) }
                if let output = part.output { cost += ConversationEntryCache.jsonValueSize(output) }
                if let source = part.source { cost += ConversationEntryCache.jsonValueSize(source) }
            }
        }
        return cost
    }

    /// Drops every node (budget and generation unchanged; diagnostic
    /// semantics — NOT the locale invalidation path, which also bumps the
    /// generation).
    public func removeAll() {
        lock.lock()
        table.removeAll()
        estimatedBytes = 0
        lock.unlock()
    }

    /// Batch LRU with the round-29 F9 honest-cost note: no low-water
    /// margin, so sustained churn at budget pays the sort per insert.
    private func evictLocked() {
        guard estimatedBytes > byteBudget else { return }
        let ordered = table.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, entry) in ordered {
            guard estimatedBytes > byteBudget else { break }
            table.removeValue(forKey: key)
            estimatedBytes -= entry.cost
        }
    }
}
