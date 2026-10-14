import Foundation
import WorkbenchCore

/// Drives StreamReveal with manual time: `advance` fires at most one pending
/// frame and any due watchdog, mirroring a display link plus a timer queue.
private final class ManualRevealClock {
    var time: Double = 0
    private(set) var pendingFrame: (() -> Void)?
    private var pendingTimer: (fire: () -> Void, due: Double)?
    var clock: StreamReveal.Clock {
        StreamReveal.Clock(
            now: { [weak self] in self?.time ?? 0 },
            frame: { [weak self] callback in self?.pendingFrame = callback; return 1 },
            cancelFrame: { [weak self] _ in self?.pendingFrame = nil },
            timeout: { [weak self] callback, ms in
                self?.pendingTimer = (callback, (self?.time ?? 0) + ms)
                return 1
            },
            clearTimeout: { [weak self] _ in self?.pendingTimer = nil })
    }
    var hasPendingFrame: Bool { pendingFrame != nil }
    func advance(_ ms: Double) {
        time += ms
        if let timer = pendingTimer, timer.due <= time {
            pendingTimer = nil
            timer.fire()
        }
        if let frame = pendingFrame {
            pendingFrame = nil
            frame()
        }
    }
    func advanceFrames(_ ms: Double, step: Double = 16) {
        var remaining = ms
        while remaining > 0 {
            advance(min(step, remaining))
            remaining -= step
        }
    }
}

func checkStreamReveal() {
    // History never animates: a non-animated update publishes everything at once.
    do {
        let manual = ManualRevealClock()
        let reveal = StreamReveal(clock: manual.clock)
        var published: [Int] = []
        reveal.onVisibleChange = { published.append($0) }
        reveal.update("完整文本", animate: false)
        expectEqual(reveal.visible, 4)
        expectEqual(published, [4])
        expectEqual(manual.hasPendingFrame, false)
    }
    // First snapshot paints whole; the growing tail drains per frame and is
    // fully visible by the max-lag deadline.
    do {
        let manual = ManualRevealClock()
        let reveal = StreamReveal(clock: manual.clock)
        var published: [Int] = []
        reveal.onVisibleChange = { published.append($0) }
        reveal.update("第一段。", animate: true)
        expectEqual(reveal.visible, 4)
        reveal.update("第一段。第二段更长一点。", animate: true)
        expectEqual(reveal.visible, 4)
        expectEqual(manual.hasPendingFrame, true)
        // Mid-drain: strictly between, monotonically increasing.
        manual.advance(16)
        let midway = reveal.visible
        precondition(midway > 4 && midway < 12, "drain must land characters progressively, got \(midway)")
        manual.advanceFrames(300)
        expectEqual(reveal.visible, 12)
        expectEqual(manual.hasPendingFrame, false)
        precondition(published == published.sorted(), "cursor must never step backwards: \(published)")
    }
    // Continuous bursts stay bounded by the max lag after the last arrival.
    do {
        let manual = ManualRevealClock()
        let reveal = StreamReveal(clock: manual.clock)
        var length = 10
        reveal.update(String(repeating: "字", count: length), animate: true)
        for _ in 0..<5 {
            length += 40
            reveal.update(String(repeating: "字", count: length), animate: true)
            manual.advanceFrames(100)
        }
        manual.advanceFrames(240)
        expectEqual(reveal.visible, 210)
    }
    // A backlog beyond the wholesale threshold dumps at once instead of
    // animating for seconds.
    do {
        let manual = ManualRevealClock()
        let reveal = StreamReveal(clock: manual.clock)
        reveal.update(String(repeating: "a", count: 100), animate: true)
        reveal.update(String(repeating: "a", count: 900), animate: true)
        expectEqual(reveal.visible, 900)
        expectEqual(manual.hasPendingFrame, false)
    }
    // A wholesale swap is not "smooth", it is wrong: show it immediately.
    do {
        let manual = ManualRevealClock()
        let reveal = StreamReveal(clock: manual.clock)
        reveal.update("abcdefgh", animate: true)
        reveal.update("abcdefgh更多", animate: true)
        manual.advance(16)
        reveal.update("XXXXXXXX完全不同", animate: true)
        expectEqual(reveal.visible, 12)
        expectEqual(manual.hasPendingFrame, false)
    }
    // Shrinking text pulls the cursor back; only real disappearance may do so.
    do {
        let manual = ManualRevealClock()
        let reveal = StreamReveal(clock: manual.clock)
        reveal.update("abcdef", animate: true)
        expectEqual(reveal.visible, 6)
        reveal.update("abc", animate: true)
        expectEqual(reveal.visible, 3)
    }
    // Suspended frames (occluded window) settle via the watchdog instead of
    // leaving text half-revealed.
    do {
        let manual = ManualRevealClock()
        let reveal = StreamReveal(clock: manual.clock)
        reveal.update("开始", animate: true)
        reveal.update("开始后续内容", animate: true)
        expectEqual(reveal.visible, 2)
        manual.advance(100)
        expectEqual(reveal.visible, 6)
        expectEqual(manual.hasPendingFrame, false)
    }
    // An unchanged non-animated snapshot settles a pending drain.
    do {
        let manual = ManualRevealClock()
        let reveal = StreamReveal(clock: manual.clock)
        let text = "先头部队" + String(repeating: "跟", count: 50)
        reveal.update("先头部队", animate: true)
        reveal.update(text, animate: true)
        expectEqual(reveal.visible, 4)
        reveal.update(text, animate: false)
        expectEqual(reveal.visible, 54)
        expectEqual(manual.hasPendingFrame, false)
    }
    // Re-arming after a cancelled frame loop keeps the original deadline.
    do {
        let manual = ManualRevealClock()
        let reveal = StreamReveal(clock: manual.clock)
        reveal.update("甲", animate: true)
        let full = "甲乙丙丁戊己庚辛"
        reveal.update(full, animate: true)
        manual.advance(16)
        let before = reveal.visible
        reveal.update(full, animate: true)
        expectEqual(reveal.visible, before)
        manual.advanceFrames(240)
        expectEqual(reveal.visible, 8)
    }
    // Grapheme safety: an emoji cluster is never split.
    do {
        let base = NSAttributedString(string: "a👨‍👩‍👧‍👦b")
        let emoji = base.attributedSubstring(from: NSRange(location: 1, length: base.length - 2))
        let partial = base.visiblePrefix(utf16Count: 1 + emoji.length - 1)
        expectEqual(partial.string, "a")
        expectEqual(base.visiblePrefix(utf16Count: 1 + emoji.length).string, "a👨‍👩‍👧‍👦")
        expectEqual(base.visiblePrefix(utf16Count: 0).string, "")
        expectEqual(base.visiblePrefix(utf16Count: 999).string, "a👨‍👩‍👧‍👦b")
        // Attributes survive truncation.
        let marker = NSAttributedString.Key("StreamRevealTestMarker")
        let styled = NSMutableAttributedString(string: "链接文本")
        styled.addAttribute(marker, value: "x", range: NSRange(location: 0, length: 4))
        let cut = styled.visiblePrefix(utf16Count: 2)
        precondition(cut.attribute(marker, at: 0, effectiveRange: nil) != nil, "prefix must keep attributes")
    }
    print("PASS: stream reveal cursor, drain pacing, wholesale dump, replacement, stall watchdog, grapheme prefix")
}
