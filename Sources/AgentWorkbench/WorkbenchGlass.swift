import SwiftUI

extension View {
    /// Native glass is confined to navigation and floating controls, never transcript text.
    func workbenchFloatingSurface() -> some View {
        modifier(WorkbenchGlassSurface(cornerRadius: WorkbenchTheme.Radius.panel))
    }

    func workbenchControlSurface() -> some View {
        modifier(WorkbenchGlassSurface(cornerRadius: WorkbenchTheme.Radius.panel))
    }

    func workbenchComposerSurface() -> some View {
        modifier(WorkbenchGlassSurface(cornerRadius: WorkbenchTheme.Radius.composer, outlined: true))
    }
}

private struct WorkbenchGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    /// The composer keeps its glass but gains an edge and a soft shadow: on the
    /// white sheet bare glass has no boundary, and the input should read as the
    /// page's one solid block (Qoder).
    var outlined = false

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                content.background(Color(nsColor: .controlBackgroundColor), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        }
        .overlay { if outlined { shape.strokeBorder(WorkbenchTheme.Stroke.hairline, lineWidth: 1).allowsHitTesting(false) } }
        .background {
            if outlined {
                shape.fill(WorkbenchTheme.contentBackground)
                    .shadow(color: WorkbenchTheme.Elevation.composerShadow, radius: 10, y: 3)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Keep the disclosure's binding and semantics while making its full header clickable.
struct WorkbenchDisclosureStyle: DisclosureGroupStyle {
    var minHeight: CGFloat = 28
    var horizontalPadding: CGFloat = 8
    /// Extends the hover wash past the header's leading edge without moving the
    /// header: padding inside the wash, the same negative padding outside it.
    var leadingWashOutset: CGFloat = 0
    /// PI/DSH process rows carry the caret on the trailing edge, after the status.
    var trailingChevron = false
    /// PI's turn-process header: the caret closes the status cluster itself,
    /// following the last label instead of either edge.
    var caretFollowsContent = false
    /// Qoder's process rows: the caret leads in a small outlined square, then the
    /// label. Takes precedence over the other caret placements.
    var boxedChevron = false

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    if boxedChevron {
                        WorkbenchDisclosureBox(expanded: configuration.isExpanded)
                    } else if !trailingChevron && !caretFollowsContent {
                        Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 12).accessibilityHidden(true)
                    }
                    configuration.label
                    if caretFollowsContent && !boxedChevron {
                        Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                    if trailingChevron && !caretFollowsContent && !boxedChevron {
                        Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }.padding(.horizontal, horizontalPadding)
                    .padding(.leading, leadingWashOutset)
                    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(WorkbenchDisclosureButtonStyle())
                .padding(.leading, -leadingWashOutset)
                .accessibilityValue(configuration.isExpanded ? Text("已展开") : Text("已收起"))
            WorkbenchDisclosureContent(expanded: configuration.isExpanded) { configuration.content }
        }
    }
}

/// The leading caret of a process row: a 20 pt outlined square whose chevron
/// turns down while the row is open. Its trailing gap brings the label to
/// `ReplyStyle.Process.nestedIndent`, where nested rows start.
struct WorkbenchDisclosureBox: View {
    let expanded: Bool
    static let size: CGFloat = 20
    /// With the row's 8 pt spacing, the label starts 30 pt in.
    static let trailingGap: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip, style: .continuous)
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
            .frame(width: Self.size, height: Self.size)
            .background(WorkbenchTheme.contentBackground, in: shape)
            .overlay(shape.strokeBorder(WorkbenchTheme.Stroke.hairline, lineWidth: 1))
            .padding(.trailing, Self.trailingGap)
            .accessibilityHidden(true)
    }
}

/// Disclosure content that opens and closes with a height transition, pushing
/// siblings instead of flashing in (ccgui ui-ux-spec §2.4). Content stays
/// mounted while the close animation runs and unmounts only after it ends;
/// rows that remember an expanded state re-appear fully open without
/// replaying the animation. Reduce Motion bypasses the transition entirely.
struct WorkbenchDisclosureContent<Content: View>: View {
    let expanded: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.conversationReduceMotion) private var conversationReduceMotion
    /// A reference box, not observable state: streaming growth re-measures on
    /// every layout pass, but the height is only read at toggle boundaries.
    private final class NaturalHeight { var value: CGFloat = 0 }
    @State private var naturalHeight = NaturalHeight()
    @State private var mounted: Bool
    /// Non-nil while animating: the clipped height growing 0→natural or
    /// shrinking natural→0. Nil means the content flows at its natural height.
    @State private var clippedHeight: CGFloat?
    @State private var animationRevision = 0

    init(expanded: Bool, @ViewBuilder content: () -> Content) {
        self.expanded = expanded
        self.content = content()
        _mounted = State(initialValue: expanded)
    }

    private var reduceMotion: Bool { accessibilityReduceMotion || conversationReduceMotion }

    var body: some View {
        Group {
            if mounted {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight.value = $0 }
                    .frame(height: clippedHeight, alignment: .top)
                    .clipped()
            }
        }
        .onChange(of: expanded) { _, now in
                animationRevision += 1
                let revision = animationRevision
                guard !reduceMotion else { mounted = now; clippedHeight = nil; return }
                if now {
                    // Mount at zero height, then grow once the first layout pass
                    // has measured the content.
                    mounted = true
                    clippedHeight = 0
                    DispatchQueue.main.async {
                        guard revision == animationRevision else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            clippedHeight = naturalHeight.value
                        } completion: {
                            if revision == animationRevision { clippedHeight = nil }
                        }
                    }
                } else {
                    clippedHeight = naturalHeight.value
                    withAnimation(.easeInOut(duration: 0.25)) {
                        clippedHeight = 0
                    } completion: {
                        if revision == animationRevision {
                            mounted = false
                            clippedHeight = nil
                        }
                    }
                }
            }
        .onDisappear { animationRevision += 1 }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                animationRevision += 1
                mounted = expanded
                clippedHeight = nil
            }
        }
    }
}
struct WorkbenchDisclosureButtonStyle: ButtonStyle {
    /// The keyboard highlight of a list built from these buttons. A press
    /// outranks it, and it outranks hover, so one row never shows two fills.
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        DisclosureButtonBody(configuration: configuration, selected: selected)
    }

    private struct DisclosureButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(wash, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row, style: .continuous))
                .onHover { hovered = $0 }
        }
        private var wash: Color {
            configuration.isPressed ? WorkbenchTheme.Fill.pressed
                : selected ? WorkbenchTheme.Fill.selected
                : hovered ? WorkbenchTheme.Fill.hover : .clear
        }
    }
}

/// Inline links stay in the quiet palette; only hover asks for attention.
struct QuietLinkStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovered || configuration.isPressed ? Color.primary : Color.secondary)
            .underline(hovered)
            .onHover { hovered = $0 }
    }
}
