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
    @State private var rowView: NSView?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Focus { case open, pin, archive }
    @FocusState private var focus: Focus?

    private var showActions: Bool { hovered || focus != nil }
    private var actionWidth: CGFloat { showActions ? CGFloat((archived ? 0 : 1) + (canQuickArchive ? 1 : 0)) * 28 : 0 }
    private var trailingWidth: CGFloat { max(actionWidth, hostName == nil ? 0 : 28) }
    private var rowHeight: CGFloat {
        #if PERCH_ACCEPTANCE
        if NativeAcceptanceProbe.shared.fixedSidebarHeight { return 48 }
        #endif
        return subtitle == nil ? 34 : 48
    }
    var body: some View {
        HStack(spacing: 0) {
            Button {
                SessionPreviewPanel.shared.hide()
                onOpen()
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    indicator.frame(width: 17, height: 16).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
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
                    if updatedAt > 0 {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(SessionTime.label(since: updatedAt, waiting: false, now: context.date) ?? "")
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                    }
                }.padding(.leading, 10).padding(.trailing, 4)
                    .frame(height: rowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canOpen).focused($focus, equals: .open)
                .accessibilityLabel(title)
                .accessibilityValue(([hostName, directory, detail, updatedAt > 0 ? SessionTime.label(since: updatedAt, waiting: false) : nil].compactMap { $0 } + groups).joined(separator: " · "))
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
        }.padding(.trailing, 5).frame(height: rowHeight)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected ? 0.065 : hovered ? 0.03 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
            }
            .contentShape(Rectangle()).onHover { hovered = $0 }
            .background(RowAnchorProbe { rowView = $0 })
            .task(id: titleHovered) {
                guard titleHovered else { SessionPreviewPanel.shared.hide(); return }
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                guard let rowView else { return }
                SessionPreviewPanel.shared.show(anchor: rowView, colorScheme: colorScheme, title: title,
                                                hostName: hostName, hostID: hostID, directory: directory,
                                                detail: detail, groups: groups, updatedAt: updatedAt)
            }
            .onDisappear { SessionPreviewPanel.shared.hide() }
    }

}

/// Captures the row's backing view so the preview panel can anchor to it.
private struct RowAnchorProbe: NSViewRepresentable {
    let resolve: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { resolve(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Floating, non-interactive session preview. Unlike a popover the panel ignores
/// mouse events, so a visible preview can never swallow or block a click; any
/// click, scroll, key press or window change dismisses it instead.
@MainActor
final class SessionPreviewPanel {
    static let shared = SessionPreviewPanel()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel != nil }
    var panelIgnoresMouseEvents: Bool { panel?.ignoresMouseEvents ?? false }
    var panelFrame: NSRect? { panel?.frame }

    func show(anchor: NSView, colorScheme: ColorScheme, title: String, hostName: String?, hostID: UUID?,
              directory: String?, detail: String?, groups: [String], updatedAt: Double) {
        hide()
        guard let window = anchor.window else { return }
        let content = SessionHoverPreview(title: title, hostName: hostName, hostID: hostID,
                                          directory: directory, detail: detail, groups: groups, updatedAt: updatedAt)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)))
            .preferredColorScheme(colorScheme)
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting

        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var origin = NSPoint(x: anchorRect.maxX + 6, y: anchorRect.midY - size.height / 2)
        if let screen = window.screen {
            let visible = screen.visibleFrame
            origin.x = min(origin.x, visible.maxX - size.width - 6)
            origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - size.height - 6)
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel

        let masks: [NSEvent.EventTypeMask] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        monitors = masks.compactMap { mask in
            NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                Task { @MainActor [weak self] in self?.hide() }
                return event
            }
        }
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.hide() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.hide() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.hide() }
            }
        ]
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.close()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
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
                if updatedAt > 0 {
                    Label {
                        Text(Date(timeIntervalSince1970: updatedAt),
                             format: Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "clock").foregroundStyle(.secondary)
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
