import SwiftUI

/// Shared row geometry; actions have reserved space so hover never moves the title.
struct SessionRowChrome<Indicator: View>: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    let starred: Bool
    let archived: Bool
    let canOpen: Bool
    let canQuickArchive: Bool
    let busy: Bool
    let onOpen: () -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    @ViewBuilder let indicator: Indicator
    @State private var hovered = false
    private enum Focus { case open, pin, archive }
    @FocusState private var focus: Focus?

    private var showActions: Bool { hovered || selected || archived || focus != nil }
    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 9) {
                    indicator.frame(width: 17, height: 16).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canOpen).focused($focus, equals: .open)
                .accessibilityLabel(title)
            HStack(spacing: 0) {
                if !archived {
                    Button(action: onPin) {
                        Image(systemName: starred ? "pin.slash" : "pin")
                            .frame(width: 24, height: 28).contentShape(Rectangle())
                    }.help(starred ? "取消置顶" : "置顶会话")
                        .accessibilityLabel(starred ? "取消置顶" : "置顶会话").disabled(busy)
                        .focused($focus, equals: .pin)
                }
                if canQuickArchive {
                    Button(action: onArchive) {
                        Image(systemName: archived ? "arrow.uturn.backward" : "archivebox")
                            .frame(width: 24, height: 28).contentShape(Rectangle())
                    }.help(archived ? "恢复会话" : "归档会话")
                        .accessibilityLabel(archived ? "恢复会话" : "归档会话").disabled(busy)
                        .focused($focus, equals: .archive)
                }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
                .opacity(showActions ? 1 : 0).allowsHitTesting(showActions).accessibilityHidden(!showActions)
        }.padding(.leading, 10).padding(.trailing, 5).frame(height: subtitle == nil ? 34 : 48)
            .background(selected ? .black.opacity(0.065) : hovered ? .black.opacity(0.03) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle()).onHover { hovered = $0 }
    }
}
