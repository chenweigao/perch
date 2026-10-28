import SwiftUI
import AppKit

/// The Perch brand mark (a sunset orb perched on a branch) for in-app surfaces:
/// home empty states and About-style moments. Geometry matches
/// `scripts/generate-brand.swift`, cropped to the content bounds (432×328);
/// the branch takes the current `ink` so the mark adapts to appearance.
/// No tile — the app icon carries it.
struct PerchMark: View {
    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                // Content bbox in icon space: x 296...728, y 354...682.
                let u = size.width / 432
                cg.scaleBy(x: u, y: u)
                cg.translateBy(x: -296, y: -354)

                let branchRect = CGRect(x: 296, y: 640 - 42, width: 432, height: 84)
                cg.addPath(CGPath(roundedRect: branchRect, cornerWidth: 42, cornerHeight: 42, transform: nil))
                cg.setFillColor(WorkbenchTheme.inkNS.cgColor)
                cg.fillPath()

                let orbRect = CGRect(x: 430 - 122, y: 476 - 122, width: 244, height: 244)
                cg.saveGState()
                cg.addPath(CGPath(ellipseIn: orbRect, transform: nil))
                cg.clip()
                let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          colors: [WorkbenchTheme.Brand.orbTop.cgColor,
                                                   WorkbenchTheme.Brand.orbBottom.cgColor] as CFArray,
                                          locations: [0, 1])!
                cg.drawLinearGradient(gradient,
                                      start: CGPoint(x: orbRect.midX, y: orbRect.minY),
                                      end: CGPoint(x: orbRect.midX, y: orbRect.maxY),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                cg.restoreGState()
            }
        }
        .aspectRatio(432 / 328, contentMode: .fit)
        .accessibilityLabel("Perch")
    }
}
