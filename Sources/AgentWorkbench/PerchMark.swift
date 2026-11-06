import SwiftUI

/// The approved woodcut terrain, tinted with the current appearance's ink.
struct PerchMark: View {
    #if SWIFT_PACKAGE
    private let bundle = Bundle.module
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
