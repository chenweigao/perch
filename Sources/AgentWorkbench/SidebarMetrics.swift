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
    static let rowHeight: CGFloat = 36
    /// Session rows that carry a status line (offline, waiting for input).
    static let subtitleRowHeight: CGFloat = 50
    /// Conversation titles may occupy two lines without being squeezed by actions.
    static let sessionMinimumHeight: CGFloat = 44
    /// Inside the shell's 10 pt list padding.
    static let rowInset: CGFloat = 8
    static let iconWidth: CGFloat = 18
    static let iconSize: CGFloat = 14
    static let labelSpacing: CGFloat = 10
    static let titleSize: CGFloat = 14
    static let detailSize: CGFloat = 11
    /// Keyboard shortcut hints after a row title (⌘K, ⌘,): one size everywhere.
    static let shortcutSize: CGFloat = 11
    static let cornerRadius: CGFloat = WorkbenchTheme.Radius.row
    /// Project disclosure chevron column and the gap after it.
    static let disclosureWidth: CGFloat = 12
    static let disclosureSpacing: CGFloat = 4
    /// Session rows inside a project start under the project's icon.
    static let childIndent: CGFloat = disclosureWidth + disclosureSpacing
    /// Leading offset of row titles, for secondary rows that carry no icon.
    static let titleOffset: CGFloat = rowInset + iconWidth + labelSpacing

    /// Section headers: small semibold labels starting at the icon column. Darker
    /// than secondary text, so headers such as 置顶 never read as disabled.
    static let sectionTitleSize: CGFloat = 12
    static let sectionTitleOpacity: Double = 0.62
    static let sectionHeaderHeight: CGFloat = 24
    static let sectionTopSpacing: CGFloat = 18
    static let sectionBottomSpacing: CGFloat = 2
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

    /// Strength of the row card: the selection is a full card, hover or a press
    /// a fainter one. A press additionally shades the row.
    static func cardOpacity(selected: Bool, hovered: Bool, pressed: Bool = false) -> Double {
        selected ? 1 : hovered || pressed ? 0.5 : 0
    }
}

/// The highlight behind every sidebar row and header control: one shape and one
/// fade. On the window glass a gray wash reads as dirt, so the selection is a
/// small light card with a hairline, like the conversation sheet beside it.
struct SidebarHighlight: View {
    var selected = false
    var hovered = false
    var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius, style: .continuous)
        let card = SidebarMetrics.cardOpacity(selected: selected, hovered: hovered, pressed: pressed)
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: SidebarMetrics.highlightDuration)
        shape.fill(WorkbenchTheme.rowCard.opacity(card))
            .overlay(shape.strokeBorder(Color.primary.opacity(selected ? WorkbenchTheme.Stroke.hairline : 0), lineWidth: 1))
            .overlay(shape.fill(Color.primary.opacity(pressed ? WorkbenchTheme.Fill.hover : 0)))
            .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 1.5, y: 0.5)
            .animation(animation, value: card)
            .animation(animation, value: pressed)
    }
}

/// A section header title in the shared style, with an optional count and, after
/// it, the disclosure chevron of a folding section or the ellipsis of a header
/// that opens a menu.
struct SidebarSectionTitle: View {
    let title: Text
    var count: Int? = nil
    var expanded: Bool? = nil
    /// The header opens a menu instead of folding its section.
    var menu = false
    var body: some View {
        HStack(spacing: 4) {
            title.font(.system(size: SidebarMetrics.sectionTitleSize, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(SidebarMetrics.sectionTitleOpacity))
                .lineLimit(1)
            if let count, count > 0 {
                Text("\(count)").font(.system(size: SidebarMetrics.sectionTitleSize)).monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if let expanded {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            if menu {
                Image(systemName: "ellipsis")
                    .font(.system(size: SidebarMetrics.sectionTitleSize, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}
