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
enum AgentMarkArtwork {
    static func draw(_ kind: AgentMarkKind, in rect: CGRect, context cg: CGContext) {
        let u = rect.width / 24
        let badge = rect.insetBy(dx: 0.5 * u, dy: 0.5 * u)
        let badgePath = CGPath(roundedRect: badge, cornerWidth: 5.6 * u, cornerHeight: 5.6 * u, transform: nil)
        cg.saveGState()
        cg.addPath(badgePath)
        cg.clip()
        if let gradient = badgeGradient(for: kind) {
            cg.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                  end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        } else {
            cg.setFillColor(badgeColor(for: kind))
            cg.fill(badge)
        }
        cg.restoreGState()

        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: u, y: u)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        drawGlyph(kind, context: cg)
        cg.restoreGState()

        // Hairline edge keeps dark badges readable on dark glass.
        cg.saveGState()
        cg.setStrokeColor(CGColor(gray: 1, alpha: 0.13))
        cg.setLineWidth(0.5 * u)
        cg.addPath(CGPath(roundedRect: badge.insetBy(dx: 0.25 * u, dy: 0.25 * u),
                          cornerWidth: 5.4 * u, cornerHeight: 5.4 * u, transform: nil))
        cg.strokePath()
        cg.restoreGState()
    }

    private static func badgeColor(for kind: AgentMarkKind) -> CGColor {
        switch kind {
        case .kimi: return rgb(0x141519)
        case .omp: return rgb(0xE9A83E)
        case .qoder: return rgb(0xF4760C)
        case .qoderintl: return rgb(0x6D54F0)
        case .dsh: return rgb(0x3E6BF2)
        case .codex: return rgb(0x16171B)
        case .claude: return rgb(0xD97757)
        }
    }

    private static func badgeGradient(for kind: AgentMarkKind) -> CGGradient? {
        switch kind {
        // Solid badges: the Kimi crescent is punched with the badge color and a
        // flat black tile matches the brand; other marks carry a subtle lift.
        case .kimi: return nil
        case .omp: return gradient(0xF4BC55, 0xDE9526)
        case .qoder: return gradient(0xFF8D41, 0xEC6608)
        case .qoderintl: return gradient(0x8A77FF, 0x5843E3)
        case .dsh: return gradient(0x5A88FF, 0x2C55DC)
        case .codex: return gradient(0x2A2C33, 0x101114)
        case .claude: return gradient(0xE28A60, 0xC96043)
        }
    }

    private static func drawGlyph(_ kind: AgentMarkKind, context cg: CGContext) {
        let white = CGColor(gray: 1, alpha: 1)
        switch kind {
        case .kimi:
            // Waning moon plus the Kimi azure star. The bite is painted in the
            // solid badge color, which is why the badge stays flat.
            cg.setFillColor(white)
            cg.fillEllipse(in: CGRect(x: 5.4, y: 6.6, width: 11.4, height: 11.4))
            cg.setFillColor(badgeColor(for: .kimi))
            cg.fillEllipse(in: CGRect(x: 9.7, y: 5.6, width: 9.8, height: 9.8))
            cg.setFillColor(rgb(0x6EA8FE))
            cg.fillEllipse(in: CGRect(x: 15.4, y: 5.9, width: 3.3, height: 3.3))
        case .claude:
            // Radial spark: twelve rounded rays.
            cg.setStrokeColor(white)
            cg.setLineWidth(2.05)
            for i in 0..<12 {
                let a = CGFloat(i) * .pi / 6 - .pi / 2
                cg.move(to: polar(3.1, a))
                cg.addLine(to: polar(6.6, a))
            }
            cg.strokePath()
        case .codex:
            // OpenAI knot, simplified to a six-blade pinwheel: each blade is one
            // hexagon chord folding into a radial spoke.
            cg.setStrokeColor(white)
            cg.setLineWidth(1.9)
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 - .pi / 2
                let b = a + .pi / 3
                cg.move(to: polar(5.5, a))
                cg.addLine(to: polar(5.5, b))
                cg.addLine(to: polar(2.7, b))
            }
            cg.strokePath()
        case .qoder, .qoderintl:
            cg.setStrokeColor(white)
            cg.setLineWidth(2.1)
            cg.strokeEllipse(in: CGRect(x: 6.3, y: 6.3, width: 9.8, height: 9.8))
            cg.move(to: CGPoint(x: 14.4, y: 14.4))
            cg.addLine(to: CGPoint(x: 18.0, y: 18.0))
            cg.strokePath()
        case .dsh:
            cg.setFillColor(white)
            let whale = CGMutablePath()
            whale.move(to: CGPoint(x: 5.0, y: 11.2))
            whale.addCurve(to: CGPoint(x: 14.6, y: 9.9), control1: CGPoint(x: 6.6, y: 8.9), control2: CGPoint(x: 10.8, y: 8.0))
            whale.addCurve(to: CGPoint(x: 18.0, y: 10.7), control1: CGPoint(x: 16.3, y: 10.8), control2: CGPoint(x: 17.1, y: 11.6))
            whale.addCurve(to: CGPoint(x: 20.8, y: 8.9), control1: CGPoint(x: 18.8, y: 9.9), control2: CGPoint(x: 19.7, y: 8.8))
            whale.addCurve(to: CGPoint(x: 18.6, y: 12.7), control1: CGPoint(x: 20.3, y: 10.7), control2: CGPoint(x: 19.6, y: 11.9))
            whale.addCurve(to: CGPoint(x: 20.6, y: 15.1), control1: CGPoint(x: 19.9, y: 13.2), control2: CGPoint(x: 20.7, y: 14.1))
            whale.addCurve(to: CGPoint(x: 17.4, y: 14.0), control1: CGPoint(x: 19.4, y: 15.4), control2: CGPoint(x: 18.3, y: 14.9))
            whale.addCurve(to: CGPoint(x: 7.6, y: 15.4), control1: CGPoint(x: 15.6, y: 16.2), control2: CGPoint(x: 10.6, y: 16.9))
            whale.addCurve(to: CGPoint(x: 5.0, y: 11.2), control1: CGPoint(x: 5.6, y: 14.4), control2: CGPoint(x: 4.3, y: 12.9))
            whale.closeSubpath()
            cg.addPath(whale)
            cg.fillPath()
            cg.setFillColor(badgeColor(for: .dsh))
            cg.fillEllipse(in: CGRect(x: 6.8, y: 10.9, width: 1.5, height: 1.5))
        case .omp:
            cg.setStrokeColor(white)
            cg.setLineWidth(2.0)
            cg.move(to: CGPoint(x: 6.9, y: 8.6))
            cg.addLine(to: CGPoint(x: 17.1, y: 8.6))
            cg.move(to: CGPoint(x: 10.1, y: 8.6))
            cg.addCurve(to: CGPoint(x: 8.4, y: 16.6), control1: CGPoint(x: 9.9, y: 11.4), control2: CGPoint(x: 9.3, y: 14.2))
            cg.move(to: CGPoint(x: 14.1, y: 8.6))
            cg.addLine(to: CGPoint(x: 14.1, y: 16.6))
            cg.strokePath()
        }
    }

    private static func polar(_ r: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: 12 + r * cos(angle), y: 12 + r * sin(angle))
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    }
}
