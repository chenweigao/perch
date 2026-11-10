import AppKit
import QuartzCore
import SwiftUI
import WorkbenchCore

/// PI's compact nine-dot mark: a slow diagonal breath while thinking, a soft
/// left-to-right ripple while executing, and a still mark when input is needed.
struct ConversationLiveMark: NSViewRepresentable {
    let phase: ConversationRunPhase
    let animated: Bool
    func makeNSView(context: Context) -> ConversationLiveMarkView { ConversationLiveMarkView(phase: phase, animated: animated) }
    func updateNSView(_ view: ConversationLiveMarkView, context: Context) { view.update(phase: phase, animated: animated) }
}

final class ConversationLiveMarkView: NSView {
    private let dots = (0..<9).map { _ in CAShapeLayer() }
    private var phase: ConversationRunPhase
    private var animated: Bool
    private var observers: [NSObjectProtocol] = []
    private var builtSize: CGSize = .zero
    private var playing = false
    private var ink: NSColor { phase.needsInput ? .systemOrange : WorkbenchTheme.quietNS }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(phase: ConversationRunPhase, animated: Bool) {
        self.phase = phase; self.animated = animated
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("conversation-live-mark")
        setAccessibilityElement(false)
        for dot in dots { layer?.addSublayer(dot) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(phase: ConversationRunPhase, animated: Bool) {
        guard self.phase != phase || self.animated != animated else { return }
        self.phase = phase; self.animated = animated
        setInk(); refreshMotion(force: true)
    }
    override func layout() {
        super.layout()
        guard bounds.size != builtSize, bounds.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let unit = min(bounds.width, bounds.height) / 16
        for (index, dot) in dots.enumerated() {
            let x = CGFloat(index % 3) * 4 + 4, y = CGFloat(index / 3) * 4 + 4
            dot.frame = bounds
            dot.path = CGPath(ellipseIn: CGRect(x: (x - 1.25) * unit, y: (y - 1.25) * unit,
                                              width: 2.5 * unit, height: 2.5 * unit), transform: nil)
            dot.contentsScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
        builtSize = bounds.size; setInk(); refreshMotion(force: true)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); setInk() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let window {
            // orderOut can resign key/main before macOS delivers an occlusion
            // change. Recheck actual visibility on those lifecycle events too.
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.refreshMotion()
                })
            }
        }
        refreshMotion(force: true)
    }
    private func setInk() {
        var color = ink.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = ink.cgColor }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for dot in dots { dot.fillColor = color }
        CATransaction.commit()
    }
    private func refreshMotion(force: Bool = false) {
        let shouldPlay = animated && phase.animates && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        guard force || shouldPlay != playing else { return }
        playing = shouldPlay
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.removeAllAnimations(); dot.opacity = phase.needsInput ? 0.7 : 0.5
            if shouldPlay {
                let duration = phase == .executing ? 1.6 : phase == .thinking ? 2.4 : 2.0
                let delay = phase == .executing ? Double(index % 3) * 0.16 : Double(index % 3 + index / 3) * 0.18
                let breath = CAKeyframeAnimation(keyPath: "opacity")
                breath.values = [0.24, 0.9, 0.24]
                breath.keyTimes = [0, 0.5, 1]
                breath.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                breath.duration = duration; breath.repeatCount = .infinity
                breath.beginTime = CACurrentMediaTime() - delay
                dot.add(breath, forKey: "live-breath")
            }
        }
        CATransaction.commit()
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
