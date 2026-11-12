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
    @State private var pressed = false
    @State private var showPreview = false
    @State private var showActionsMenu = false
    @State private var previewTask: Task<Void, Never>?
    /// The title's available width, to tell whether the row truncates it.
    @State private var titleWidth: CGFloat = 0
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
        .background { SidebarHighlight(selected: selected, hovered: hovered, pressed: pressed) }
        .contentShape(Rectangle())
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            SessionRowPreview(title: titleTruncated ? title : nil, lines: previewLines)
                .preferredColorScheme(colorScheme)
        }
    }

    /// The row shows less than the whole title.
    private var titleTruncated: Bool {
        let font = NSFont.systemFont(ofSize: SidebarMetrics.titleSize, weight: unread ? .semibold : .regular)
        return titleWidth > 0 && ceil((title as NSString).size(withAttributes: [.font: font]).width) > titleWidth + 0.5
    }

    /// What the preview adds to the row: location, Agent/status and groups, time.
    private var previewLines: [String] {
        Array(tooltip.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).dropFirst())
    }

    private func updateHover(_ inside: Bool) {
        hovered = inside
        previewTask?.cancel()
        guard inside else {
            if showPreview { SessionPreviewTiming.lastDismissed = Date() }
            showPreview = false
            return
        }
        guard !showActionsMenu, titleTruncated || !previewLines.isEmpty else { return }
        let delay = SessionPreviewTiming.delay
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, hovered, !showActionsMenu, !SessionPreviewTiming.scrolling else { return }
            showPreview = true
        }
    }

    /// Compact single-line rows prioritize the title and essential status;
    /// the trailing menu and delayed preview expose details on demand.
    private var conversationRow: some View {
        // Running and failed rows keep their mark in view while the actions button
        // takes the trailing slot; their reserve is fixed, so the title never reflows.
        let keepsStatus = actions != nil && (running || failed)
        let actionsShown = actions != nil && (hovered || showActionsMenu)
        return HStack(spacing: 0) {
            Button {
                showPreview = false
                onOpen()
            } label: {
                Text(title).font(.system(size: SidebarMetrics.titleSize, weight: unread ? .semibold : .regular))
                    .foregroundStyle(selected || unread ? WorkbenchTheme.ink
                                     : WorkbenchTheme.ink.opacity(SidebarMetrics.idleTitleOpacity))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                    .padding(.leading, SidebarMetrics.rowInset).padding(.trailing, 4)
                    .frame(maxWidth: .infinity, minHeight: SidebarMetrics.rowHeight, maxHeight: SidebarMetrics.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(SidebarPressStyle(pressed: $pressed)).disabled(!canOpen)
                .accessibilityIdentifier("sidebar.row")
                .accessibilityLabel(title)
                .accessibilityValue(([offline ? L("离线 · 状态未同步") : nil, hostName, directory, detail,
                                      updatedAt > 0 ? SessionTime.label(since: updatedAt, waiting: false) : nil].compactMap { $0 } + groups).joined(separator: " · "))
            if keepsStatus {
                ZStack { if actionsShown { statusMark } }
                    .frame(width: SidebarMetrics.statusReserveWidth, height: SidebarMetrics.actionSize)
            }
            // Status sits on the row's trailing edge; on hover the actions button
            // takes the same slot, so the title column ends in one clean line.
            ZStack {
                if !actionsShown { statusMark }
                if let actions {
                    SessionActionsButton(visible: actionsShown, locale: locale, label: L("会话操作"), actions: actions,
                        willOpen: {
                            previewTask?.cancel()
                            showPreview = false
                            showActionsMenu = true
                        },
                        didClose: { showActionsMenu = false })
                        .frame(width: SidebarMetrics.actionSize, height: SidebarMetrics.actionSize)
                        .onHover { inside in
                            if inside {
                                previewTask?.cancel()
                                showPreview = false
                            }
                        }
                }
            }.frame(width: SidebarMetrics.actionSize, height: SidebarMetrics.actionSize)
                .padding(.trailing, SidebarMetrics.rowTrailingInset)
        }
        .overlay(SessionHoverTracking(onChange: updateHover))
    }

    @ViewBuilder private var statusMark: some View {
        if running {
            ConversationBusyIndicator().help("运行中").accessibilityIdentifier("sidebar.running")
                .frame(width: 18, height: 18)
        } else if offline {
            Image(systemName: "wifi.slash").font(.system(size: WorkbenchTheme.Typography.caption))
                .foregroundStyle(WorkbenchTheme.quiet).help("离线 · 状态未同步")
                .accessibilityHidden(true)
        } else if failed {
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

/// Preview timing shared by every row: a first preview waits for a real dwell;
/// moving on to a neighbor right after one closed swaps at once, as tooltips do.
/// Nothing opens while the list is scrolling under the pointer.
@MainActor enum SessionPreviewTiming {
    static let cold: Duration = .milliseconds(900)
    static let warm: Duration = .milliseconds(120)
    static let warmWindow: TimeInterval = 0.8
    static var lastDismissed: Date?
    static var scrollingUntil = Date.distantPast
    static var scrolling: Bool { Date() < scrollingUntil }
    static var delay: Duration {
        guard let lastDismissed, Date().timeIntervalSince(lastDismissed) < warmWindow else { return cold }
        return warm
    }
}

/// Only what the row doesn't already show: the full title when the row truncates
/// it, then location, Agent/status and groups, and time.
private struct SessionRowPreview: View {
    let title: String?
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
                    .foregroundStyle(WorkbenchTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
                    .accessibilityIdentifier("sidebar.row.preview.title")
            }
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: WorkbenchTheme.Typography.caption))
                    .foregroundStyle(WorkbenchTheme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // A fixed width with its natural height, so the popover sizes to it exactly.
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.row.preview")
    }
}

/// The trailing ⋯: a SwiftUI button (so it stays in the accessibility tree) that
/// pops the same native menu as the row's context menu, anchored under itself
/// through an AppKit view behind it. Hidden until the row is hovered; it takes
/// no clicks while hidden.
private struct SessionActionsButton: View {
    let visible: Bool
    let locale: Locale
    let label: String
    let actions: AnyView
    let willOpen: () -> Void
    let didClose: () -> Void
    @State private var anchor = SessionActionsMenuAnchor()

    var body: some View {
        Button {
            let menu = NSHostingMenu(rootView: actions.environment(\.locale, locale))
            willOpen()
            anchor.present(menu, didClose: didClose)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WorkbenchTheme.quiet)
                .frame(width: SidebarMetrics.actionSize, height: SidebarMetrics.actionSize)
                .background(WorkbenchTheme.Fill.surface,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(SessionActionsMenuAnchorView(anchor: anchor))
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier("sidebar.row.actions")
    }
}

/// Holds the AppKit view the actions menu pops up from.
@MainActor final class SessionActionsMenuAnchor {
    /// The menu while it is open; checks read its items and dismiss it.
    static weak var presentedMenu: NSMenu?
    weak var view: NSView?

    func present(_ menu: NSMenu, didClose: @escaping () -> Void) {
        // Pop up after the click (or AXPress) returns: the menu's tracking loop
        // must not run inside the action that opened it.
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.view, view.window != nil else { didClose(); return }
            Self.presentedMenu = menu
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
            Self.presentedMenu = nil
            didClose()
            NotificationCenter.default.post(name: SessionHoverTrackingView.refreshNotification, object: nil)
        }
    }
}

private struct SessionActionsMenuAnchorView: NSViewRepresentable {
    let anchor: SessionActionsMenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = SessionActionsMenuAnchorNSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

private final class SessionActionsMenuAnchorNSView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    /// Re-read the pointer after something that swallows mouse events (a menu).
    static let refreshNotification = Notification.Name("PerchSessionRowHoverRefresh")
    var onChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    private var inside = false
    private var observers: [NSObjectProtocol] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        // Only while Perch is the active app: a background window never pops previews.
        let next = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard window != nil else { set(false); return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Self.refreshNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(false) }
        })
        if let scroll = enclosingScrollView {
            // Rows slide under a still pointer while the list scrolls: drop the
            // hover, hold previews back, and re-read the pointer once it settles.
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
                observers.append(center.addObserver(forName: name, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        SessionPreviewTiming.scrollingUntil = Date().addingTimeInterval(0.3)
                        self?.set(false)
                    }
                })
            }
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func set(_ next: Bool) {
        guard next != inside else { return }
        inside = next
        onChange?(next)
    }

    private func refresh() {
        guard let window, NSApp.isActive else { set(false); return }
        set(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { set(true) }
    override func mouseExited(with event: NSEvent) { set(false) }
}
