import AppKit
import SwiftUI
import WorkbenchCore

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
    var waiting = false
    var failed = false
    var unread = false
    var offline = false
    var actions: AnyView? = nil
    let selected: Bool
    let canOpen: Bool
    let onOpen: () -> Void
    @ViewBuilder let indicator: Indicator
    @State private var hovered = false
    @State private var showPreview = false
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.locale) private var locale

    private var trailingWidth: CGFloat { compact ? (running ? 0 : 36) : (hostName == nil ? 0 : 28) }
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
        .contentShape(Rectangle())
        .accessibilityIdentifier("sidebar.row")
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            SessionRowPreview(title: title, detail: tooltip)
        }
    }

    private func updateHover(_ inside: Bool) {
        hovered = inside
        previewTask?.cancel()
        guard inside else {
            showPreview = false
            return
        }
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, hovered else { return }
            showPreview = true
        }
    }

    /// Compact single-line rows prioritize the title and essential status;
    /// the trailing menu and full preview appear only while hovered.
    private var conversationRow: some View {
        HStack(spacing: 0) {
            Button {
                showPreview = false
                onOpen()
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    Text(title).font(.system(size: SidebarMetrics.titleSize, weight: unread ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if running {
                        ConversationBusyIndicator().accessibilityIdentifier("sidebar.running")
                            .frame(width: 18, height: 18)
                    } else if offline {
                        Image(systemName: "wifi.slash").font(.system(size: WorkbenchTheme.Typography.caption))
                            .foregroundStyle(WorkbenchTheme.quiet)
                            .accessibilityHidden(true)
                            .frame(width: 18, height: 18)
                    } else {
                        HStack(spacing: 4) {
                            if failed {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                                    .accessibilityHidden(true)
                            } else if waiting {
                                Circle().fill(Color.orange).frame(width: 6, height: 6)
                                    .accessibilityHidden(true)
                            } else if unread {
                                Circle().fill(Color.blue).frame(width: 6, height: 6)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }.padding(.horizontal, SidebarMetrics.rowInset)
                    .frame(maxWidth: .infinity, minHeight: SidebarMetrics.rowHeight, maxHeight: SidebarMetrics.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canOpen)
                .accessibilityLabel(title)
                .accessibilityValue(([offline ? L("离线 · 状态未同步") : nil, hostName, directory, detail,
                                      updatedAt > 0 ? SessionTime.label(since: updatedAt, waiting: false) : nil].compactMap { $0 } + groups).joined(separator: " · "))
            if let actions {
                Menu { actions } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WorkbenchTheme.quiet)
                        .frame(width: 24, height: 24)
                        .background(WorkbenchTheme.Fill.surface,
                                    in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip, style: .continuous))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .buttonStyle(.plain)
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .accessibilityLabel("会话操作")
                .accessibilityIdentifier("sidebar.row.actions")
                .onHover { inside in if inside { showPreview = false } }
            }
        }
        .onHover(perform: updateHover)
    }

    private var standardRow: some View {
        HStack(spacing: 0) {
            Button {
                onOpen()
            } label: {
                HStack(alignment: .top, spacing: SidebarMetrics.labelSpacing) {
                    indicator.frame(width: SidebarMetrics.iconWidth, height: 16).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: SidebarMetrics.titleSize, weight: unread ? .semibold : .regular))
                            .lineLimit(1).truncationMode(.tail)
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
            }.buttonStyle(.plain).disabled(!canOpen)
                .help(Text(verbatim: tooltip))
                .accessibilityLabel(title)
                .accessibilityValue(([hostName, directory, detail, updatedAt > 0 ? SessionTime.label(since: updatedAt, waiting: false) : nil].compactMap { $0 } + groups).joined(separator: " · "))
            ZStack(alignment: .trailing) {
                if compact && !running && updatedAt > 0 {
                    SessionTimeText(updatedAt: updatedAt, tone: .tertiary)
                        .accessibilityHidden(true)
                } else if hostName != nil && !compact {
                    HostIdentityIcon(hostID: hostID)
                        .font(.system(size: WorkbenchTheme.Typography.body)).frame(width: 28)
                        .accessibilityHidden(true)
                }
            }.frame(width: trailingWidth, alignment: .trailing)
        }.padding(.trailing, 5).frame(height: rowHeight)
    }

    /// Full title, host, directory, Agent/status detail and timestamp on demand.
    var tooltip: String {
        var lines = [title]
        let location = [hostName, directory].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !location.isEmpty { lines.append(location) }
        let meta = ([detail].compactMap { $0 }.filter { !$0.isEmpty } + groups).joined(separator: " · ")
        if !meta.isEmpty { lines.append(meta) }
        if updatedAt > 0, let timeLabel = SessionTime.label(since: updatedAt, waiting: false) {
            lines.append(timeLabel)
        }
        return lines.joined(separator: "\n")
    }

}

private struct SessionRowPreview: View {
    let title: String
    let detail: String
    private var lines: [String] {
        detail.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
                .foregroundStyle(WorkbenchTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sidebar.row.preview.title")
            ForEach(lines.dropFirst(), id: \.self) { line in
                Text(line)
                    .font(.system(size: WorkbenchTheme.Typography.caption))
                    .foregroundStyle(WorkbenchTheme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous)
            .strokeBorder(WorkbenchTheme.Stroke.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.row.preview")
    }
}
