import Foundation

/// Presentation-only cursor for streaming text: the stored text stays complete
/// while this controller paces how much of it is visible. Ported from ccgui's
/// stream-reveal.ts (MIT).
///
/// The cursor is anchored to the TAIL of the text — a `holdback` of trailing
/// characters still hidden — instead of an absolute prefix index. Markdown
/// re-parsing rewrites the rendered text constantly (syntax markers are
/// consumed: `# `, `- `, backticks, `**`, link targets), so a prefix cursor had
/// to reset whenever the text changed shape, and at high token rates that reset
/// dumped the whole unrevealed backlog in a single frame (ccgui measured
/// 20–62 chars/frame at 200 tok/s, up to 140 at 400 tok/s; only ≤15 at 40
/// tok/s, which is why slow streams never showed it).
///
/// The holdback is drained linearly so everything received is on screen by
/// `maxLagMs`: a provider burst is spread across the frames of its own arrival
/// cadence, and continuous output advances at the arrival rate with a bounded
/// lag. Done/hidden/reduced-motion paths bypass the animation entirely.
public final class StreamReveal {
    /// Wall clock in milliseconds plus frame/timeout scheduling. Injected so
    /// checks can drive time manually; production uses a display link.
    public struct Clock {
        public var now: () -> Double
        public var frame: (_ callback: @escaping () -> Void) -> Int
        public var cancelFrame: (_ token: Int) -> Void
        public var timeout: (_ callback: @escaping () -> Void, _ ms: Double) -> Int
        public var clearTimeout: (_ token: Int) -> Void
        public init(now: @escaping () -> Double,
                    frame: @escaping (@escaping () -> Void) -> Int,
                    cancelFrame: @escaping (Int) -> Void,
                    timeout: @escaping (@escaping () -> Void, Double) -> Int,
                    clearTimeout: @escaping (Int) -> Void) {
            self.now = now
            self.frame = frame
            self.cancelFrame = cancelFrame
            self.timeout = timeout
            self.clearTimeout = clearTimeout
        }
    }

    /// Upper bound on how long received text may stay hidden. Every burst is
    /// drained by this deadline, so the display never lags more than this.
    public static let maxLagMs: Double = 240
    /// Shortest spread for one burst: below this the drain reads as a jump, not
    /// as flowing text.
    static let minLagMs: Double = 80
    /// A backlog this large is a wholesale dump (window restore, session
    /// switch, first paint of a long snapshot), not a stream: show it at once
    /// instead of animating for seconds.
    static let maxHoldback: Double = 600
    /// No frame for this long means the display link is suspended (occluded
    /// window): settle rather than leaving text half-revealed behind the scenes.
    static let stallMs: Double = 100

    private var text = ""
    /// Visible prefix length in UTF-16 units. `Int.max` marks a fresh instance
    /// that has not received an update yet: everything is already visible.
    public private(set) var visible = Int.max
    /// Trailing characters already received but not published yet.
    private var holdback = 0.0
    /// Wall-clock time by which the current holdback must be fully revealed.
    private var deadline = 0.0
    /// Measured arrival: cadence (ms between text changes) and rate (characters
    /// per ms). A burst is spread over the cadence that produced it, so the
    /// drain finishes as the next burst lands instead of leaving the text
    /// frozen in between; a rate-matching drain keeps a long fast stream from
    /// accumulating unbounded lag.
    private var cadence = 80.0
    private var rate = 0.0
    private var lastArrival: Double?
    private var frameToken: Int?
    private var timerToken: Int?
    private var lastTick = 0.0
    private let clock: Clock
    /// Called whenever the visible prefix changes. Only the live row
    /// subscribes, so a single callback replaces ccgui's ranged listener set.
    public var onVisibleChange: ((Int) -> Void)?

    public init(clock: Clock) {
        self.clock = clock
    }

    private func publish(_ next: Int) {
        let previous = visible
        visible = next
        if next != previous { onVisibleChange?(next) }
    }

    /// A wholesale swap shares almost nothing with what came before: replaying a
    /// different message character by character is not "smooth", it is wrong.
    /// Only the head can diverge during markdown re-parsing (a construct at the
    /// start of the text completing), so a generous head threshold is enough.
    private func isReplacement(_ previous: String, _ next: String) -> Bool {
        if previous.isEmpty || next.isEmpty { return false }
        let a = Array(previous.utf16)
        let b = Array(next.utf16)
        let limit = min(a.count, b.count)
        var common = 0
        while common < limit, a[common] == b[common] { common += 1 }
        return Double(common) < min(24, Double(limit) * 0.5)
    }

    public func update(_ text: String, animate: Bool) {
        if text == self.text {
            if !animate {
                finish()
                return
            }
            // A pending drain must survive a cancelled frame loop (view teardown
            // between commits). Re-arm it without moving the deadline, so an
            // unchanged snapshot can never leave half-revealed text on screen.
            if holdback > 0 { run(clock.now()) }
            return
        }
        let now = clock.now()
        let previous = self.text
        self.text = text
        if !animate || visible == Int.max || isReplacement(previous, text) {
            finish()
            return
        }
        // The rendered text may change shape without being a literal extension
        // (markdown consumed `**`, `# `, a link target…). The new characters are
        // what needs revealing — not the whole snapshot — so track the cursor
        // relative to the end and let a reshape move it with the text.
        let gained = text.utf16.count - previous.utf16.count
        holdback = max(0, holdback + Double(gained))
        if holdback > Self.maxHoldback {
            finish()
            return
        }
        if gained > 0, let lastArrival {
            let gap = now - lastArrival
            // Sub-frame gaps are part of one provider batch, not a cadence.
            if gap >= 16 {
                cadence = cadence * 0.5 + min(gap, 220) * 0.5
                rate = rate > 0 ? rate * 0.5 + (Double(gained) / gap) * 0.5 : Double(gained) / gap
            }
        }
        lastArrival = now
        // Text may only be pulled back by text that actually disappeared.
        let length = text.utf16.count
        if length < visible { publish(length) }
        if holdback <= 0 {
            cancel()
            return
        }
        // Never drain faster than the arrival cadence (that would empty the queue
        // and stall between bursts) nor faster than the measured rate can feed
        // (that would burn the whole burst in one frame); both are bounded by
        // maxLagMs so the display never lags more than that.
        let spread = rate > 0 ? max(cadence * 1.1, holdback / rate) : Self.maxLagMs
        deadline = now + min(Self.maxLagMs, max(Self.minLagMs, spread))
        run(now)
    }

    /// Start (or keep) the single drain loop plus its stalled-frame watchdog.
    /// One continuous loop per burst beats restarting an animation per commit:
    /// restarts recompute the pacing and produce uneven steps.
    private func run(_ now: Double) {
        if frameToken == nil {
            lastTick = now
            frameToken = clock.frame { [weak self] in self?.tick() }
        }
        if timerToken == nil {
            timerToken = clock.timeout({ [weak self] in self?.watchdog() }, Self.stallMs)
        }
    }

    private func watchdog() {
        timerToken = nil
        let idle = clock.now() - lastTick
        if idle >= Self.stallMs {
            finish()
            return
        }
        timerToken = clock.timeout({ [weak self] in self?.watchdog() }, Self.stallMs - idle)
    }

    /// Drain at the rate that clears the holdback exactly at `deadline`. The
    /// release is fractional, so a small burst still lands one character at a
    /// time over its whole cadence instead of emptying the queue in one frame.
    private func tick() {
        frameToken = nil
        let now = clock.now()
        let remaining = deadline - now
        if holdback <= 0.5 || remaining <= 0 {
            holdback = 0
            publish(text.utf16.count)
            cancel()
            return
        }
        let dt = max(0, min(now - lastTick, remaining))
        lastTick = now
        holdback = max(0, holdback - (holdback * dt) / remaining)
        // Never step backwards inside the loop; only shrinking text may do that
        // (handled by update()).
        let target = text.utf16.count - Int(holdback.rounded())
        if target > visible { publish(target) }
        frameToken = clock.frame { [weak self] in self?.tick() }
    }

    public func finish() {
        cancel()
        holdback = 0
        publish(text.utf16.count)
    }

    public func cancel() {
        if let frameToken { clock.cancelFrame(frameToken) }
        if let timerToken { clock.clearTimeout(timerToken) }
        frameToken = nil
        timerToken = nil
    }
}

extension NSAttributedString {
    /// Grapheme-safe prefix: never show half an emoji, combining sequence, or
    /// surrogate pair. Cursor math runs in UTF-16 units; the boundary check is
    /// the only place graphemes are consulted.
    public func visiblePrefix(utf16Count: Int) -> NSAttributedString {
        if utf16Count >= length { return self }
        if utf16Count <= 0 { return NSAttributedString() }
        let cluster = (string as NSString).rangeOfComposedCharacterSequence(at: utf16Count)
        return attributedSubstring(from: NSRange(location: 0, length: cluster.location))
    }
}
