import SwiftUI

/// One geometry for every sidebar row. Navigation, section headers, projects and
/// sessions share the icon column, insets, height and highlight shape, so icons,
/// titles and selection backgrounds line up down the whole sidebar:
///
///     | inset | icon | gap | title …                      |
///     | inset | ▸ | icon | gap | project title           |   (project header)
///     | inset | indent | icon | gap | session title       |   (session in project)
///
/// A project's sessions start under the project's icon, so their titles align
/// with the project title. Section headers start at the icon column.
enum SidebarMetrics {
    /// Qoder rhythm: 32 pt rows 1 pt apart, navigation and sessions alike.
    static let rowHeight: CGFloat = 32
    static let navigationHeight: CGFloat = rowHeight
    static let navigationSize: CGFloat = WorkbenchTheme.Typography.body
    static let rowSpacing: CGFloat = 1
    /// The list's side padding inside the sidebar; the selection fill spans it.
    static let listInset: CGFloat = 4
    /// Session rows that carry a status line in diagnostic height-change checks.
    static let subtitleRowHeight: CGFloat = 44
    /// Compact vertical padding for single-line session rows.
    static let sessionVerticalPadding: CGFloat = 5
    /// Inside the shell's `listInset`.
    static let rowInset: CGFloat = 8
    static let iconWidth: CGFloat = 18
    static let iconSize: CGFloat = 14
    static let labelSpacing: CGFloat = 8
    static let titleSize: CGFloat = WorkbenchTheme.Typography.body
    static let detailSize: CGFloat = WorkbenchTheme.Typography.caption
    /// Keyboard shortcut hints after a row title (⌘K, ⌘,): one size everywhere.
    static let shortcutSize: CGFloat = WorkbenchTheme.Typography.caption
    static let cornerRadius: CGFloat = WorkbenchTheme.Radius.row
    /// Project disclosure chevron column and the gap after it.
    static let disclosureWidth: CGFloat = 12
    static let disclosureSpacing: CGFloat = 4
    /// Session rows inside a project start under the project's icon.
    static let childIndent: CGFloat = disclosureWidth + disclosureSpacing
    /// Leading offset of row titles, for secondary rows that carry no icon.
    static let titleOffset: CGFloat = rowInset + iconWidth + labelSpacing

    /// Section and date headers (最近会话, 今天, 昨天): regular weight, one step
    /// smaller than the rows and lighter than their titles, starting at the
    /// title column. Weight stays regular so the list reads as one calm column.
    static let sectionTitleSize: CGFloat = 13
    static let sectionTitleOpacity: Double = 0.40
    static let sectionHeaderHeight: CGFloat = 28
    /// Unselected session titles recede; the selected row returns to full ink.
    static let idleTitleOpacity: Double = 0.80
    /// Trailing actions of headers and project rows (+, filter, retry): one quiet
    /// glyph size and one hit target.
    static let actionSize: CGFloat = 24
    static let actionGlyphSize: CGFloat = 12
    /// A session row's status / actions slot sits this far inside the row's trailing edge.
    static let rowTrailingInset: CGFloat = 4
    static let sectionTopSpacing: CGFloat = 6
    static let sectionBottomSpacing: CGFloat = 1
    /// "显示全部", "更多会话" and the pin invitation: quieter than a session row.
    static let auxiliaryRowHeight: CGFloat = 28
    /// The first header sits closer to the navigation block than the later ones.
    static let pinnedHeaderTopSpacing: CGFloat = 2
    static let sectionHeight: CGFloat = sectionTopSpacing + sectionHeaderHeight + sectionBottomSpacing

    /// Compact status badge past the agent mark's bottom-trailing corner: symbol
    /// size, the unread dot, its offset, and the gap ring cut out of the mark so
    /// the badge reads on any brand color.
    static let badgeSize: CGFloat = 7
    static let badgeDotSize: CGFloat = 5
    static let badgeOffset = CGSize(width: 3, height: 2)
    static let badgeGap: CGFloat = 1.25

    /// Hover fades: row highlights and the actions they reveal.
    static let highlightDuration: Double = 0.1

    /// Strength of the row wash: the selection is a full wash, hover a fainter
    /// one. A press additionally shades the row.
    static func cardOpacity(selected: Bool, hovered: Bool, pressed: Bool = false) -> Double {
        selected ? 1 : hovered || pressed ? 0.5 : 0
    }
}

/// The highlight behind every sidebar row and header control: one shape and one
/// fade. Qoder-style, the selection is a flat neutral wash on the window glass
/// (no card, hairline or shadow); hover is the same wash at half strength.
struct SidebarHighlight: View {
    var selected = false
    var hovered = false
    var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius, style: .continuous)
        let wash = SidebarMetrics.cardOpacity(selected: selected, hovered: hovered, pressed: pressed)
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: SidebarMetrics.highlightDuration)
        shape.fill(WorkbenchTheme.Fill.selected.opacity(wash))
            .overlay(shape.fill(pressed ? WorkbenchTheme.Fill.hover : .clear))
            .animation(animation, value: wash)
            .animation(animation, value: pressed)
    }
}

/// A section header title in the shared style, with an optional count and, after
/// it, the disclosure chevron of a folding section or the up-down chevron of a
/// header that opens a menu, as on a pop-up button.
struct SidebarSectionTitle: View {
    let title: Text
    var count: Int? = nil
    var expanded: Bool? = nil
    /// Folding headers show their chevron only while it is useful; it keeps its
    /// width either way, so the title and count never shift.
    var showsDisclosure = true
    /// The header opens a menu instead of folding its section.
    var menu = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 4) {
            title.font(.system(size: SidebarMetrics.sectionTitleSize, weight: .regular))
                .foregroundStyle(Color.primary.opacity(SidebarMetrics.sectionTitleOpacity))
                .lineLimit(1)
            if let count, count > 0 {
                Text("\(count)").font(.system(size: SidebarMetrics.sectionTitleSize)).monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if let expanded {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    .opacity(showsDisclosure ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: SidebarMetrics.highlightDuration), value: showsDisclosure)
                    .accessibilityHidden(true)
            }
            if menu {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The glyph of a header or project-row action (+, filter, retry): quiet, one size,
/// one hit target, so no action looks more or less available than another.
struct SidebarActionGlyph: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: SidebarMetrics.actionGlyphSize, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: SidebarMetrics.actionSize, height: SidebarMetrics.actionSize).contentShape(Rectangle())
    }
}
