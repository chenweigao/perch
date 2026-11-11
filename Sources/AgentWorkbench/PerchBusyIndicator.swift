import AppKit
import QuartzCore
import SwiftUI
import WorkbenchCore

/// A small monochrome progress mark. Its layer rotates independently of
/// SwiftUI; visibility also pauses the work line's separate elapsed clock.
struct ConversationWorkIndicator: NSViewRepresentable {
    let phase: ConversationRunPhase
    let animated: Bool
    let visibilityChanged: (Bool) -> Void
    func makeNSView(context: Context) -> ConversationWorkIndicatorView { ConversationWorkIndicatorView() }
    func updateNSView(_ view: ConversationWorkIndicatorView, context: Context) {
        view.visibilityChanged = visibilityChanged
        view.update(phase: phase, animated: animated)
    }
    static func dismantleNSView(_ view: ConversationWorkIndicatorView, coordinator: ()) { view.stop() }
}

final class ConversationWorkIndicatorView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var phase: ConversationRunPhase = .running
    private var animated = false
    private var playing = false
    private var reportedVisible: Bool?
    private var observers: [NSObjectProtocol] = []
    var visibilityChanged: ((Bool) -> Void)?
    var motionLayer: CALayer { arc }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("conversation-work-indicator")
        setAccessibilityElement(false)
        for shape in [track, arc] {
            shape.fillColor = nil; shape.lineCap = .round; shape.lineWidth = 1.35
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0.72
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(phase: ConversationRunPhase, animated: Bool) {
        self.phase = phase; self.animated = animated
        render(); refreshMotion()
    }
    override func layout() { super.layout(); render(); refreshMotion() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); render() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); render() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.refreshMotion() }
                })
            }
        }
        render(); refreshMotion()
    }
    private func render() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        var ink = phase.needsInput ? NSColor.systemOrange : WorkbenchTheme.quietNS
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = ink.usingColorSpace(.sRGB) ?? ink }
        let radius = max(1, min(bounds.width, bounds.height) / 2 - 1.25)
        let path = CGPath(ellipseIn: CGRect(x: bounds.midX-radius, y: bounds.midY-radius, width: radius*2, height: radius*2), transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shape in [track, arc] {
            shape.frame = bounds; shape.path = path; shape.contentsScale = window?.backingScaleFactor ?? 2
        }
        track.strokeColor = ink.withAlphaComponent(0.16).cgColor
        arc.strokeColor = ink.cgColor
        CATransaction.commit()
    }
    private func refreshMotion() {
        let visible = window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
        if reportedVisible != visible {
            reportedVisible = visible
            let callback = visibilityChanged
            DispatchQueue.main.async { callback?(visible) }
        }
        let shouldPlay = visible && animated && phase.animates
        guard shouldPlay != playing else { return }
        playing = shouldPlay
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arc.removeAllAnimations(); arc.transform = CATransform3DIdentity
        if shouldPlay {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0; rotation.toValue = 2 * CGFloat.pi
            rotation.duration = 1.05; rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            arc.add(rotation, forKey: "work-rotation")
        }
        CATransaction.commit()
    }
    func stop() {
        visibilityChanged = nil; arc.removeAllAnimations(); playing = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}

/// The running sun of list rows and the Goal header on the 24-unit glyph grid:
/// a ring that chases. The composer uses the same mark around its stop glyph.
enum PerchLineMark {
    static let lineWidth: CGFloat = 1.75
    static let soloCenter = CGPoint(x: 12, y: 12)
    static let soloRadius: CGFloat = 7

    /// Running is a chase: the arc's head runs out from a quarter to most of the
    /// ring, then its tail catches up, once per revolution. The arc never drops
    /// below a quarter, so the sun never shrinks to a dot.
    static let revolution: CFTimeInterval = 2
    static let shortArc: CGFloat = 90
    static let longArc: CGFloat = 270
    /// Reduce Motion holds this share of the ring still.
    static let stillArc: CGFloat = 0.75

    /// Where the ring's path starts, in degrees. The chase is drawn as
    /// strokeStart/strokeEnd over a layer turning once per revolution; starting
    /// the path here keeps both fractions inside 0...1 for the whole cycle.
    static let ringStart: CGFloat = -225

    /// One revolution of the chase, sampled, as stroke fractions of a ring whose
    /// path starts at `ringStart` and whose layer turns a full circle per cycle.
    /// Head and tail each ease in and out over half the cycle; the arc hands off
    /// `longArc - shortArc` per cycle and drifts the rest, so a cycle is exactly
    /// one turn and repeats seamlessly.
    static func chaseKeyframes(samples: Int = 48) -> (start: [CGFloat], end: [CGFloat]) {
        let reach = longArc - shortArc
        func smooth(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
        var start: [CGFloat] = [], end: [CGFloat] = []
        for i in 0...samples {
            let u = CGFloat(i) / CGFloat(samples)
            let tail = u < 0.5 ? 0 : reach * smooth((u - 0.5) / 0.5)
            let head = u < 0.5 ? shortArc + reach * smooth(u / 0.5) : longArc
            // Absolute angle = ringStart + 360u (layer turn) + 360·fraction; the
            // drawn arc sits at -90° + (360 - reach)u + tail ... + head.
            let offset = -90 - ringStart - reach * u
            start.append((offset + tail) / 360)
            end.append((offset + head) / 360)
        }
        return (start, end)
    }
}

/// "Running" in session lists and the Goal header: the sun alone in `quiet`,
/// chasing at the 24-box size the system spinner had. CoreAnimation on one
/// shape layer inside an NSView, so no SwiftUI graph is invalidated. Reduce
/// Motion holds a still open arc.
struct PerchBusyIndicator: View {
    var size: CGFloat = 16
    var ink: NSColor = WorkbenchTheme.quietNS
    /// Spoken when the indicator stands alone; nil when the row already says it.
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PerchBusyRepresentable(animated: !reduceMotion, ink: ink)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label ?? ""))
            .accessibilityHidden(label == nil)
    }
}

private struct PerchBusyRepresentable: NSViewRepresentable {
    let animated: Bool
    let ink: NSColor
    func makeNSView(context: Context) -> PerchBusyView { PerchBusyView(animated: animated, color: ink) }
    func updateNSView(_ view: PerchBusyView, context: Context) {
        view.color = ink
        view.animated = animated
    }
}

private final class PerchBusyView: NSView {
    private let sun = CAShapeLayer()
    private var builtSize: CGSize = .zero
    private static let chase = PerchLineMark.chaseKeyframes()
    var color: NSColor { didSet { if color != oldValue { rebuild() } } }
    var animated: Bool { didSet { if animated != oldValue { rebuild() } } }

    override var isFlipped: Bool { true }

    init(animated: Bool, color: NSColor) {
        self.animated = animated
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        sun.fillColor = nil
        sun.lineCap = .round
        layer?.addSublayer(sun)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.size != builtSize else { return }
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Detached layers can drop their animations; a chasing sun restarts.
        if window != nil, animated, sun.animationKeys()?.isEmpty != false { rebuild() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sun.strokeColor = ink
        CATransaction.commit()
    }

    private var ink: CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    private func rebuild() {
        guard bounds.width > 0 else { return }
        let l = PerchLineMark.self
        let unit = bounds.width / 24
        let radius = l.soloRadius * unit, side = 2 * radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sun.removeAllAnimations()
        // The layer is the ring's square, so rotation turns about the centre.
        sun.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        sun.position = CGPoint(x: l.soloCenter.x * unit, y: l.soloCenter.y * unit)
        let path = CGMutablePath()
        let start = l.ringStart * .pi / 180
        path.addArc(center: CGPoint(x: radius, y: radius), radius: radius,
                    startAngle: start, endAngle: start + 2 * .pi, clockwise: false)
        sun.path = path
        sun.lineWidth = l.lineWidth * unit
        sun.strokeColor = ink
        sun.contentsScale = window?.backingScaleFactor ?? 2
        sun.strokeStart = 0
        sun.strokeEnd = l.stillArc
        if animated {
            let chase = Self.chase
            for (key, values) in [("strokeStart", chase.start), ("strokeEnd", chase.end)] {
                let run = CAKeyframeAnimation(keyPath: key)
                run.values = values
                run.calculationMode = .linear
                run.duration = l.revolution
                run.repeatCount = .infinity
                sun.add(run, forKey: key)
            }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = 2 * CGFloat.pi
            turn.duration = l.revolution
            turn.repeatCount = .infinity
            turn.timingFunction = CAMediaTimingFunction(name: .linear)
            sun.add(turn, forKey: "turn")
        }
        CATransaction.commit()
        builtSize = bounds.size
    }
}
