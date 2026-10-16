import AppKit
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
    var compact = false
    var running = false
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
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Focus { case open, pin, archive }
    @FocusState private var focus: Focus?

    private var showActions: Bool { hovered || focus != nil }
    private var actionWidth: CGFloat { showActions ? CGFloat((archived ? 0 : 1) + (canQuickArchive ? 1 : 0)) * 28 : 0 }
    private var trailingWidth: CGFloat { compact ? (running ? actionWidth : 36) : max(actionWidth, hostName == nil ? 0 : 28) }
    private var rowHeight: CGFloat {
        #if PERCH_ACCEPTANCE
        if NativeAcceptanceProbe.shared.fixedSidebarHeight { return SidebarMetrics.subtitleRowHeight }
        #endif
        return subtitle == nil ? SidebarMetrics.rowHeight : SidebarMetrics.subtitleRowHeight
    }
    var body: some View {
        HStack(spacing: 0) {
            Button {
                onOpen()
            } label: {
                HStack(alignment: .top, spacing: SidebarMetrics.labelSpacing) {
                    indicator.frame(width: SidebarMetrics.iconWidth, height: 16).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: SidebarMetrics.titleSize)).lineLimit(1).truncationMode(.tail)
                        #if PERCH_ACCEPTANCE
                        if NativeAcceptanceProbe.shared.persistentSubtitle {
                            Text(subtitle ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                .frame(height: subtitle == nil ? 0 : nil).clipped()
                                .padding(.top, subtitle == nil ? -3 : 0)
                                .accessibilityHidden(subtitle == nil)
                        } else {
                        if let subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        }
                        #else
                        if let subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        #endif
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if compact && running {
                        ConversationBusyIndicator().help("运行中")
                            .accessibilityIdentifier("sidebar.running")
                    }
                    if updatedAt > 0 && !compact {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(SessionTime.label(since: updatedAt, waiting: false, now: context.date) ?? "")
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                    }
                }.padding(.leading, SidebarMetrics.rowInset).padding(.trailing, 4)
                    .frame(height: rowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canOpen).focused($focus, equals: .open)
                .accessibilityLabel(title)
                .accessibilityValue(([hostName, directory, detail, updatedAt > 0 ? SessionTime.label(since: updatedAt, waiting: false) : nil].compactMap { $0 } + groups).joined(separator: " · "))
            ZStack(alignment: .trailing) {
                if compact && !running && updatedAt > 0 {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(SessionTime.compactLabel(since: updatedAt, now: context.date, locale: locale) ?? "")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                    }.opacity(showActions ? 0 : 1).accessibilityHidden(true)
                } else if hostName != nil && !compact {
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
                    .background {
                        if compact && showActions {
                            RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip).fill(.regularMaterial)
                        }
                    }
                    .opacity(showActions ? 1 : 0).allowsHitTesting(showActions).accessibilityHidden(!showActions)
                    .animation(reduceMotion ? nil : .easeOut(duration: SidebarMetrics.highlightDuration), value: showActions)
            }.frame(width: trailingWidth, alignment: .trailing)
        }.padding(.trailing, 5).frame(height: rowHeight)
            .background { SidebarHighlight(selected: selected, hovered: hovered) }
            .contentShape(Rectangle()).onHover { hovered = $0 }
            // Native tooltip carries what the row cannot show: the full title
            // plus host and directory. A custom card covered the reading area.
            .help(Text(verbatim: tooltip))
    }

    /// Full title, with host and directory on a second line when present.
    private var tooltip: String {
        let extra = [hostName, directory].compactMap { $0 }.joined(separator: " · ")
        return extra.isEmpty ? title : title + "\n" + extra
    }

}
