import CoreGraphics

/// Approved D1 bird, on a 100-unit grid (y down). Kept in step with
/// scripts/generate-brand.swift. A centered branch and near-symmetric body;
/// the short beak and lighter wing provide the directional detail.
enum PerchBirdGeometry {
    static let contentBounds = CGRect(x: 20.3, y: 21.3, width: 59.4, height: 60.4)
    static var body: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 66, y: 36))
        p.addCurve(to: CGPoint(x: 47, y: 24), control1: CGPoint(x: 62, y: 27), control2: CGPoint(x: 56, y: 24))
        p.addCurve(to: CGPoint(x: 27, y: 44), control1: CGPoint(x: 35, y: 24), control2: CGPoint(x: 27, y: 33))
        p.addCurve(to: CGPoint(x: 47, y: 64), control1: CGPoint(x: 27, y: 56), control2: CGPoint(x: 35, y: 64))
        p.addCurve(to: CGPoint(x: 67, y: 49), control1: CGPoint(x: 58, y: 64), control2: CGPoint(x: 65, y: 57))
        p.addLine(to: CGPoint(x: 75, y: 44))
        p.addLine(to: CGPoint(x: 67, y: 40))
        p.addCurve(to: CGPoint(x: 66, y: 36), control1: CGPoint(x: 67, y: 38), control2: CGPoint(x: 66.5, y: 37))
        p.closeSubpath()
        return p
    }
    static var wing: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 37, y: 43))
        p.addCurve(to: CGPoint(x: 54, y: 46), control1: CGPoint(x: 39, y: 52), control2: CGPoint(x: 47, y: 54))
        return p
    }
    static var branch: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 23, y: 79))
        p.addLine(to: CGPoint(x: 77, y: 79))
        p.move(to: CGPoint(x: 47, y: 64))
        p.addLine(to: CGPoint(x: 47, y: 79))
        return p
    }

    static func draw(in cg: CGContext, ink: CGColor, pixels: CGFloat) {
        let small = pixels <= 16
        let medium = pixels <= 24
        let scale: CGFloat = small ? 1.08 : medium ? 1.04 : 1
        cg.saveGState()
        cg.translateBy(x: 50, y: 50)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -50, y: -50)
        cg.setStrokeColor(ink)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineWidth(small ? 6.2 : medium ? 5.8 : 5.4)
        cg.addPath(body)
        cg.addPath(branch)
        cg.strokePath()
        cg.setLineWidth(small ? 5.6 : medium ? 5.4 : 5.2)
        cg.addPath(wing)
        cg.strokePath()
        cg.restoreGState()
    }
}
