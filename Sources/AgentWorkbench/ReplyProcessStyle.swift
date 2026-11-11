import SwiftUI
import WorkbenchCore

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
        /// Header labels: the same size as prose; color and grouping convey their role.
        static var labelSize: CGFloat { ReplyStyle.labelSize }
        /// Between the rows of an expanded fold, and above its first row.
        static let rowSpacing: CGFloat = 12
        /// Thought text: the same reading size and line height as the reply,
        /// upright, in secondary ink. Secondary ink and disclosure grouping set it apart; italic
        /// would slant only the Latin glyphs, because PingFang has no italic.
        static var thoughtSize: CGFloat { ReplyStyle.secondarySize }
        static var thoughtLineHeight: CGFloat { ReplyStyle.scale.secondaryLine }
        /// Leading rail under a thought disclosure's chevron.
        static let thoughtRailWidth: CGFloat = 2
        static let thoughtRailLeading: CGFloat = 5
    }
}

/// A tool's compact outcome stays visible beside its label: tuned warm amber
/// with a gentle soft halo while running, and calm emerald once completed.
struct ProcessStatusDot: View {
    let status: VisibleTool.Status
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.conversationReduceMotion) private var conversationReduceMotion
    private var active: Bool { status == .running }
    private var color: Color {
        switch status {
        case .running, .awaitingApproval: return Color(nsColor: WorkbenchTheme.statusRunningNS)
        case .succeeded, .returned: return Color(nsColor: WorkbenchTheme.statusSuccessNS)
        case .failed: return Color(nsColor: .systemRed)
        case .missingResult, .disconnected: return WorkbenchTheme.quiet
        }
    }
    var body: some View {
        let canAnimate = active && !(systemReduceMotion || conversationReduceMotion)
        Circle().fill(color).frame(width: 6, height: 6)
            .opacity(active && pulsing ? 0.62 : 1)
            .overlay {
                if active {
                    Circle().fill(color.opacity(pulsing ? 0.22 : 0.10))
                        .frame(width: 11, height: 11)
                }
            }
            .animation(canAnimate ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

/// PI's activity-marker geometry, using the tuned warm amber live color.
struct ProcessLivePulse: View {
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(Color(nsColor: WorkbenchTheme.statusRunningNS)).frame(width: 4, height: 4)
            .opacity(pulsing ? 1 : 0.35)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                       value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

/// The disclosure every process row uses: `WorkbenchDisclosureStyle`'s full-width
/// header and content mechanics, at the `ReplyStyle.Process` inset.
struct ProcessDisclosureStyle: DisclosureGroupStyle {
    /// The turn fold's header closes its status cluster with the caret (PI's
    /// turn-process header); leaf rows keep the caret on the trailing edge.
    var caretFollowsContent = false
    func makeBody(configuration: Configuration) -> some View {
        // Process rows carry the caret on the trailing edge (PI/DSH form).
        WorkbenchDisclosureStyle(horizontalPadding: ReplyStyle.Process.leadingInset,
                                 leadingWashOutset: ReplyStyle.Process.washOutset,
                                 trailingChevron: true, caretFollowsContent: caretFollowsContent)
            .makeBody(configuration: configuration)
    }
}
