import SwiftUI
import AppKit

/// A monochrome, untiled Perch bird for in-app brand moments.
struct PerchMark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let bounds = PerchBirdGeometry.contentBounds
        let dark = colorScheme == .dark
        Canvas { context, size in
            context.withCGContext { cg in
                let u = size.width / bounds.width
                cg.scaleBy(x: u, y: u)
                cg.translateBy(x: -bounds.minX, y: -bounds.minY)
                var ink = WorkbenchTheme.inkNS.cgColor
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    ink = WorkbenchTheme.inkNS.cgColor
                }
                PerchBirdGeometry.draw(in: cg, ink: ink, pixels: 100)
            }
        }
        .aspectRatio(bounds.width / bounds.height, contentMode: .fit)
        .accessibilityLabel("Perch")
    }
}
