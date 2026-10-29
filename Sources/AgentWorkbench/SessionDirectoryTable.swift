import AppKit
import SwiftUI
import WorkbenchCore

/// Reusable native cells keep scrolling independent of SwiftUI row graphs.
/// The existing SwiftUI session menu is built only when requested.
struct SessionDirectoryTable: NSViewRepresentable {
    let sessions: [WorkspaceSession]
    let selection: String?
    let query: String
    let groups: SessionGroupIndex
    let now: Date
    let onOpen: (WorkspaceSession) -> Void
    let menu: (WorkspaceSession) -> NSMenu
    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = context.coordinator.table
        let column = NSTableColumn(identifier: .init("session"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.rowHeight = 56
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    /// Labels are presentation only; a normal button owns their click target,
    /// native keyboard focus and VoiceOver action.
    final class OpenButton: NSButton {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }
    }

    final class Cell: NSTableCellView {
        let openButton = OpenButton()
        let more = NSButton()
        let titleLabel = NSTextField(labelWithString: "")
        let detail = NSTextField(labelWithString: "")
        let time = NSTextField(labelWithString: "")
        let icon = NSImageView()
        let progress = NSProgressIndicator()
        var onOpen: (() -> Void)?
        var makeMenu: (() -> NSMenu)?
        var selected = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            openButton.title = ""; openButton.isBordered = false
            openButton.target = self; openButton.action = #selector(openSession)
            more.title = ""; more.isBordered = false
            more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
            more.target = self; more.action = #selector(showMenu)
            titleLabel.font = .systemFont(ofSize: 14)
            detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
            time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); time.textColor = .tertiaryLabelColor
            titleLabel.lineBreakMode = .byTruncatingTail
            detail.lineBreakMode = .byTruncatingMiddle
            for label in [titleLabel, detail, time] {
                label.maximumNumberOfLines = 1
                label.setAccessibilityElement(false)
                openButton.addSubview(label)
            }
            icon.setAccessibilityElement(false); openButton.addSubview(icon)
            progress.style = .spinning; progress.controlSize = .small
            progress.isDisplayedWhenStopped = false
            progress.setAccessibilityElement(false); openButton.addSubview(progress)
            addSubview(openButton); addSubview(more)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ item: WorkspaceSession, parent: SessionDirectoryTable) {
            let status = item.online ? item.detail : WorkbenchCore.L("离线 · 状态未同步", locale: parent.locale)
            let metadata = [item.hostName, item.directory, status].filter { !$0.isEmpty }.joined(separator: " · ")
            titleLabel.stringValue = item.title
            titleLabel.textColor = item.online ? .labelColor : .secondaryLabelColor
            detail.stringValue = metadata
            time.stringValue = SessionTime.label(since: item.updatedAt, waiting: false, now: parent.now, locale: parent.locale) ?? ""
            openButton.isEnabled = item.online
            openButton.setAccessibilityLabel(item.title)
            openButton.setAccessibilityValue(([metadata, time.stringValue] + parent.groups[item.id]).filter { !$0.isEmpty }.joined(separator: " · "))
            openButton.setAccessibilityIdentifier("directory.session." + item.id)
            more.setAccessibilityLabel(WorkbenchCore.L("会话操作", locale: parent.locale))
            toolTip = ([item.title, item.directory] + parent.groups[item.id]).joined(separator: "\n")
            selected = parent.selection == item.id
            let running = item.online && item.section == .running
            if running { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
            icon.isHidden = running
            let symbol = !item.online ? "wifi.slash" : item.section == .attention ? "exclamationmark.circle.fill" : item.section == .review ? "circle.fill" : item.reference.kind.symbol
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = !item.online ? .secondaryLabelColor : item.section == .attention ? .systemOrange : item.section == .review ? .systemBlue : .secondaryLabelColor
            // Capture the session value: reuse must not route to a former row.
            onOpen = { parent.onOpen(item) }
            makeMenu = { parent.menu(item) }
            needsLayout = true; needsDisplay = true
        }
        override func layout() {
            super.layout()
            openButton.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 38), height: 56)
            more.frame = NSRect(x: max(0, bounds.width - 34), y: 14, width: 28, height: 28)
            let timeWidth = min(100, ceil(time.intrinsicContentSize.width))
            let textWidth = max(0, openButton.bounds.width - 48 - timeWidth - 12)
            titleLabel.frame = NSRect(x: 40, y: 8, width: textWidth, height: 18)
            detail.frame = NSRect(x: 40, y: 30, width: textWidth, height: 16)
            time.frame = NSRect(x: openButton.bounds.width - timeWidth - 4, y: 21, width: timeWidth, height: 16)
            icon.frame = NSRect(x: 12, y: 21, width: 14, height: 14)
            progress.frame = NSRect(x: 10, y: 19, width: 18, height: 18)
        }
        override func draw(_ dirtyRect: NSRect) {
            if selected {
                NSColor(WorkbenchTheme.Fill.selected).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: WorkbenchTheme.Radius.row, yRadius: WorkbenchTheme.Radius.row).fill()
            }
        }
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
        @objc private func openSession() { onOpen?() }
        @objc private func showMenu() {
            makeMenu?().popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.minY), in: self)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let table = NSTableView()
        private var parent: SessionDirectoryTable?
        func numberOfRows(in tableView: NSTableView) -> Int { parent?.sessions.count ?? 0 }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("session")
            let cell = table.makeView(withIdentifier: id, owner: nil) as? Cell ?? Cell()
            cell.identifier = id
            cell.configure(parent!.sessions[row], parent: parent!)
            return cell
        }
        func apply(_ next: SessionDirectoryTable) {
            let old = parent
            let queryChanged = old?.query != next.query
            let visible = table.rows(in: table.visibleRect)
            let anchor = visible.location != NSNotFound && visible.location < (old?.sessions.count ?? 0) ? old?.sessions[visible.location].id : nil
            let offset = anchor == nil ? 0 : table.visibleRect.minY - table.rect(ofRow: visible.location).minY
            parent = next
            if old?.sessions.map(\.id) != next.sessions.map(\.id) {
                table.reloadData()
                if !queryChanged, let anchor, let index = next.sessions.firstIndex(where: { $0.id == anchor }),
                   let scroll = table.enclosingScrollView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: index).minY + offset))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            table.enumerateAvailableRowViews { _, index in
                (self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? Cell)?.configure(next.sessions[index], parent: next)
            }
            if queryChanged || next.selection != old?.selection {
                if let selection = next.selection, let index = next.sessions.firstIndex(where: { $0.id == selection }) {
                    table.scrollRowToVisible(index)
                } else if queryChanged, !next.sessions.isEmpty { table.scrollRowToVisible(0) }
            }
        }
    }
}
