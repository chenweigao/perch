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
    /// The session cannot be reached. Compact rows say so with a badge, not a status line,
    /// so the row keeps its height when a machine drops off.
    var offline = false
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
        Group {
            if compact { conversationRow }
            else { standardRow }
        }
        .background { SidebarHighlight(selected: selected, hovered: hovered) }
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .help(Text(verbatim: tooltip))
    }

    /// Pin and archive, shared by both row layouts.
    @ViewBuilder private var actionButtons: some View {
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
        }
    }

    /// Titles own the space. The status column holds a stable 28 pt minimum and
    /// grows for wider labels instead of truncating; pin/archive remain in the
    /// row's context menu.
    private var fullActionWidth: CGFloat { CGFloat((archived ? 0 : 1) + (canQuickArchive ? 1 : 0)) * 28 }

    private var conversationRow: some View {
        ZStack(alignment: .topTrailing) {
            conversationButton
            // Pin and archive replace the age while the pointer is over the row; the
            // material keeps them legible over a long title.
            if fullActionWidth > 0 {
                actionButtons.buttonStyle(.plain).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary)
                    .frame(width: fullActionWidth, height: 28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip))
                    .padding(.trailing, SidebarMetrics.rowInset - 2).padding(.top, 4)
                    .opacity(showActions ? 1 : 0).allowsHitTesting(showActions).accessibilityHidden(!showActions)
                    .animation(reduceMotion ? nil : .easeOut(duration: SidebarMetrics.highlightDuration), value: showActions)
            }
        }
    }

    private var conversationButton: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: SidebarMetrics.labelSpacing) {
                indicator.frame(width: SidebarMetrics.iconWidth, height: 18).padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: SidebarMetrics.titleSize, weight: .regular))
                        .lineLimit(2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let subtitle {
                        Text(subtitle).font(.system(size: SidebarMetrics.detailSize)).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Group {
                    if running {
                        ConversationBusyIndicator().help("运行中").accessibilityIdentifier("sidebar.running")
                    } else if offline {
                        Image(systemName: "wifi.slash").font(.system(size: WorkbenchTheme.Typography.caption))
                            .foregroundStyle(Color.orange).help("离线 · 状态未同步")
                            .accessibilityHidden(true)
                    } else if updatedAt > 0 {
                        // Two-digit labels ("25分") exceed the old 28 pt slot and
                        // collapsed to an ellipsis; the slot widens instead.
                        SessionTimeText(updatedAt: updatedAt)
                    }
                }.frame(minWidth: 28, minHeight: 18, maxHeight: 18, alignment: .trailing).padding(.top, 1)
                    .opacity(showActions && fullActionWidth > 0 ? 0 : 1)
            }.padding(.horizontal, SidebarMetrics.rowInset).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: SidebarMetrics.sessionMinimumHeight, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!canOpen).focused($focus, equals: .open)
            .accessibilityLabel(title)
            .accessibilityValue(([offline ? L("离线 · 状态未同步") : nil, hostName, directory, detail,
                                  updatedAt > 0 ? SessionTime.label(since: updatedAt, waiting: false) : nil].compactMap { $0 } + groups).joined(separator: " · "))
    }

    private var standardRow: some View {
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
                            Text(subtitle ?? "").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary).lineLimit(1)
                                .frame(height: subtitle == nil ? 0 : nil).clipped()
                                .padding(.top, subtitle == nil ? -3 : 0)
                                .accessibilityHidden(subtitle == nil)
                        } else {
                        if let subtitle {
                            Text(subtitle).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        }
                        #else
                        if let subtitle {
                            Text(subtitle).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        #endif
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if compact && running {
                        ConversationBusyIndicator().help("运行中")
                            .accessibilityIdentifier("sidebar.running")
                    }
                    if updatedAt > 0 && !compact {
                        SessionTimeText(updatedAt: updatedAt, compact: false, tone: .tertiary)
                    }
                }.padding(.leading, SidebarMetrics.rowInset).padding(.trailing, 4)
                    .frame(height: rowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canOpen).focused($focus, equals: .open)
                .accessibilityLabel(title)
                .accessibilityValue(([hostName, directory, detail, updatedAt > 0 ? SessionTime.label(since: updatedAt, waiting: false) : nil].compactMap { $0 } + groups).joined(separator: " · "))
            ZStack(alignment: .trailing) {
                if compact && !running && updatedAt > 0 {
                    SessionTimeText(updatedAt: updatedAt, tone: .tertiary)
                        .opacity(showActions ? 0 : 1).accessibilityHidden(true)
                } else if hostName != nil && !compact {
                    HostIdentityIcon(hostID: hostID)
                        .font(.system(size: WorkbenchTheme.Typography.body)).frame(width: 28)
                        .opacity(showActions && actionWidth > 0 ? 0 : 1)
                        .accessibilityHidden(true)
                }
                actionButtons.buttonStyle(.plain).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary)
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
    }

    /// Full title, with host and directory on a second line when present.
    private var tooltip: String {
        let extra = [hostName, directory].compactMap { $0 }.joined(separator: " · ")
        return extra.isEmpty ? title : title + "\n" + extra
    }

}
