import AppKit
import QuartzCore
import SwiftUI

/// The conversation activity bar's running state: the Perch sun hops along its
/// branch, squashing on each landing. All motion is CoreAnimation on two layers
/// inside one NSView — like the NSProgressIndicator it replaces, it never
/// invalidates the transcript's SwiftUI graph. Reduce Motion shows the still mark.
struct PerchBusyIndicator: View {
    var height: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PerchBusyRepresentable(animated: !reduceMotion)
            .frame(width: height * PerchBusyGeometry.aspect, height: height)
            .accessibilityHidden(true)
    }
}

/// The approved mark (scripts/generate-brand.swift's 1024 canvas) in a y-down unit
/// space matching the SVG: the branch runs (0,0)-(432,0) with an 84-wide round cap
/// and the sun rests tangent to it, bottom-center at (134, -42), radius 122. The
/// content bounds fit the resting mark; hop arcs rise past them and neither the
/// NSView nor the SwiftUI frame clips them.
private enum PerchBusyGeometry {
    static let contentWidth: CGFloat = 516
    static let contentHeight: CGFloat = 328
    static let aspect: CGFloat = contentWidth / contentHeight

    static let branchFrom = CGPoint.zero
    static let branchTo = CGPoint(x: 432, y: 0)
    static let branchWidth: CGFloat = 84
    static let orbRadius: CGFloat = 122
    /// Rest and landing contact point: the orb's bottom-center on the branch's top edge.
    static let orbRest = CGPoint(x: 134, y: -42)
    static let orbTravel: CGFloat = 166
    static let hopHeight: CGFloat = 56

    static let orbTop = NSColor(srgbRed: 1, green: 0xD9 / 255.0, blue: 0x8E / 255.0, alpha: 1)
    static let orbBottom = NSColor(srgbRed: 1, green: 0x7A / 255.0, blue: 0x59 / 255.0, alpha: 1)

    static func point(_ unit: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (unit.x + 42) * scale, y: (unit.y + 286) * scale)
    }
}

private struct PerchBusyRepresentable: NSViewRepresentable {
    let animated: Bool

    func makeNSView(context: Context) -> PerchBusyView {
        let view = PerchBusyView()
        view.setAnimated(animated)
        return view
    }

    func updateNSView(_ view: PerchBusyView, context: Context) {
        view.setAnimated(animated)
    }
}

/// Branch first, sun above it. The sun's anchor is its bottom-center, so a landing
/// squash spreads from the contact point like a droplet instead of shrinking in place.
private final class PerchBusyView: NSView {
    private let branchLayer = CAShapeLayer()
    private let orbLayer = CALayer()
    private var animated = true

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
        branchLayer.lineCap = .round
        orbLayer.anchorPoint = CGPoint(x: 0.5, y: 1)
        orbLayer.contentsGravity = .resize
        layer?.addSublayer(branchLayer)
        layer?.addSublayer(orbLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard bounds.height > 0 else { return }
        let scale = bounds.height / PerchBusyGeometry.contentHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let branch = CGMutablePath()
        branch.move(to: PerchBusyGeometry.point(PerchBusyGeometry.branchFrom, scale: scale))
        branch.addLine(to: PerchBusyGeometry.point(PerchBusyGeometry.branchTo, scale: scale))
        branchLayer.path = branch
        branchLayer.lineWidth = PerchBusyGeometry.branchWidth * scale
        branchLayer.strokeColor = resolvedInk()

        let diameter = PerchBusyGeometry.orbRadius * 2 * scale
        orbLayer.bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
        orbLayer.position = PerchBusyGeometry.point(PerchBusyGeometry.orbRest, scale: scale)
        let backing = window?.backingScaleFactor ?? 2
        branchLayer.contentsScale = backing
        orbLayer.contentsScale = backing
        orbLayer.contents = PerchBusyView.orbImage(diameter: diameter, scale: backing)
        CATransaction.commit()
        if animated && orbLayer.animation(forKey: "hop") == nil { startHopping() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        branchLayer.strokeColor = resolvedInk()
    }

    private func resolvedInk() -> CGColor {
        var ink = NSColor.secondaryLabelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor.secondaryLabelColor.cgColor }
        return ink
    }

    /// Sunset disc baked from the brand gradient at the exact backing scale. Bitmap
    /// contexts run y-down to the displayed image, so the gradient's start is the top.
    private static func orbImage(diameter: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((diameter * scale).rounded())
        guard pixels > 0, let context = CGContext(data: nil, width: pixels, height: pixels,
                                                  bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.addEllipse(in: rect)
        context.clip()
        let colors = [PerchBusyGeometry.orbTop.cgColor, PerchBusyGeometry.orbBottom.cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        return context.makeImage()
    }

    func setAnimated(_ animated: Bool) {
        guard animated != self.animated else { return }
        self.animated = animated
        if animated { startHopping() } else { orbLayer.removeAllAnimations() }
    }

    /// One cycle: hop right, settle, hop back. Rises ease out, falls ease in; the
    /// squash lands a beat after contact and recovers before the next hop.
    private func startHopping() {
        guard animated, bounds.height > 0 else { return }
        orbLayer.removeAllAnimations()
        let scale = bounds.height / PerchBusyGeometry.contentHeight
        let g = PerchBusyGeometry.self
        let home = g.orbRest
        let away = CGPoint(x: home.x + g.orbTravel, y: home.y)
        let peak = CGPoint(x: home.x + g.orbTravel / 2, y: home.y - g.hopHeight)
        let duration: CFTimeInterval = 1.6

        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = [home, home, peak, away, away, away, away, peak, home, home, home]
            .map { NSValue(point: g.point($0, scale: scale)) }
        position.keyTimes = [0, 0.05, 0.20, 0.36, 0.42, 0.50, 0.55, 0.70, 0.86, 0.92, 1]
        position.duration = duration
        position.repeatCount = .infinity
        position.timingFunctions = PerchBusyView.hopTimings
        orbLayer.add(position, forKey: "hop")

        let squashTimes: [NSNumber] = [0, 0.05, 0.20, 0.36, 0.39, 0.47, 0.50, 0.55, 0.70, 0.86, 0.89, 1]
        let squashX = CAKeyframeAnimation(keyPath: "transform.scale.x")
        squashX.values = [1, 1.12, 0.94, 1, 1.16, 1, 1, 1.12, 0.94, 1, 1.16, 1]
        let squashY = CAKeyframeAnimation(keyPath: "transform.scale.y")
        squashY.values = [1, 0.88, 1.10, 1, 0.84, 1, 1, 0.88, 1.10, 1, 0.84, 1]
        for squash in [squashX, squashY] {
            squash.keyTimes = squashTimes
            squash.duration = duration
            squash.repeatCount = .infinity
            squash.timingFunctions = PerchBusyView.squashTimings
            orbLayer.add(squash, forKey: squash.keyPath)
        }
    }

    private static let hopTimings = [
        CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
        CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
    ]

    private static let squashTimings = [
        CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeInEaseOut),
    ]
}
