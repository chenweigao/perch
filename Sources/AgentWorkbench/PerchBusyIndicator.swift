import AppKit
import QuartzCore
import SwiftUI

/// The Perch mark as two lines on the 24-unit glyph grid (y down), the grid the
/// agent marks use: a sun ring floating one gap above a branch, left of centre.
/// The gap matters at 16pt; touching strokes merge into an Ω. One source for
/// the status bar, the list rows' running sun and the home mark (`PerchMark`).
/// The app icon keeps the composition on its 1024 canvas at icon weight
/// (`scripts/generate-brand.swift`).
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
    /// below a quarter, so the sun never shrinks to a dot.
    static let revolution: CFTimeInterval = 1.6
    static let shortArc: CGFloat = 90
    static let longArc: CGFloat = 310
    /// Reduce Motion holds this share of the ring still.
    static let stillArc: CGFloat = 0.75
    static let openDuration: CFTimeInterval = 0.25
    static let closeDuration: CFTimeInterval = 0.3

    /// The resting mark's ink extent, for surfaces that crop to it.
    static let contentBounds = CGRect(
        x: branchFrom.x - lineWidth / 2, y: sunCenter.y - sunRadius - lineWidth / 2,
        width: branchTo.x - branchFrom.x + lineWidth,
        height: branchFrom.y - sunCenter.y + sunRadius + lineWidth)
    /// The ink extent squared around its centre. The status bar fits this to its
    /// 16pt slot so the mark carries the weight of the 14pt title beside it
    /// (×1.28 over the 24 box; the line draws at ~1.5pt).
    static let slotBounds = contentBounds.insetBy(dx: 0, dy: -(contentBounds.width - contentBounds.height) / 2)

    /// The resting mark in grid units: the branch in one color, the sun in another.
    static func draw(in cg: CGContext, branch: CGColor, sun: CGColor) {
        cg.saveGState()
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        cg.setStrokeColor(branch)
        cg.move(to: branchFrom)
        cg.addLine(to: branchTo)
        cg.strokePath()
        cg.setStrokeColor(sun)
        cg.strokeEllipse(in: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius,
                                    width: 2 * sunRadius, height: 2 * sunRadius))
        cg.restoreGState()
    }

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

/// Execution feedback in the Perch mark. Running: the sun chases itself around,
/// the head running out and the tail catching up, the familiar spinner read.
/// Not running: the closed, resting mark. Switching from running to rest closes
/// the arc. All motion is CoreAnimation on two shape layers inside one NSView, so
/// the transcript's SwiftUI graph is never invalidated. Reduce Motion holds the
/// open arc still.
///
/// `.bar` (status bar) draws branch and sun fitted to the slot; it runs in the
/// body `ink` and rests in `quiet`, so the moving mark is the one live element
/// beside a quiet title. `.sun` (list rows, Goal header) is the sun alone in
/// `quiet`, at the 24-box size the system spinner had.
struct PerchBusyIndicator: View {
    enum Style { case bar, sun }
    var running = true
    var style: Style = .bar
    var size: CGFloat = 16
    /// Spoken when the indicator stands alone; nil when the row already says it.
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PerchBusyRepresentable(running: running, style: style, animated: !reduceMotion)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label ?? ""))
            .accessibilityHidden(label == nil)
    }
}

private struct PerchBusyRepresentable: NSViewRepresentable {
    let running: Bool
    let style: PerchBusyIndicator.Style
    let animated: Bool

    func makeNSView(context: Context) -> PerchBusyView {
        let view = PerchBusyView(style: style)
        view.update(running: running, animated: animated, transition: false)
        return view
    }

    func updateNSView(_ view: PerchBusyView, context: Context) {
        view.update(running: running, animated: animated, transition: true)
    }
}

private final class PerchBusyView: NSView {
    private let branchLayer = CAShapeLayer()
    private let sunLayer = CAShapeLayer()
    private let style: PerchBusyIndicator.Style
    private var running = false
    private var animated = true
    private static let chase = PerchLineMark.chaseKeyframes()

    override var isFlipped: Bool { true }

    init(style: PerchBusyIndicator.Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        for shape in [branchLayer, sunLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        branchLayer.isHidden = style == .sun
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let g = PerchLineMark.self
        // Grid units to points: the bar fits the mark's ink to the slot; the sun
        // alone keeps the 24 box.
        let frame = style == .bar ? g.slotBounds : CGRect(x: 0, y: 0, width: 24, height: 24)
        let u = bounds.width / frame.width
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - frame.minX) * u, y: (p.y - frame.minY) * u) }
        let center = point(style == .bar ? g.sunCenter : g.soloCenter)
        let radius = (style == .bar ? g.sunRadius : g.soloRadius) * u
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let branch = CGMutablePath()
        branch.move(to: point(g.branchFrom))
        branch.addLine(to: point(g.branchTo))
        branchLayer.path = branch
        // The sun layer is the ring's square, so its rotation turns about the centre.
        sunLayer.bounds = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
        sunLayer.position = center
        let ring = CGMutablePath()
        let start = g.ringStart * .pi / 180
        ring.addArc(center: CGPoint(x: radius, y: radius), radius: radius,
                    startAngle: start, endAngle: start + 2 * .pi, clockwise: false)
        sunLayer.path = ring
        for shape in [branchLayer, sunLayer] {
            shape.lineWidth = g.lineWidth * u
            shape.contentsScale = window?.backingScaleFactor ?? 2
        }
        applyInk()
        CATransaction.commit()
        if running && animated { startRunning(opening: false) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && running && animated { startRunning(opening: false) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyInk()
        CATransaction.commit()
    }

    /// The bar runs in the body ink and rests in quiet; the lone sun is quiet.
    private func ink(running: Bool) -> CGColor {
        let color = style == .bar && running ? WorkbenchTheme.inkNS : WorkbenchTheme.quietNS
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    private func applyInk() {
        let color = ink(running: running)
        branchLayer.strokeColor = color
        sunLayer.strokeColor = color
    }

    /// `transition` animates a state change (open, or close and coast to a stop);
    /// the first configuration applies without motion.
    func update(running: Bool, animated: Bool, transition: Bool) {
        guard !transition || running != self.running || animated != self.animated else { return }
        let moving = transition && animated && running != self.running
        let wasRunning = self.running
        self.running = running
        self.animated = animated
        if running && animated {
            startRunning(opening: moving)
        } else {
            stopRunning(closing: moving && wasRunning)
            // Reduce Motion holds an open arc; rest is the whole ring.
            setStroke(start: 0, end: running ? PerchLineMark.stillArc : 1, animated: moving, duration: PerchLineMark.closeDuration)
        }
        setInk(animated: moving, duration: running ? PerchLineMark.openDuration : PerchLineMark.closeDuration)
    }

    private func setInk(animated: Bool, duration: CFTimeInterval) {
        let color = ink(running: running)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [branchLayer, sunLayer] {
            if animated {
                let fade = CABasicAnimation(keyPath: "strokeColor")
                fade.fromValue = shape.presentation()?.strokeColor ?? shape.strokeColor
                fade.toValue = color
                fade.duration = duration
                shape.add(fade, forKey: "ink")
            }
            shape.strokeColor = color
        }
        CATransaction.commit()
    }

    /// Moves the stroke ends from where they are shown to `start`/`end`.
    private func setStroke(start: CGFloat, end: CGFloat, animated: Bool, duration: CFTimeInterval) {
        let shown = sunLayer.presentation()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            for (key, from, to) in [("strokeStart", shown?.strokeStart ?? sunLayer.strokeStart, start),
                                    ("strokeEnd", shown?.strokeEnd ?? sunLayer.strokeEnd, end)] {
                let move = CABasicAnimation(keyPath: key)
                move.fromValue = from
                move.toValue = to
                move.duration = duration
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sunLayer.add(move, forKey: key + ".move")
            }
        }
        sunLayer.strokeStart = start
        sunLayer.strokeEnd = end
        CATransaction.commit()
    }

    /// Starts the chase. Opening first moves the ring's ends to the chase's first
    /// frame, then the chase takes over; the turn starts at once.
    private func startRunning(opening: Bool) {
        guard bounds.width > 0, sunLayer.animation(forKey: "turn") == nil else { return }
        let g = PerchLineMark.self
        let chase = Self.chase
        setStroke(start: chase.start[0], end: chase.end[0], animated: opening, duration: g.openDuration)

        let now = sunLayer.convertTime(CACurrentMediaTime(), from: nil)
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        // Additive from 0, so each run continues from wherever the last one rested.
        turn.fromValue = 0
        turn.toValue = 2 * CGFloat.pi
        turn.duration = g.revolution
        turn.repeatCount = .infinity
        turn.isAdditive = true
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        sunLayer.add(turn, forKey: "turn")

        for (key, values) in [("strokeStart", chase.start), ("strokeEnd", chase.end)] {
            let run = CAKeyframeAnimation(keyPath: key)
            run.values = values
            run.calculationMode = .linear
            run.duration = g.revolution
            run.repeatCount = .infinity
            run.beginTime = opening ? now + g.openDuration : 0
            sunLayer.add(run, forKey: key + ".chase")
        }
    }

    /// Holds the arc where it is shown, then lets it coast a quarter turn while it
    /// closes.
    private func stopRunning(closing: Bool) {
        guard sunLayer.animation(forKey: "turn") != nil else { return }
        let shown = sunLayer.presentation()
        let angle = CGFloat((shown?.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0)
        let rest = angle + (closing ? .pi / 2 : 0)
        // Freeze the shown ends as the model before the chase is removed, so the
        // close starts from what is on screen.
        let start = shown?.strokeStart ?? sunLayer.strokeStart, end = shown?.strokeEnd ?? sunLayer.strokeEnd
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in ["turn", "strokeStart.chase", "strokeEnd.chase", "strokeStart.move", "strokeEnd.move"] {
            sunLayer.removeAnimation(forKey: key)
        }
        sunLayer.strokeStart = start
        sunLayer.strokeEnd = end
        sunLayer.setValue(rest, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        guard closing else { return }
        let coast = CABasicAnimation(keyPath: "transform.rotation.z")
        coast.fromValue = angle
        coast.toValue = rest
        coast.duration = PerchLineMark.closeDuration
        coast.timingFunction = CAMediaTimingFunction(name: .easeOut)
        sunLayer.add(coast, forKey: "coast")
    }
}
