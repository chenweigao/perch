import SwiftUI
import AppKit

/// The Perch brand mark (a sun ring floating over a branch, both lines) for
/// in-app brand moments such as the fresh-workspace home. Geometry is
/// `PerchLineMark`, cropped to its ink; the branch takes the current `ink` and the
/// sun the one brand hue, so the mark adapts to appearance. No tile — the app icon
/// carries it.
struct PerchMark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let bounds = PerchLineMark.contentBounds
        // Read here so the Canvas redraws with the appearance.
        let dark = colorScheme == .dark
        Canvas { context, size in
            context.withCGContext { cg in
                let u = size.width / bounds.width
                cg.scaleBy(x: u, y: u)
                cg.translateBy(x: -bounds.minX, y: -bounds.minY)
                var branch = WorkbenchTheme.inkNS.cgColor
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    branch = WorkbenchTheme.inkNS.cgColor
                }
                PerchLineMark.draw(in: cg, branch: branch, sun: WorkbenchTheme.Brand.sun.cgColor)
            }
        }
        .aspectRatio(bounds.width / bounds.height, contentMode: .fit)
        .accessibilityLabel("Perch")
    }
}
