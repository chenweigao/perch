import SwiftUI

/// The approved woodcut terrain, tinted with the current appearance's ink.
struct PerchMark: View {
    #if SWIFT_PACKAGE
    // The installed app keeps SwiftPM bundles in Contents/Resources. SwiftPM's
    // generated accessor instead searches the app root, then the build tree.
    // Keep its accessor for `swift run`, whose resources live beside the binary.
    private let bundle = Bundle.main.url(forResource: "AgentWorkbench_AgentWorkbench", withExtension: "bundle")
        .flatMap { Bundle(url: $0) } ?? Bundle.module
    #else
    private let bundle = Bundle.main
    #endif

    var body: some View {
        Image("Perch-mark", bundle: bundle)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(WorkbenchTheme.ink)
            .accessibilityLabel("Perch")
    }
}
