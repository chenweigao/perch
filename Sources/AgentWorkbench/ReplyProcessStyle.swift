import SwiftUI

extension ReplyStyle {
    /// Process rows: thoughts, tools, activity groups, progress notes, runtime
    /// context, compaction notes and the fold a settled turn collapses them into.
    /// Live rows and the fold share this geometry, so a running turn folds in
    /// place instead of moving sideways.
    enum Process {
        /// From a row's leading edge to its chevron (and from the header's last
        /// label to its trailing edge). Zero puts top-level chevrons on the reading
        /// column's leading edge, live and folded alike.
        static let leadingInset: CGFloat = 0
        /// The hover wash reaches this far before the chevron. Negative padding
        /// keeps the header in place; a top-level row clips it at the column edge.
        static let washOutset: CGFloat = 8
        /// Nested content (rows, tool details, thoughts, notes) starts under its
        /// header's label: the disclosure's 12 pt chevron column and its 8 pt gap.
        static let nestedIndent: CGFloat = 20
        /// Header labels, a step below the 14 pt body.
        static let labelSize: CGFloat = 12
        /// Between the rows of an expanded fold, and above its first row.
        static let rowSpacing: CGFloat = 12
        /// Thought text: one step below the body, upright, in secondary ink. Size
        /// and ink already set it apart; italic would slant only the Latin glyphs,
        /// because PingFang has no italic.
        static let thoughtSize: CGFloat = 13
        static let thoughtLineHeight: CGFloat = 20
        /// The streaming preview shows at most four thought lines.
        static let thoughtPreviewHeight: CGFloat = thoughtLineHeight * 4
    }
}

/// The disclosure every process row uses: `WorkbenchDisclosureStyle`'s full-width
/// header and content mechanics, at the `ReplyStyle.Process` inset.
struct ProcessDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchDisclosureStyle(horizontalPadding: ReplyStyle.Process.leadingInset,
                                 leadingWashOutset: ReplyStyle.Process.washOutset)
            .makeBody(configuration: configuration)
    }
}
