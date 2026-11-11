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
    @State private var showActionsMenu = false
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

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
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            SessionRowPreview(title: title, detail: tooltip)
                .preferredColorScheme(colorScheme)
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
    /// the trailing menu and delayed preview expose details on demand.
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
                        ConversationBusyIndicator().help("运行中").accessibilityIdentifier("sidebar.running")
                            .frame(width: 18, height: 18)
                    } else if offline {
                        Image(systemName: "wifi.slash").font(.system(size: WorkbenchTheme.Typography.caption))
                            .foregroundStyle(WorkbenchTheme.quiet).help("离线 · 状态未同步")
                            .accessibilityHidden(true)
                            .frame(width: 18, height: 18)
                    } else {
                        HStack(spacing: 4) {
                            if failed {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                                    .help(detail ?? L("运行出错"))
                                    .accessibilityHidden(true)
                            } else if waiting {
                                Circle().fill(Color.orange).frame(width: 6, height: 6)
                                    .help(detail ?? L("等你处理"))
                                    .accessibilityHidden(true)
                            } else if unread {
                                Circle().fill(Color.blue).frame(width: 6, height: 6)
                                    .help("有未读结果")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }.padding(.horizontal, SidebarMetrics.rowInset)
                    .frame(maxWidth: .infinity, minHeight: SidebarMetrics.rowHeight, maxHeight: SidebarMetrics.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canOpen)
                .accessibilityIdentifier("sidebar.row")
                .accessibilityLabel(title)
                .accessibilityValue(([offline ? L("离线 · 状态未同步") : nil, hostName, directory, detail,
                                      updatedAt > 0 ? SessionTime.label(since: updatedAt, waiting: false) : nil].compactMap { $0 } + groups).joined(separator: " · "))
            if let actions {
                Button {
                    showPreview = false
                    showActionsMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WorkbenchTheme.quiet)
                        .frame(width: 24, height: 24)
                        .background(WorkbenchTheme.Fill.surface,
                                    in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovered || showActionsMenu ? 1 : 0)
                .allowsHitTesting(hovered)
                .onHover { inside in
                    if inside {
                        previewTask?.cancel()
                        showPreview = false
                    }
                }
                .accessibilityLabel("会话操作")
                .accessibilityIdentifier("sidebar.row.actions")
                .popover(isPresented: $showActionsMenu, arrowEdge: .trailing) {
                    actions
                        .preferredColorScheme(colorScheme)
                        .environment(\.sessionActionPresentation, .popover)
                        .buttonStyle(SessionActionButtonStyle())
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 208)
                        .padding(6)
                }
            }
        }
        .overlay(SessionHoverTracking(onChange: updateHover))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 308, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous)
            .strokeBorder(WorkbenchTheme.Stroke.hairline.opacity(0.55), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.row.preview")
    }
}

private struct SessionHoverTracking: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> SessionHoverTrackingView {
        let view = SessionHoverTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: SessionHoverTrackingView, context: Context) {
        view.onChange = onChange
    }
}

private final class SessionHoverTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        FileHandle.standardError.write(Data("HOVER-TRACK window=\(String(describing: window)) bounds=\(bounds)\n".utf8))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
        FileHandle.standardError.write(Data("HOVER-TRACK area bounds=\(bounds) visible=\(visibleRect) key=\(window?.isKeyWindow == true) active=\(NSApp.isActive)\n".utf8))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        FileHandle.standardError.write(Data("HOVER-TRACK entered \(event.locationInWindow) bounds=\(bounds)\n".utf8))
        onChange?(true)
    }
    override func mouseExited(with event: NSEvent) {
        FileHandle.standardError.write(Data("HOVER-TRACK exited \(event.locationInWindow) bounds=\(bounds)\n".utf8))
        onChange?(false)
    }
}

enum SessionActionPresentation {
    case contextMenu
    case popover
}

private struct SessionActionPresentationKey: EnvironmentKey {
    static let defaultValue = SessionActionPresentation.contextMenu
}

extension EnvironmentValues {
    var sessionActionPresentation: SessionActionPresentation {
        get { self[SessionActionPresentationKey.self] }
        set { self[SessionActionPresentationKey.self] = newValue }
    }
}

private struct SessionActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(configuration.role == .destructive ? Color.red : WorkbenchTheme.ink)
                .opacity(isEnabled ? 1 : 0.4)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip, style: .continuous)
                        .fill(configuration.isPressed ? WorkbenchTheme.Fill.pressed : WorkbenchTheme.Fill.hover)
                        .opacity(hovered || configuration.isPressed ? 1 : 0)
                }
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}
