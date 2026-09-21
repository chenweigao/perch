import SwiftUI

extension View {
    /// Native glass is confined to navigation and floating controls, never transcript text.
    func workbenchFloatingSurface() -> some View {
        modifier(WorkbenchGlassSurface(cornerRadius: 16))
    }

    func workbenchControlSurface() -> some View {
        modifier(WorkbenchGlassSurface(cornerRadius: 20))
    }
}

private struct WorkbenchGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
