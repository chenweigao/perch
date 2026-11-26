import AppKit
import SwiftUI

/// The approved woodcut terrain. Brand moments use the identity's umber/paper
/// ink; the menu-bar extra passes the neutral interface ink.
struct PerchMark: View {
    var tint: Color = WorkbenchTheme.brandInk

    /// The mark ships as a loose PNG, not in an asset catalog, and SwiftUI's
    /// `Image(_:bundle:)` only resolves catalog names: it drew nothing. Load the
    /// file through the bundle once and template it.
    private static let image: NSImage? = {
        #if SWIFT_PACKAGE
        // The installed app keeps SwiftPM bundles in Contents/Resources. SwiftPM's
        // generated accessor instead searches the app root, then the build tree.
        // Keep its accessor for `swift run`, whose resources live beside the binary.
        let bundle = Bundle.main.url(forResource: "AgentWorkbench_AgentWorkbench", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return bundle.image(forResource: "Perch-mark")
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint)
            } else {
                Color.clear
            }
        }
        .accessibilityLabel("Perch")
    }
}
