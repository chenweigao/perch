import CoreGraphics
import Foundation

/// Agents with a designed brand mark. `SessionKind.terminal` intentionally has
/// none: the system terminal glyph already says it.
enum AgentMarkKind: String, CaseIterable {
    case kimi, omp, qoder, qoderintl, dsh, codex, claude
}

/// Pure CoreGraphics geometry shared by the SwiftUI mark and the NSImage used
/// in native menus. One drawing source keeps every size and both appearances
/// identical. Glyph space is a 24×24 grid, y pointing down; both Canvas
/// (`withCGContext`) and a flipped NSImage drawing handler match it.
///
/// Marks are line glyphs with no badge, the same language as the SF Symbols
/// around them: a 1.75-unit round stroke (≈1pt at the 14pt sidebar size) inside
/// an 18×18 live area, and at most one small filled accent (Kimi's star, the
/// whale's eye). Each line keeps its brand hue, darkened for light and lifted
/// for dark so a thin stroke holds ≥3:1 on the sidebar and its selected card.
/// Kimi and Codex brands are black and white, so they take the sidebar's
/// secondary icon ink and stay apart by shape.
enum AgentMarkArtwork {
    static let lineWidth: CGFloat = 1.75

    static func draw(_ kind: AgentMarkKind, in rect: CGRect, dark: Bool, context cg: CGContext) {
        let u = rect.width / 24
        let ink = tint(for: kind, dark: dark)
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: u, y: u)
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setStrokeColor(ink)
        cg.addPath(stroke(for: kind))
        cg.strokePath()
        switch kind {
        case .kimi:
            cg.setFillColor(dark ? rgb(0x6EA8FE) : rgb(0x2F7BF5))
            cg.fillEllipse(in: circle(17.6, 6.5, 1.55))
        case .dsh:
            cg.setFillColor(ink)
            cg.fillEllipse(in: circle(7.3, 12.3, 0.95))
        default:
            break
        }
        cg.restoreGState()
    }

    private static func tint(for kind: AgentMarkKind, dark: Bool) -> CGColor {
        switch kind {
        case .kimi, .codex: return dark ? rgb(0xA3A6AD) : rgb(0x5A5F69)
        case .claude: return dark ? rgb(0xE8936A) : rgb(0xC8643F)
        case .qoder: return dark ? rgb(0xFF9550) : rgb(0xD35F08)
        case .qoderintl: return dark ? rgb(0x9C8CFF) : rgb(0x5B45E0)
        case .dsh: return dark ? rgb(0x7194FF) : rgb(0x3461E6)
        case .omp: return dark ? rgb(0xF2BA52) : rgb(0xB7740F)
        }
    }

    // Geometry does not depend on size or appearance, so each path is built once.
    private static func stroke(for kind: AgentMarkKind) -> CGPath {
        switch kind {
        case .kimi: return moonPath
        case .claude: return sparkPath
        case .codex: return knotPath
        case .qoder, .qoderintl: return qPath
        case .dsh: return whalePath
        case .omp: return piPath
        }
    }

    /// Waning moon outline; the star is filled into its bite in `draw`.
    private static let moonPath = crescent(CGPoint(x: 11.25, y: 12.75), 7.75, minus: CGPoint(x: 16.25, y: 8.0), 6.0)

    /// Eight rays meeting in a closed core, alternating long and short and turned
    /// off the axes. The closed core and uneven rays keep it apart from the hollow,
    /// even busy spinner that shares the row.
    private static let sparkPath: CGPath = {
        let path = CGMutablePath()
        for i in 0..<8 {
            let a: CGFloat = CGFloat(i) * (.pi / 4) - 3 * .pi / 8
            let r: CGFloat = i.isMultiple(of: 2) ? 8.6 : 6.2
            path.move(to: CGPoint(x: 12, y: 12))
            path.addLine(to: polar(r, a))
        }
        return path
    }()

    /// OpenAI knot as a hexagon whose six chords fold into short spokes. The
    /// spokes stop at r 4.4 and lean 30°, so the centre stays open at 12–14pt.
    private static let knotPath: CGPath = {
        let path = CGMutablePath()
        for i in 0..<6 {
            let a: CGFloat = CGFloat(i) * (.pi / 3) - .pi / 2
            let b: CGFloat = a + .pi / 3
            path.move(to: polar(8.2, a))
            path.addLine(to: polar(8.2, b))
            path.addLine(to: polar(4.4, b + .pi / 6))
        }
        return path
    }()

    /// A typographic Q: the tail starts inside the bowl and leaves at a shallow
    /// angle. A ring with a 45° outer handle would be the sidebar's search glyph.
    private static let qPath: CGPath = {
        let path = CGMutablePath()
        path.addEllipse(in: circle(11.6, 11.1, 7.6))
        path.move(to: CGPoint(x: 13.2, y: 14.6))
        path.addLine(to: CGPoint(x: 20.4, y: 20.2))
        return path
    }()

    /// Whale in two strokes: the back runs into a tail that curls up into a
    /// fluke, then the belly. The eye is filled in `draw`.
    private static let whalePath: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2.9, y: 14.4))
        path.addCurve(to: CGPoint(x: 15.4, y: 9.9), control1: CGPoint(x: 3.9, y: 8.9), control2: CGPoint(x: 10.4, y: 6.7))
        path.addCurve(to: CGPoint(x: 19.3, y: 9.6), control1: CGPoint(x: 17.0, y: 10.9), control2: CGPoint(x: 18.1, y: 11.0))
        path.addCurve(to: CGPoint(x: 21.1, y: 5.6), control1: CGPoint(x: 20.3, y: 8.4), control2: CGPoint(x: 20.8, y: 7.1))
        path.addCurve(to: CGPoint(x: 17.9, y: 7.3), control1: CGPoint(x: 19.7, y: 5.7), control2: CGPoint(x: 18.6, y: 6.3))
        path.move(to: CGPoint(x: 2.9, y: 14.4))
        path.addCurve(to: CGPoint(x: 17.9, y: 13.2), control1: CGPoint(x: 5.0, y: 19.4), control2: CGPoint(x: 13.4, y: 19.6))
        return path
    }()

    /// π: crossbar, a left leg that sweeps out, a right leg with a small foot.
    private static let piPath: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4.8, y: 7.2))
        path.addLine(to: CGPoint(x: 19.2, y: 7.2))
        path.move(to: CGPoint(x: 9.4, y: 7.2))
        path.addCurve(to: CGPoint(x: 6.8, y: 18.4), control1: CGPoint(x: 9.4, y: 11.6), control2: CGPoint(x: 8.7, y: 15.4))
        path.move(to: CGPoint(x: 14.8, y: 7.2))
        path.addLine(to: CGPoint(x: 14.8, y: 15.6))
        path.addCurve(to: CGPoint(x: 18.3, y: 17.8), control1: CGPoint(x: 14.8, y: 17.7), control2: CGPoint(x: 16.3, y: 18.7))
        return path
    }()

    /// Outline of the disc (c1, r1) minus the disc (c2, r2). Angles grow
    /// clockwise on screen in this y-down space, which is CG's `clockwise: false`.
    private static func crescent(_ c1: CGPoint, _ r1: CGFloat, minus c2: CGPoint, _ r2: CGFloat) -> CGPath {
        let d = hypot(c2.x - c1.x, c2.y - c1.y)
        let alpha = atan2(c2.y - c1.y, c2.x - c1.x)
        let beta = acos((d * d + r1 * r1 - r2 * r2) / (2 * d * r1))
        let p = polar(r1, alpha + beta, around: c1)
        let q = polar(r1, alpha - beta, around: c1)
        let path = CGMutablePath()
        path.move(to: p)
        // Outer rim: the long way from P to Q, away from the bite.
        path.addArc(center: c1, radius: r1, startAngle: alpha + beta, endAngle: alpha - beta + 2 * .pi, clockwise: false)
        // Bite edge: back from Q to P along the side of c2 that faces c1.
        path.addArc(center: c2, radius: r2, startAngle: atan2(q.y - c2.y, q.x - c2.x),
                    endAngle: atan2(p.y - c2.y, p.x - c2.x), clockwise: true)
        path.closeSubpath()
        return path
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect {
        CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
    }

    private static func polar(_ r: CGFloat, _ angle: CGFloat, around c: CGPoint = CGPoint(x: 12, y: 12)) -> CGPoint {
        CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
