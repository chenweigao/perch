import SwiftUI
import WorkbenchCore

/// Hidden actions give their width back to the title; visible actions use one slot each.
struct SessionRowChrome<Indicator: View>: View {
    @UILocalization private var L
    let title: String
    let subtitle: String?
    var hostName: String? = nil
    var hostID: UUID? = nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Focus { case open, pin, archive }
    @FocusState private var focus: Focus?

    private var showActions: Bool { hovered || selected || archived || focus != nil }
    private var actionWidth: CGFloat { showActions ? CGFloat((archived ? 0 : 1) + (canQuickArchive ? 1 : 0)) * 24 : 0 }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 9) {
                    indicator.frame(width: 17, height: 16).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, 10).padding(.trailing, 4)
                    .frame(height: subtitle == nil ? 34 : 48).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canOpen).focused($focus, equals: .open)
                .accessibilityLabel(title)
                .accessibilityValue(hostName ?? "")
            HStack(spacing: 0) {
                if !archived {
                    Button(action: onPin) {
                        Image(systemName: starred ? "pin.slash" : "pin")
                            .frame(width: 24, height: 28).contentShape(Rectangle())
                    }.help(starred ? L("取消置顶") : L("置顶会话"))
                        .accessibilityLabel(starred ? L("取消置顶") : L("置顶会话")).disabled(busy)
                        .focused($focus, equals: .pin)
                }
                if canQuickArchive {
                    Button(action: onArchive) {
                        Image(systemName: archived ? "arrow.uturn.backward" : "archivebox")
                            .frame(width: 24, height: 28).contentShape(Rectangle())
                    }.help(archived ? L("恢复会话") : L("归档会话"))
                        .accessibilityLabel(archived ? L("恢复会话") : L("归档会话")).disabled(busy)
                        .focused($focus, equals: .archive)
                }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: actionWidth, alignment: .trailing).clipped()
                .opacity(showActions ? 1 : 0).allowsHitTesting(showActions).accessibilityHidden(!showActions)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: showActions)
            if let hostName {
                HostIdentityIcon(hostID: hostID)
                    .font(.system(size: 12))
                    .frame(width: 18).padding(.leading, 7).padding(.trailing, 3)
                    .help(hostName).accessibilityHidden(true)
            }
        }.padding(.trailing, 5).frame(height: subtitle == nil ? 34 : 48)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(selected ? 0.065 : hovered ? 0.03 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
            }
            .contentShape(Rectangle()).onHover { hovered = $0 }
    }

}
