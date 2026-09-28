import SwiftUI
import WorkbenchCore

/// Host identity and hover actions share the trailing space.
struct SessionRowChrome<Indicator: View>: View {
    @UILocalization private var L
    let title: String
    let subtitle: String?
    var hostName: String? = nil
    var hostID: UUID? = nil
    var directory: String? = nil
    var detail: String? = nil
    var groups: [String] = []
    var updatedAt: Double = 0
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
    @State private var titleHovered = false
    @State private var showPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Focus { case open, pin, archive }
    @FocusState private var focus: Focus?

    private var showActions: Bool { hovered || focus != nil }
    private var actionWidth: CGFloat { showActions ? CGFloat((archived ? 0 : 1) + (canQuickArchive ? 1 : 0)) * 28 : 0 }
    private var trailingWidth: CGFloat { max(actionWidth, hostName == nil ? 0 : 28) }
    var body: some View {
        HStack(spacing: 0) {
            Button {
                showPreview = false
                onOpen()
            } label: {
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
                .accessibilityValue(([hostName, directory, detail].compactMap { $0 } + groups).joined(separator: " · "))
                .onHover { titleHovered = $0 }
            ZStack(alignment: .trailing) {
                if hostName != nil {
                    HostIdentityIcon(hostID: hostID)
                        .font(.system(size: 12)).frame(width: 28)
                        .opacity(showActions && actionWidth > 0 ? 0 : 1)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 0) {
                    if !archived {
                        Button(action: onPin) {
                            Image(systemName: starred ? "pin.slash" : "pin")
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }.help(starred ? L("取消置顶") : L("置顶会话"))
                            .accessibilityLabel(starred ? L("取消置顶") : L("置顶会话")).disabled(busy)
                            .focused($focus, equals: .pin)
                    }
                    if canQuickArchive {
                        Button(action: onArchive) {
                            Image(systemName: archived ? "arrow.uturn.backward" : "archivebox")
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }.help(archived ? L("恢复会话") : L("归档会话"))
                            .accessibilityLabel(archived ? L("恢复会话") : L("归档会话")).disabled(busy)
                            .focused($focus, equals: .archive)
                    }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: actionWidth, alignment: .trailing).clipped()
                    .opacity(showActions ? 1 : 0).allowsHitTesting(showActions).accessibilityHidden(!showActions)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: showActions)
            }.frame(width: trailingWidth, alignment: .trailing)
        }.padding(.trailing, 5).frame(height: subtitle == nil ? 34 : 48)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected ? 0.065 : hovered ? 0.03 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
            }
            .contentShape(Rectangle()).onHover { hovered = $0 }
            .task(id: titleHovered) {
                guard titleHovered else { showPreview = false; return }
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                showPreview = true
            }
            .popover(isPresented: $showPreview, arrowEdge: .trailing) {
                SessionHoverPreview(title: title, hostName: hostName, hostID: hostID,
                                    directory: directory, detail: detail, groups: groups, updatedAt: updatedAt)
            }
    }

}

struct SessionHoverPreview: View {
    @Environment(\.locale) private var locale
    let title: String
    let hostName: String?
    let hostID: UUID?
    let directory: String?
    let detail: String?
    let groups: [String]
    let updatedAt: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if updatedAt > 0 {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(updateTime(relativeTo: context.date))
                            .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let directory, !directory.isEmpty {
                    Label {
                        Text(URL(fileURLWithPath: directory).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .help(directory).accessibilityLabel(directory)
                    } icon: {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                    }
                }
                if let hostName {
                    HStack(spacing: 8) {
                        HostIdentityIcon(hostID: hostID).frame(width: 16)
                        Text(hostName).lineLimit(2)
                    }
                }
                if !groups.isEmpty {
                    Label(groups.joined(separator: "、"), systemImage: "square.stack")
                        .foregroundStyle(.secondary).lineLimit(2)
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }
            }.font(.system(size: 13))
        }.padding(14).frame(width: 340, alignment: .leading)
    }

    private func updateTime(relativeTo now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        // Match SessionTime on each tick, including while the remote clock is ahead.
        return formatter.localizedString(fromTimeInterval: min(0, updatedAt - now.timeIntervalSince1970))
    }

}
