import AppKit
import QuartzCore
import SwiftUI

/// The Perch mark as two lines on the 24-unit glyph grid (y down), the grid the
/// agent marks use: a sun ring floating one gap above a branch, left of centre.
/// The gap matters at 16pt; touching strokes merge into an Ω. One source for
/// the status bar, the sidebar's running arc and the home mark (`PerchMark`).
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
    /// While a turn runs the ring opens to this share and turns; closed is rest.
    static let runningArc: CGFloat = 0.75
    static let revolution: CFTimeInterval = 1.2
    static let openDuration: CFTimeInterval = 0.25
    static let closeDuration: CFTimeInterval = 0.3

    /// The resting mark's ink extent, for surfaces that crop to it.
    static let contentBounds = CGRect(
        x: branchFrom.x - lineWidth / 2, y: sunCenter.y - sunRadius - lineWidth / 2,
        width: branchTo.x - branchFrom.x + lineWidth,
        height: branchFrom.y - sunCenter.y + sunRadius + lineWidth)

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
}

/// Execution feedback in the Perch mark. Running: the branch holds still and the
/// sun opens into an arc that turns at a constant speed, the familiar spinner
/// read. Not running: the closed, resting mark. Switching from running to rest
/// closes the arc. All motion is CoreAnimation on two shape layers inside one
/// NSView, so the transcript's SwiftUI graph is never invalidated. Reduce Motion
/// keeps the open arc still. Ink is the status bar's `quiet`.
struct PerchBusyIndicator: View {
    var running = true
    /// The status bar draws the whole mark; list rows show only the turning sun.
    var showsBranch = true
    var size: CGFloat = 16
    /// Spoken when the indicator stands alone; nil when the row already says it.
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PerchBusyRepresentable(running: running, showsBranch: showsBranch, animated: !reduceMotion)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label ?? ""))
            .accessibilityHidden(label == nil)
    }
}

private struct PerchBusyRepresentable: NSViewRepresentable {
    let running: Bool
    let showsBranch: Bool
    let animated: Bool

    func makeNSView(context: Context) -> PerchBusyView {
        let view = PerchBusyView(showsBranch: showsBranch)
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
    private let showsBranch: Bool
    private var running = false
    private var animated = true

    override var isFlipped: Bool { true }

    init(showsBranch: Bool) {
        self.showsBranch = showsBranch
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        for shape in [branchLayer, sunLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        branchLayer.isHidden = !showsBranch
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let g = PerchLineMark.self
        let u = bounds.width / 24
        let center = showsBranch ? g.sunCenter : g.soloCenter
        let radius = (showsBranch ? g.sunRadius : g.soloRadius) * u
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let branch = CGMutablePath()
        branch.move(to: CGPoint(x: g.branchFrom.x * u, y: g.branchFrom.y * u))
        branch.addLine(to: CGPoint(x: g.branchTo.x * u, y: g.branchTo.y * u))
        branchLayer.path = branch
        // The sun layer is the ring's square, so its rotation turns about the centre.
        sunLayer.bounds = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
        sunLayer.position = CGPoint(x: center.x * u, y: center.y * u)
        sunLayer.path = CGPath(ellipseIn: sunLayer.bounds, transform: nil)
        for shape in [branchLayer, sunLayer] {
            shape.lineWidth = g.lineWidth * u
            shape.contentsScale = window?.backingScaleFactor ?? 2
        }
        applyInk()
        CATransaction.commit()
        if running && animated { startTurning() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && running && animated { startTurning() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyInk()
        CATransaction.commit()
    }

    private func applyInk() {
        var ink = WorkbenchTheme.quietNS.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = WorkbenchTheme.quietNS.cgColor }
        branchLayer.strokeColor = ink
        sunLayer.strokeColor = ink
    }

    /// `transition` animates a state change (open, or close and coast to a stop);
    /// the first configuration applies without motion.
    func update(running: Bool, animated: Bool, transition: Bool) {
        guard !transition || running != self.running || animated != self.animated else { return }
        let moving = transition && animated && running != self.running
        self.running = running
        self.animated = animated
        let arc = running ? PerchLineMark.runningArc : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if moving {
            let resize = CABasicAnimation(keyPath: "strokeEnd")
            resize.fromValue = sunLayer.presentation()?.strokeEnd ?? sunLayer.strokeEnd
            resize.toValue = arc
            resize.duration = running ? PerchLineMark.openDuration : PerchLineMark.closeDuration
            resize.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sunLayer.add(resize, forKey: "arc")
        }
        sunLayer.strokeEnd = arc
        CATransaction.commit()
        if running && animated { startTurning() } else { stopTurning(coasting: moving) }
    }

    private func startTurning() {
        guard sunLayer.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        // Additive from 0, so each run continues from wherever the last one rested.
        turn.fromValue = 0
        turn.toValue = 2 * CGFloat.pi
        turn.duration = PerchLineMark.revolution
        turn.repeatCount = .infinity
        turn.isAdditive = true
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        sunLayer.add(turn, forKey: "turn")
    }

    /// Holds the arc where it is, then lets it coast a quarter turn while it closes.
    private func stopTurning(coasting: Bool) {
        guard sunLayer.animation(forKey: "turn") != nil else { return }
        let shown = sunLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber
        let angle = CGFloat(shown?.doubleValue ?? 0)
        let rest = angle + (coasting ? .pi / 2 : 0)
        sunLayer.removeAnimation(forKey: "turn")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sunLayer.setValue(rest, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        guard coasting else { return }
        let coast = CABasicAnimation(keyPath: "transform.rotation.z")
        coast.fromValue = angle
        coast.toValue = rest
        coast.duration = PerchLineMark.closeDuration
        coast.timingFunction = CAMediaTimingFunction(name: .easeOut)
        sunLayer.add(coast, forKey: "coast")
    }
}
