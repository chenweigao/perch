import Foundation

/// Cross-instance cache of rendered find-bar search sources (round 27).
///
/// A fresh `ConversationSearch` instance — the find bar on every open, the
/// workspace history worker on every keystroke — re-renders every source of
/// the searchable window through `ReplyDocument.parse` + `renderedText`,
/// which round-16 attribution measured at ~80% of a cold query (link
/// detection 66.6% + parse 14%). Rendering is shared here across instances
/// so a reopen or a keystroke re-search pays matching, not rendering.
///
/// Design argument (the queue gate for WorkbenchCore-wide caches, "no
/// global memo"):
///
/// 1. **Purity.** `renderedText(ReplyDocument.parse(source))` is a function
///    of the source string's exact UTF-8 bytes within a process: the parse
///    pipeline is deterministic and link detection runs through the
///    process-lifetime `static let` NSDataDetector in ReplyDocument, fixed at
///    first use. A content-addressed lookup therefore returns exactly what
///    re-rendering would produce — the same purity contract round 12's
///    per-instance rendered-text reuse already relies on.
/// 2. **Byte-exact keys, never canonical keys.** Canonically equal but
///    encoding-distinct sources (an NFC/NFD payload swap) render DIFFERENT
///    search bytes (round 12's `sameRenderedUTF8` reasoning), so a
///    canonical-equality key (what `Dictionary<String, …>` uses) would
///    return the wrong rendering. Keys are the exact UTF-8 byte array:
///    hashed and compared byte-wise, so NFC and NFD sources are distinct
///    entries.
/// 3. **Bounded.** Total cost (rendered UTF-16 bytes × 2 + key bytes — a
///    cost ESTIMATE, not exact RSS; same convention as the native math
///    cache's admission estimate) is capped by `byteBudget` (default 32 MiB:
///    the 16k-message bench window renders to ~4 MB, so the budget covers
///    large transcripts several times over while bounding the worst case).
///    Batch-LRU eviction on overflow; a single source whose rendered cost
///    exceeds the whole budget is rendered but not stored (pathological
///    payloads cannot thrash the table).
/// 4. **Locale generation.** The product's NSDataDetector is a process
///    static, so its behavior is fixed at creation; as defense-in-depth
///    against any match-time locale consultation, an
///    `NSLocale.currentLocaleDidChangeNotification` observer bumps the
///    generation and drops the table. The cache holds no session, UI or
///    connection references and never outlives the process — lifetime
///    independence from pages and windows (state-and-effects discipline).
/// 5. **Thread safety.** Find-bar searches run on the main actor; history
///    searches run off-main. One lock guards the table; `produce` runs
///    OUTSIDE the lock (rendering runs cmark + Data Detectors — holding the
///    lock across it would serialize independent searches). Concurrent
///    misses on one source may render it twice; both renders are the same
///    pure value and the last insert wins — benign.
public final class RenderedSourceCache: @unchecked Sendable {
    /// The process-wide cache `ConversationSearch` uses by default. Callers
    /// that must observe true cold rendering (benchmarks, tests) inject a
    /// fresh instance instead; the default argument keeps every existing
    /// call site unchanged.
    public static let shared = RenderedSourceCache()

    /// Estimated byte budget for stored renders (see the type comment: an
    /// estimate, not a hard RSS limit).
    public let byteBudget: Int

    private struct Node {
        let rendered: String
        let cost: Int
        var lastUse: UInt64
        let generation: Int
    }

    private let lock = NSLock()
    private var table: [[UInt8]: Node] = [:]
    private var estimatedBytes = 0
    private var tick: UInt64 = 0
    private var generation = 0
    private var localeObserver: NSObjectProtocol?

    public init(byteBudget: Int = 32 * 1024 * 1024) {
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

    /// Current estimated stored bytes (cost-estimate convention above);
    /// observable for pins and diagnostics.
    public var estimatedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return estimatedBytes
    }

    /// The rendered form of `source`: the stored value on a byte-exact hit,
    /// otherwise `produce()`'s result, stored if it fits the budget.
    public func rendered(_ source: String, produce: () -> String) -> String {
        let key = Array(source.utf8)
        lock.lock()
        tick &+= 1
        let stamp = tick
        let currentGeneration = generation
        if let node = table[key], node.generation == currentGeneration {
            var refreshed = node
            refreshed.lastUse = stamp
            table[key] = refreshed
            lock.unlock()
            return node.rendered
        }
        lock.unlock()

        let produced = produce()

        let cost = produced.utf16.count * 2 + key.count
        lock.lock()
        defer { lock.unlock() }
        guard generation == currentGeneration else { return produced }
        if cost <= byteBudget {
            if let replaced = table[key] {
                estimatedBytes -= replaced.cost
            }
            tick &+= 1
            table[key] = Node(rendered: produced, cost: cost, lastUse: tick, generation: currentGeneration)
            estimatedBytes += cost
            if estimatedBytes > byteBudget {
                evictLocked()
            }
        }
        return produced
    }

    /// Drops every entry (budget and generation unchanged). Benchmarks use
    /// fresh instances instead; this exists for diagnostics and pins.
    public func removeAll() {
        lock.lock()
        table.removeAll()
        estimatedBytes = 0
        lock.unlock()
    }

    /// Batch LRU: evict least-recently-used entries until at or under
    /// budget. Evicting in batches keeps the sort cost amortized (evictions
    /// are rare relative to inserts at budget scale).
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
