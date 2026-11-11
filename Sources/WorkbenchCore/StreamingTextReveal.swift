import Foundation

/// Display-only release of cumulative stream snapshots. Existing text is never
/// replayed; terminal updates and replacements remain immediately authoritative.
public struct StreamingTextReveal {
    public static let maximumLength = 32 * 1024
    public static let frameInterval: TimeInterval = 1.0 / 60
    public static let maximumLag: TimeInterval = 0.5
    public private(set) var text: String
    private var source: NSString
    private var revealed: Int
    private var pendingAge: TimeInterval = 0
    private var fractionalAdvance: Double = 0
    public var hasBacklog: Bool { revealed < source.length }

    public init(_ source: String) {
        self.source = source as NSString
        text = source
        revealed = self.source.length
    }

    @discardableResult public mutating func update(_ next: String, smoothing: Bool) -> Bool {
        let nextSource = next as NSString
        let canAppend = smoothing && nextSource.length <= Self.maximumLength
            && nextSource.length >= source.length && next.hasPrefix(source as String)
        source = nextSource
        if !canAppend { return flush() }
        return false
    }

    @discardableResult public mutating func advance(elapsed: TimeInterval) -> Bool {
        guard hasBacklog, elapsed.isFinite, elapsed > 0 else { return false }
        let remainingTime = max(Self.frameInterval, Self.maximumLag - pendingAge)
        // PI's 60 characters/sec base, accelerated by backlog. The remaining
        // deadline also bounds catch-up when a provider delivers one large burst.
        let speed = max(60, Double(source.length - revealed) / remainingTime)
        pendingAge += elapsed
        if pendingAge >= Self.maximumLag { return flush() }
        let exact = fractionalAdvance + speed * min(elapsed, 0.1)
        let amount = Int(exact)
        fractionalAdvance = exact - Double(amount)
        guard amount > 0 else { return false }
        var end = min(source.length, revealed + amount)
        if end < source.length {
            // Keep emoji, combining marks and joined glyphs together, in addition
            // to protecting UTF-16 surrogate pairs.
            let character = source.rangeOfComposedCharacterSequence(at: end - 1)
            end = max(end, NSMaxRange(character))
        }
        revealed = end
        text = source.substring(to: end)
        if !hasBacklog { pendingAge = 0; fractionalAdvance = 0 }
        return true
    }

    @discardableResult public mutating func flush() -> Bool {
        let changed = revealed != source.length || text != source as String
        revealed = source.length
        text = source as String
        pendingAge = 0
        fractionalAdvance = 0
        return changed
    }
}
