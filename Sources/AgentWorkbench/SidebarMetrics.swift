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
    static let rowHeight: CGFloat = 32
    /// Session rows that carry a status line (offline, waiting for input).
    static let subtitleRowHeight: CGFloat = 44
    /// Inside the shell's 10 pt list padding.
    static let rowInset: CGFloat = 8
    static let iconWidth: CGFloat = 16
    static let iconSize: CGFloat = 13
    static let labelSpacing: CGFloat = 8
    static let titleSize: CGFloat = 13
    static let detailSize: CGFloat = 11
    static let cornerRadius: CGFloat = 7
    /// Project disclosure chevron column and the gap after it.
    static let disclosureWidth: CGFloat = 12
    static let disclosureSpacing: CGFloat = 4
    /// Session rows inside a project start under the project's icon.
    static let childIndent: CGFloat = disclosureWidth + disclosureSpacing
    /// Leading offset of row titles, for secondary rows that carry no icon.
    static let titleOffset: CGFloat = rowInset + iconWidth + labelSpacing

    /// Section headers: small semibold labels starting at the icon column. Darker
    /// than secondary text, so headers such as 置顶 never read as disabled.
    static let sectionTitleSize: CGFloat = 11
    static let sectionTitleOpacity: Double = 0.62
    static let sectionHeaderHeight: CGFloat = 24
    static let sectionTopSpacing: CGFloat = 14
    static let sectionBottomSpacing: CGFloat = 2
    static let sectionHeight: CGFloat = sectionTopSpacing + sectionHeaderHeight + sectionBottomSpacing

    /// Row highlight strength: pressed > selected > hovered.
    static func fill(selected: Bool, hovered: Bool, pressed: Bool = false) -> Double {
        pressed ? 0.11 : selected ? 0.08 : hovered ? 0.045 : 0
    }
}

/// A section header title in the shared style, with an optional count and the
/// disclosure chevron after it.
struct SidebarSectionTitle: View {
    let title: Text
    var count: Int? = nil
    var expanded: Bool? = nil
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
        }
    }
}
