import AppKit
import QuartzCore
import SwiftUI

/// Execution-feedback geometry on the 24-unit glyph grid (y down): a sun ring
/// floating over a branch. Used by phase motions and list rows. The brand bird
/// lives in `PerchBirdGeometry` and does not change these execution cues.
enum PerchLineMark {
    static let lineWidth: CGFloat = 1.75
    static let branchFrom = CGPoint(x: 3.5, y: 19.25)
    static let branchTo = CGPoint(x: 20.5, y: 19.25)
    static let sunCenter = CGPoint(x: 10, y: 10.75)
    static let sunRadius: CGFloat = 5.5
    /// List rows show the sun alone, centred and larger, in the 16pt slot the
    /// system spinner used.
    static let soloCenter = CGPoint(x: 12, y: 12)
    static let soloRadius: CGFloat = 7

    /// Running is a chase: the arc's head runs out from a quarter to most of the
    /// ring, then its tail catches up, once per revolution. The arc never drops
    /// below a quarter, so the sun never shrinks to a dot. Slow and narrow
    /// enough to stay at the edge of the reader's eye.
    static let revolution: CFTimeInterval = 2
    static let shortArc: CGFloat = 90
    static let longArc: CGFloat = 270
    /// Reduce Motion holds this share of the ring still.
    static let stillArc: CGFloat = 0.75
    static let openDuration: CFTimeInterval = 0.25
    static let closeDuration: CFTimeInterval = 0.3

    /// The status bar gives each phase of a turn its own motion of the same mark.
    /// Thinking: the whole sun breathes, shrinking and fading a little.
    static let thinkPeriod: CFTimeInterval = 2.8
    static let thinkShrink: CGFloat = 0.6
    static let thinkFade: Float = 0.7
    /// Reading or searching: a short arc sweeps back and forth over the top.
    static let scanPeriod: CFTimeInterval = 2.2
    static let scanArc: CGFloat = 110
    static let scanSwing: CGFloat = 80
    /// Writing the reply: the sun rests whole and the branch is written left to
    /// right like a line of text, then fades for the next line.
    static let writePeriod: CFTimeInterval = 2.2
    static let writeDrawShare: Double = 0.62
    static let writeBaseOpacity: Float = 0.35
    /// Phases cross-fade, and each holds at least `phaseDwell`, so a burst of short
    /// tool calls does not flicker between motions.
    static let phaseCrossfade: CFTimeInterval = 0.3
    static let phaseDwell: CFTimeInterval = 1

    /// The resting mark's ink extent, for surfaces that crop to it.
    static let contentBounds = CGRect(
        x: branchFrom.x - lineWidth / 2, y: sunCenter.y - sunRadius - lineWidth / 2,
        width: branchTo.x - branchFrom.x + lineWidth,
        height: branchFrom.y - sunCenter.y + sunRadius + lineWidth)
    /// The ink extent squared around its centre. The status bar fits this to its
    /// 16pt slot so the mark carries the weight of the 14pt title beside it
    /// (×1.28 over the 24 box; the line draws at ~1.5pt).
    static let slotBounds = contentBounds.insetBy(dx: 0, dy: -(contentBounds.width - contentBounds.height) / 2)

    /// Where the sun ring's path starts, in degrees. The chase is drawn as
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

/// Execution feedback in the Perch mark. While a turn runs, the status bar gives
/// each phase its own motion: thinking breathes, reading sweeps, working chases,
/// writing writes the branch. Phases cross-fade and hold at least a second. When
/// the turn ends, the motion settles into the closed, resting mark. All motion is
/// CoreAnimation on shape layers inside one NSView, so the transcript's SwiftUI
/// graph is never invalidated. Reduce Motion holds a still open arc.
///
/// `.bar` (status bar) draws branch and sun fitted to the slot, in `quiet` like
/// the title beside it: running is peripheral information, and what needs the
/// reader is called out by color and reminders instead. `.sun` (list rows, Goal header) is the sun alone in
/// `quiet`, at the 24-box size the system spinner had, and always chases: a list
/// of running sessions should not each change motion.
struct PerchBusyIndicator: View {
    enum Style { case bar, sun }
    enum Motion: Equatable { case thinking, reading, working, writing }
    var running = true
    var motion: Motion = .working
    var style: Style = .bar
    var size: CGFloat = 16
    /// Spoken when the indicator stands alone; nil when the row already says it.
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PerchBusyRepresentable(running: running, motion: motion, style: style, animated: !reduceMotion)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label ?? ""))
            .accessibilityHidden(label == nil)
    }
}

private struct PerchBusyRepresentable: NSViewRepresentable {
    let running: Bool
    let motion: PerchBusyIndicator.Motion
    let style: PerchBusyIndicator.Style
    let animated: Bool

    func makeNSView(context: Context) -> PerchBusyView {
        let view = PerchBusyView(style: style)
        view.update(running: running, motion: motion, animated: animated, transition: false)
        return view
    }

    func updateNSView(_ view: PerchBusyView, context: Context) {
        view.update(running: running, motion: motion, animated: animated, transition: true)
    }

    static func dismantleNSView(_ view: PerchBusyView, coordinator: ()) { view.cancelPendingSwitch() }
}

/// One drawing of the mark: branch, the writing stroke over it, and the sun.
private final class PerchMarkLayers {
    let root = CALayer()
    let branch = CAShapeLayer()
    let stroke = CAShapeLayer()
    let sun = CAShapeLayer()
    var shapes: [CAShapeLayer] { [branch, stroke, sun] }

    init() {
        for shape in shapes {
            shape.fillColor = nil
            shape.lineCap = .round
            root.addSublayer(shape)
        }
    }
}

private final class PerchBusyView: NSView {
    typealias Motion = PerchBusyIndicator.Motion
    private enum Shown: Equatable { case rest, still, moving(Motion) }

    private let style: PerchBusyIndicator.Style
    private var running = false
    private var animated = true
    private var requested: Motion = .working
    private var shown: Shown = .rest
    private var marks: PerchMarkLayers?
    private var builtSize: CGSize = .zero
    private var lastSwitch: CFTimeInterval = 0
    private var pendingSwitch: DispatchWorkItem?
    private static let chase = PerchLineMark.chaseKeyframes()

    override var isFlipped: Bool { true }

    init(style: PerchBusyIndicator.Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: State

    private var target: Shown {
        if !running { return .rest }
        if !animated { return .still }
        return .moving(style == .sun ? .working : requested)
    }

    /// `transition` animates a state change; the first configuration applies
    /// without motion.
    func update(running: Bool, motion: Motion, animated: Bool, transition: Bool) {
        self.running = running
        self.animated = animated
        requested = motion
        let next = target
        guard next != shown || marks == nil else { cancelPendingSwitch(); return }
        guard transition, animated, marks != nil else { cancelPendingSwitch(); show(next, fade: 0); return }
        switch (shown, next) {
        case (.moving, .moving):
            // A new phase waits out the current one's minimum hold.
            let wait = lastSwitch + PerchLineMark.phaseDwell - CACurrentMediaTime()
            if wait <= 0 { cancelPendingSwitch(); show(next, fade: PerchLineMark.phaseCrossfade); return }
            guard pendingSwitch == nil else { return }  // it applies the latest request when it fires
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingSwitch = nil
                if case .moving = self.target, self.target != self.shown { self.show(self.target, fade: PerchLineMark.phaseCrossfade) }
            }
            pendingSwitch = item
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
        case (_, .rest):
            cancelPendingSwitch()
            settle()
        default:
            cancelPendingSwitch()
            show(next, fade: PerchLineMark.openDuration)
        }
    }

    func cancelPendingSwitch() {
        pendingSwitch?.cancel()
        pendingSwitch = nil
    }

    // MARK: Layout and appearance

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.size != builtSize else { return }
        show(shown, fade: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Detached layers can drop their animations; a moving mark restarts.
        if window != nil, case .moving = shown,
           marks?.shapes.allSatisfy({ $0.animationKeys()?.isEmpty != false }) != false { show(shown, fade: 0) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let marks else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let color = ink(for: shown)
        for shape in marks.shapes { shape.strokeColor = color }
        CATransaction.commit()
    }

    /// Every style and state draws in quiet, the status line's own ink.
    private func ink(for state: Shown) -> CGColor {
        let color = WorkbenchTheme.quietNS
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    // MARK: Geometry

    private struct Geometry {
        let unit: CGFloat
        let origin: CGPoint
        let center: CGPoint
        let radius: CGFloat
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) * unit, y: (p.y - origin.y) * unit) }
    }

    /// Grid units to points: the bar fits the mark's ink to the slot; the sun alone
    /// keeps the 24 box.
    private var geometry: Geometry {
        let g = PerchLineMark.self
        let frame = style == .bar ? g.slotBounds : CGRect(x: 0, y: 0, width: 24, height: 24)
        let u = bounds.width / frame.width
        let center = style == .bar ? g.sunCenter : g.soloCenter
        return Geometry(unit: u, origin: frame.origin,
                        center: CGPoint(x: (center.x - frame.minX) * u, y: (center.y - frame.minY) * u),
                        radius: (style == .bar ? g.sunRadius : g.soloRadius) * u)
    }

    /// The sun ring inside its square layer, starting at `ringStart`. Every ring is
    /// built the same way, so a path animation between radii stays valid.
    private static func ring(in side: CGFloat, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let start = PerchLineMark.ringStart * .pi / 180
        path.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: radius,
                    startAngle: start, endAngle: start + 2 * .pi, clockwise: false)
        return path
    }

    /// Stroke fraction of the ring path for an absolute angle in degrees.
    private static func fraction(_ degrees: CGFloat) -> CGFloat { (degrees - PerchLineMark.ringStart) / 360 }

    // MARK: Drawing

    /// Replaces the drawn mark with `state`, cross-fading over `fade` seconds.
    private func show(_ state: Shown, fade: CFTimeInterval) {
        guard let host = layer, bounds.width > 0 else { shown = state; return }
        let next = makeMarks(state)
        let previous = marks
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(next.root)
        if fade > 0, let previous {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = fade
            next.root.add(appear, forKey: "fade")
            let vanish = CABasicAnimation(keyPath: "opacity")
            vanish.fromValue = previous.root.presentation()?.opacity ?? 1
            previous.root.opacity = 0
            vanish.toValue = 0
            vanish.duration = fade
            previous.root.add(vanish, forKey: "fade")
            DispatchQueue.main.asyncAfter(deadline: .now() + fade) { previous.root.removeFromSuperlayer() }
        } else {
            previous?.root.removeFromSuperlayer()
        }
        CATransaction.commit()
        marks = next
        shown = state
        builtSize = bounds.size
        if case .moving = state { lastSwitch = CACurrentMediaTime() }
    }

    private func makeMarks(_ state: Shown) -> PerchMarkLayers {
        let g = geometry, l = PerchLineMark.self
        let m = PerchMarkLayers()
        let side = 2 * g.radius
        m.root.frame = bounds
        let branch = CGMutablePath()
        branch.move(to: g.point(l.branchFrom))
        branch.addLine(to: g.point(l.branchTo))
        m.branch.path = branch
        m.stroke.path = branch
        m.stroke.strokeEnd = 0
        m.branch.isHidden = style == .sun
        m.stroke.isHidden = style == .sun
        // The sun layer is the ring's square, so rotation turns about the centre.
        m.sun.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        m.sun.position = g.center
        m.sun.path = Self.ring(in: side, radius: g.radius)
        let color = ink(for: state)
        for shape in m.shapes {
            shape.lineWidth = l.lineWidth * g.unit
            shape.strokeColor = color
            shape.contentsScale = window?.backingScaleFactor ?? 2
        }
        switch state {
        case .rest: break
        case .still: m.sun.strokeEnd = l.stillArc
        case .moving(let motion): animate(m, motion, side: side, radius: g.radius)
        }
        return m
    }

    private func animate(_ m: PerchMarkLayers, _ motion: Motion, side: CGFloat, radius: CGFloat) {
        let l = PerchLineMark.self
        switch motion {
        case .working:
            let chase = Self.chase
            m.sun.strokeStart = chase.start[0]
            m.sun.strokeEnd = chase.end[0]
            for (key, values) in [("strokeStart", chase.start), ("strokeEnd", chase.end)] {
                let run = CAKeyframeAnimation(keyPath: key)
                run.values = values
                run.calculationMode = .linear
                run.duration = l.revolution
                run.repeatCount = .infinity
                m.sun.add(run, forKey: key)
            }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = 2 * CGFloat.pi
            turn.duration = l.revolution
            turn.repeatCount = .infinity
            turn.timingFunction = CAMediaTimingFunction(name: .linear)
            m.sun.add(turn, forKey: "turn")
        case .reading:
            m.sun.strokeStart = Self.fraction(-90 - l.scanArc / 2)
            m.sun.strokeEnd = Self.fraction(-90 + l.scanArc / 2)
            let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
            sweep.fromValue = -l.scanSwing * .pi / 180
            sweep.toValue = l.scanSwing * .pi / 180
            sweep.duration = l.scanPeriod / 2
            sweep.autoreverses = true
            sweep.repeatCount = .infinity
            // Start from the top, mid-sweep.
            sweep.timeOffset = l.scanPeriod / 4
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            m.sun.add(sweep, forKey: "turn")
        case .thinking:
            let breathe = CAAnimationGroup()
            let size = CABasicAnimation(keyPath: "path")
            size.fromValue = m.sun.path
            size.toValue = Self.ring(in: side, radius: radius - l.thinkShrink * (radius / (style == .bar ? l.sunRadius : l.soloRadius)))
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = l.thinkFade
            size.duration = l.thinkPeriod / 2
            fade.duration = l.thinkPeriod / 2
            breathe.animations = [size, fade]
            breathe.duration = l.thinkPeriod / 2
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            m.sun.add(breathe, forKey: "breathe")
        case .writing:
            m.branch.opacity = l.writeBaseOpacity
            let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
            draw.values = [0, 1, 1]
            draw.keyTimes = [0, NSNumber(value: l.writeDrawShare), 1]
            draw.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = draw.keyTimes
            fade.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
            draw.duration = l.writePeriod
            fade.duration = l.writePeriod
            let line = CAAnimationGroup()
            line.animations = [draw, fade]
            line.duration = l.writePeriod
            line.repeatCount = .infinity
            m.stroke.add(line, forKey: "write")
        }
    }

    /// Ends a turn: freezes whatever is on screen, then closes it into the resting
    /// mark. Arcs grow to the full ring while coasting a quarter turn; a breathing
    /// sun returns to full size; a half-written branch fills in.
    private func settle() {
        guard let m = marks else { show(.rest, fade: 0); return }
        let l = PerchLineMark.self
        let quiet = ink(for: .rest)
        let arc = shown != .moving(.thinking) && shown != .moving(.writing)
        let duration = l.closeDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in m.shapes {
            let p = shape.presentation()
            let from = (start: p?.strokeStart ?? shape.strokeStart, end: p?.strokeEnd ?? shape.strokeEnd,
                        opacity: p?.opacity ?? shape.opacity, path: p?.path ?? shape.path, color: p?.strokeColor ?? shape.strokeColor,
                        angle: CGFloat((p?.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0))
            shape.removeAllAnimations()
            let to: (start: CGFloat, end: CGFloat, opacity: Float, angle: CGFloat)
            switch shape {
            case m.sun: to = (0, 1, 1, from.angle + (arc ? .pi / 2 : 0))
            case m.branch: to = (0, 1, 1, 0)
            default: to = (0, from.end, 0, 0)   // the writing stroke fades where it is
            }
            var moves: [CAAnimation] = []
            func move(_ key: String, _ a: Any?, _ b: Any?) {
                let anim = CABasicAnimation(keyPath: key)
                anim.fromValue = a
                anim.toValue = b
                anim.duration = duration
                moves.append(anim)
            }
            move("strokeStart", from.start, to.start)
            move("strokeEnd", from.end, to.end)
            move("opacity", from.opacity, to.opacity)
            move("strokeColor", from.color, quiet)
            if shape === m.sun {
                move("transform.rotation.z", from.angle, to.angle)
                move("path", from.path, shape.path)
            }
            let group = CAAnimationGroup()
            group.animations = moves
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shape.add(group, forKey: "settle")
            shape.strokeStart = to.start
            shape.strokeEnd = to.end
            shape.opacity = to.opacity
            shape.strokeColor = quiet
            if shape === m.sun { shape.setValue(to.angle, forKeyPath: "transform.rotation.z") }
        }
        CATransaction.commit()
        shown = .rest
    }
}
