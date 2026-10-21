import AppKit
import QuartzCore

/// Display frames for the opt-in frame-hitch recorder.
///
/// A CADisplayLink from the key window's screen (macOS 14 `displayLink(target:selector:)`)
/// runs on the main run loop in `.common` modes, so it keeps firing during
/// event tracking. Its callbacks are main-thread work, so a callback that
/// arrives late is exactly a frame this app did not produce in time. The
/// screen's link fires whatever the window's state; the monitor follows key
/// window and screen changes itself. A local scroll-wheel monitor (events pass
/// through unchanged) marks frames near a scroll event, or during momentum, as
/// scrolling.
///
/// Runs only while diagnostics are on and the app is active. The monitor calls
/// into PerfDiagnostics; PerfDiagnostics never refers to it.
@MainActor
final class FrameHitchMonitor: NSObject {
    static let shared = FrameHitchMonitor(requiresActiveApp: true)
    /// A frame within this time after a scroll event counts as scrolling.
    static let scrollWindow: CFTimeInterval = 0.3
    /// Momentum whose end event never arrives stops counting after this.
    static let momentumTimeout: CFTimeInterval = 2

    /// The app measures only while it is in front; the host check runs as an
    /// inactive background agent.
    private let requiresActiveApp: Bool
    private typealias Observer = (center: NotificationCenter, token: NSObjectProtocol)
    private var link: CADisplayLink?
    private weak var screen: NSScreen?
    private var wheelMonitor: Any?
    /// The only observer while diagnostics are off.
    private var toggle: Observer?
    /// Activation, key window, screen, sleep and session changes; only while on.
    private var lifecycle: [Observer] = []
    private var previousFrame: CFTimeInterval?
    private var lastScroll = -CFTimeInterval.infinity
    private var lastPhase = "wheel"
    private var momentum = false
    /// Callbacks received so far; the host check's evidence that the link fires.
    private(set) var deliveredFrames = 0
    var isRunning: Bool { link != nil }

    init(requiresActiveApp: Bool) {
        self.requiresActiveApp = requiresActiveApp
        super.init()
    }

    /// Idempotent. While diagnostics are off only the Settings toggle is
    /// observed; the display link and the scroll monitor exist only while recording.
    func install() {
        if toggle == nil {
            toggle = observe(NotificationCenter.default, PerfDiagnostics.enabledDidChange) { [weak self] _ in self?.reconcile() }
        }
        reconcile()
    }

    func uninstall() {
        stop()
        unobserveLifecycle()
        if let toggle { toggle.center.removeObserver(toggle.token) }
        toggle = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping (Notification) -> Void) -> Observer {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { action(note) }
        }
        return (center: center, token: token)
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
            lifecycle.append(observe(center, name) { [weak self] _ in self?.reconcile() })
        }
        // Screen reconfiguration, sleep and session switches pause the display:
        // start a fresh chain so the pause is not recorded as a hitch.
        lifecycle.append(observe(center, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.restart() })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            lifecycle.append(observe(workspace, name) { [weak self] _ in self?.restart() })
        }
    }

    private func unobserveLifecycle() {
        for observer in lifecycle { observer.center.removeObserver(observer.token) }
        lifecycle.removeAll()
    }

    private func reconcile() {
        guard PerfDiagnostics.shared.enabled else {
            stop()
            unobserveLifecycle()
            return
        }
        if lifecycle.isEmpty { observeLifecycle() }
        let app = NSApplication.shared
        guard !requiresActiveApp || app.isActive,
              let target = app.keyWindow?.screen ?? app.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            stop()
            return
        }
        guard link == nil || target !== screen else { return }
        start(on: target)
    }

    private func restart() {
        stop()
        reconcile()
    }

    private func start(on target: NSScreen) {
        stop()
        // The default frame rate range is the screen's maximum refresh rate.
        let link = target.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        screen = target
        PerfDiagnostics.shared.breakFrameChain()
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.noteScroll(phase: event.phase, momentumPhase: event.momentumPhase)
            return event
        }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        screen = nil
        previousFrame = nil
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        lastScroll = -.infinity
        momentum = false
    }

    @objc private func step(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        // A stall's late callback still counts as scrolling when the scroll
        // event came shortly before the stalled window began.
        let windowStart = previousFrame ?? timestamp
        previousFrame = timestamp
        deliveredFrames += 1
        if momentum, CACurrentMediaTime() - lastScroll > Self.momentumTimeout { momentum = false }
        let scrolling = momentum || lastScroll >= windowStart - Self.scrollWindow
        PerfDiagnostics.shared.recordFrame(timestamp: timestamp, duration: link.targetTimestamp - timestamp,
                                           scrolling: scrolling, phase: scrolling ? lastPhase : nil)
    }

    /// Event-dispatch time on the display link's clock, not the event's own
    /// timestamp: a stalled main thread dispatches late, as it draws late.
    private func noteScroll(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        lastScroll = CACurrentMediaTime()
        if momentumPhase.isEmpty {
            momentum = false
            lastPhase = Self.name(phase)
        } else {
            momentum = !momentumPhase.contains(.ended) && !momentumPhase.contains(.cancelled)
            lastPhase = "momentum"
        }
    }

    private static func name(_ phase: NSEvent.Phase) -> String {
        if phase.isEmpty { return "wheel" } // a mouse wheel without gesture phases
        if phase.contains(.began) { return "began" }
        if phase.contains(.changed) { return "changed" }
        if phase.contains(.ended) { return "ended" }
        if phase.contains(.cancelled) { return "cancelled" }
        if phase.contains(.mayBegin) { return "may_begin" }
        return "stationary"
    }
}
