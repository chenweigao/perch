import SwiftUI

extension ReplyStyle {
    /// Conversation notices (an error, a lost connection, a stale sync) look the same
    /// for every agent: a label-size line with a symbol and at most one action, set in the
    /// reading column.
    enum Notice {
        static var textSize: CGFloat { ReplyStyle.labelSize }
        /// Between the symbol, the text and the action.
        static let spacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 8
        static let cornerRadius: CGFloat = 8
        static let fillOpacity: Double = 0.06
        /// Long upstream errors scroll past this height instead of displacing the conversation.
        static let maxTextHeight: CGFloat = 128
        /// The transcript column's horizontal inset (`ConversationScrollView`), which the
        /// activity bar and the composer also use, so a notice lines up with all three.
        static let columnInset: CGFloat = 36
        /// Above and below a notice.
        static let margin: CGFloat = 8
    }
}

/// One notice in a conversation: a symbol, localized text and an optional action
/// (重新连接, Retry). Native agents and Kimi both use it, so the two families report
/// problems the same way, in the reading column. It sets that column itself: place
/// it in the pane, not inside the transcript's scroll view.
struct ConversationNotice: View {
    struct Action {
        /// Already localized.
        let title: String
        var isDisabled = false
        let perform: () -> Void
    }
    /// Already localized; upstream errors are shown verbatim.
    let text: String
    var symbol = "exclamationmark.circle"
    var tint: Color = .orange
    var action: Action? = nil

    var body: some View {
        HStack(spacing: ReplyStyle.Notice.spacing) {
            NoticeTextFrame(maxHeight: ReplyStyle.Notice.maxTextHeight) {
                // Short text sizes the notice; only text past the cap scrolls.
                ViewThatFits(in: .vertical) {
                    message
                    ScrollView { message }
                }
            }
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.bordered).controlSize(.small).tint(tint)
                    .disabled(action.isDisabled)
            }
        }
        .font(.system(size: ReplyStyle.Notice.textSize))
        .foregroundStyle(tint)
        .padding(.horizontal, ReplyStyle.Notice.horizontalPadding)
        .padding(.vertical, ReplyStyle.Notice.verticalPadding)
        .background(tint.opacity(ReplyStyle.Notice.fillOpacity),
                    in: RoundedRectangle(cornerRadius: ReplyStyle.Notice.cornerRadius))
        .frame(maxWidth: ReplyStyle.readingWidth)
        .padding(.horizontal, ReplyStyle.Notice.columnInset)
        .frame(maxWidth: .infinity)
        .padding(.vertical, ReplyStyle.Notice.margin)
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: ReplyStyle.Notice.spacing) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(verbatim: text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Offers its content at most `maxHeight` and keeps the content's own size.
/// `.frame(maxHeight:)` would instead stretch a one-line notice to the cap.
private struct NoticeTextFrame: Layout {
    let maxHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: proposal.width,
                                                     height: min(proposal.height ?? maxHeight, maxHeight)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
