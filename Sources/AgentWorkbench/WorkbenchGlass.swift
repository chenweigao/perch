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

/// Keep the disclosure's binding and semantics while making its full header clickable.
struct WorkbenchDisclosureStyle: DisclosureGroupStyle {
    var minHeight: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 12).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(WorkbenchDisclosureButtonStyle())
                .accessibilityValue(configuration.isExpanded ? Text("已展开") : Text("已收起"))
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct WorkbenchDisclosureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureButtonBody(configuration: configuration)
    }

    private struct DisclosureButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.05 : hovered ? 0.025 : 0),
                            in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}
