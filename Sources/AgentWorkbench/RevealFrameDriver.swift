import CoreVideo
import Foundation
import Observation
import QuartzCore
import WorkbenchCore

/// Shared vsync-aligned frame source for StreamReveal controllers. The display
/// link runs only while at least one frame callback is pending; timeouts ride
/// the main run loop. CVDisplayLink stops when every display sleeps or the
/// window server suspends it, which is exactly when the reveal watchdog should
/// settle the text instead of animating behind an occluded window.
/// Everything is called on the main thread.
final class RevealFrameDriver {
    static let shared = RevealFrameDriver()
    private var link: CVDisplayLink?
    private var frames: [Int: () -> Void] = [:]
    private var timers: [Int: Timer] = [:]
    private var nextToken = 0

    private(set) var requestedFrameCount = 0
    var pendingFrameCount: Int { frames.count }
    var isRunning: Bool { link != nil }

    var clock: StreamReveal.Clock {
        StreamReveal.Clock(
            now: { CACurrentMediaTime() * 1000 },
            frame: { [weak self] callback in self?.addFrame(callback) ?? 0 },
            cancelFrame: { [weak self] token in self?.cancelFrame(token) },
            timeout: { [weak self] callback, ms in self?.addTimeout(callback, ms) ?? 0 },
            clearTimeout: { [weak self] token in self?.cancelTimeout(token) })
    }

    private func addFrame(_ callback: @escaping () -> Void) -> Int {
        nextToken += 1
        requestedFrameCount += 1
        frames[nextToken] = callback
        ensureLink()
        return nextToken
    }
    private func cancelFrame(_ token: Int) {
        frames.removeValue(forKey: token)
        if frames.isEmpty, let link {
            CVDisplayLinkStop(link)
            self.link = nil
        }
    }
    private func ensureLink() {
        guard link == nil else { return }
        var created: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard let created else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(created, { _, _, _, _, _, context -> CVReturn in
            guard let context else { return kCVReturnError }
            let driver = Unmanaged<RevealFrameDriver>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { driver.fire() }
            return kCVReturnSuccess
        }, context)
        CVDisplayLinkStart(created)
        link = created
    }
    private func fire() {
        let tickProbe = PerfDiagnostics.begin()
        // Controllers re-arm inside their tick; only stop once nobody did.
        let pending = Array(frames.keys)
        defer { PerfDiagnostics.end("reveal_tick", tickProbe, detail: "callbacks=\(pending.count)") }
        for token in pending {
            // Consume before invoking: a tick can schedule the next frame or
            // cancel a sibling without replaying an old callback.
            guard let callback = frames.removeValue(forKey: token) else { continue }
            callback()
        }
        if frames.isEmpty, let link {
            CVDisplayLinkStop(link)
            self.link = nil
        }
    }
    private func addTimeout(_ callback: @escaping () -> Void, _ ms: Double) -> Int {
        nextToken += 1
        let token = nextToken
        timers[token] = Timer.scheduledTimer(withTimeInterval: ms / 1000, repeats: false) { [weak self] timer in
            self?.timers.removeValue(forKey: token)
            callback()
            timer.invalidate()
        }
        return token
    }
    private func cancelTimeout(_ token: Int) {
        timers.removeValue(forKey: token)?.invalidate()
    }
}

/// Per-row published cursor. Rows without an active reveal keep `Int.max`:
/// everything visible, identical to pre-reveal rendering.
@Observable final class RevealCursor {
    var visible = Int.max
}
