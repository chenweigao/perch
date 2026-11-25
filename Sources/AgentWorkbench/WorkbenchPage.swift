import SwiftUI

/// The shared frame of non-conversation pages (workbench, inbox, all sessions,
/// archive): one title scale, one column width, one set of margins. See
/// docs/design/layout.md「页面模板」. The conversation reader keeps its own
/// reading column instead.
enum WorkbenchPageLayout {
    static let maxWidth: CGFloat = 944
    static let horizontalPadding: CGFloat = 32
    static let topPadding: CGFloat = 28
    static let bottomPadding: CGFloat = 32
    static let headerSpacing: CGFloat = 6
}

extension View {
    /// The page column: at most `WorkbenchPageLayout.maxWidth`, centered.
    func workbenchPageColumn(alignment: Alignment = .center) -> some View {
        frame(maxWidth: WorkbenchPageLayout.maxWidth, alignment: alignment).frame(maxWidth: .infinity)
    }

    /// The page title scale, shared by every page header.
    func workbenchPageTitle() -> some View {
        font(.system(size: WorkbenchTheme.Typography.Display.page, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// Title, one secondary line, and at most one trailing action for the page.
struct WorkbenchPageHeader<Trailing: View>: View {
    let title: Text
    var subtitle: Text?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: Text, subtitle: Text? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: WorkbenchPageLayout.headerSpacing) {
                title.workbenchPageTitle()
                if let subtitle {
                    subtitle.font(.system(size: WorkbenchTheme.Typography.label)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
    }
}

extension WorkbenchPageHeader where Trailing == EmptyView {
    init(_ title: Text, subtitle: Text? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}
