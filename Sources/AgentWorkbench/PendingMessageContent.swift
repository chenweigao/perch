import SwiftUI
import WorkbenchCore

extension UserMessageStyle {
    /// A message still sending, queued or steering. It is drawn as the sent
    /// prompt's bubble, so the echo takes its place without moving the text.
    enum Pending {
        /// Its state and controls under the bubble, in secondary ink.
        static let detailSize: CGFloat = 11
        /// Between the bubble and that line, as the fold toggle under a long prompt.
        static let detailSpacing: CGFloat = 6
        /// Between the items of that line.
        static let detailItemSpacing: CGFloat = 8
        /// Below that line, before the next row.
        static let bottomSpacing: CGFloat = 8
    }
}

/// Pending text stays in the transcript at full length until the runtime echoes it.
/// It reads as the sent prompt: the same right-aligned bubble, text, padding and
/// fill, so the echo replaces it in place. Its state and the caller's controls
/// share one line under it.
struct PendingMessageContent<Controls: View>: View {
    @UILocalization private var L
    let text: String
    /// A localization key or already localized text; both display through lookup.
    let status: String
    /// A localization key ("Steer", "Queue").
    var mode: String? = nil
    /// Actions on this message, set in the line's type; buttons are borderless.
    @ViewBuilder let controls: Controls
    var body: some View {
        VStack(alignment: .trailing, spacing: UserMessageStyle.Pending.detailSpacing) {
            // An attachment-only send has no text to set.
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PendingBubbleLayout {
                    // Set as `KimiMessageView` sets a sent prompt; plain prompts also
                    // measure the same in the settled native row.
                    KimiMarkdown(text: text)
                        .environment(\.replyLineHeight, UserMessageStyle.lineHeight)
                        .padding(.horizontal, UserMessageStyle.horizontalPadding)
                        .padding(.vertical, UserMessageStyle.verticalPadding)
                        // The sent bubble's fill, without a stroke.
                        .background(ReplyStyle.paper, in: RoundedRectangle(cornerRadius: UserMessageStyle.cornerRadius))
                }
            }
            HStack(spacing: UserMessageStyle.Pending.detailItemSpacing) {
                if let mode { Text(L(key: mode)) }
                Text(L(key: status)).textSelection(.enabled)
                controls
            }
            .font(.system(size: UserMessageStyle.Pending.detailSize))
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // A sent prompt's row starts its bubble `topSpacing` down; so does this one.
        .padding(.top, UserMessageStyle.topSpacing)
        .padding(.bottom, UserMessageStyle.Pending.bottomSpacing)
    }
}

/// Places the bubble as `UserMessageLayout` places a sent prompt: its ideal width
/// up to `UserMessageStyle.maxWidthRatio` of the column, against the trailing edge.
private struct PendingBubbleLayout: Layout {
    private func measure(width: CGFloat, subview: LayoutSubview) -> CGSize {
        let idealWidth = subview.sizeThatFits(.unspecified).width
        return subview.sizeThatFits(ProposedViewSize(width: min(idealWidth, width * UserMessageStyle.maxWidthRatio), height: nil))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        let width = max(1, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ReplyStyle.readingWidth)
        return CGSize(width: width, height: measure(width: width, subview: bubble).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        bubble.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                     proposal: ProposedViewSize(measure(width: bounds.width, subview: bubble)))
    }
}

/// Editing a not-yet-accepted queue entry; save failure keeps the typed revision.
struct PendingMessageEditor: View {
    @UILocalization private var L
    let message: OutboundMessage
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var messageError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑待发消息").font(.headline)
            TextEditor(text: $text).frame(minHeight: 140)
            if let messageError { Text(messageError).font(.subheadline).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if save(text) { dismiss() }
                    else { messageError = L("消息已经提交，修改未保存。可复制这里的文字作为新的补充。") }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(WorkbenchTheme.Dialog.padding).frame(width: 460).onAppear { text = message.text }
    }
}
