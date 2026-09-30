#if PERCH_ACCEPTANCE
import AppKit
import SwiftUI
import WorkbenchCore

/// Experimental container only: row content/actions remain the production SwiftUI views.
struct AcceptanceSidebarTable: NSViewRepresentable {
    struct Item {
        let id: String
        let session: WorkspaceSession?
        let height: CGFloat
        let content: AnyView
    }
    let items: [Item]
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        let table = context.coordinator.table
        let column = NSTableColumn(identifier: .init("content"))
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.selectionHighlightStyle = .none; table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        scroll.documentView = table
        NativeAcceptanceProbe.shared.sidebarTable = context.coordinator
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(items)
    }
    final class Cell: NSTableCellView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        override init(frame: NSRect) {
            super.init(frame: frame)
            host.translatesAutoresizingMaskIntoConstraints = false
            host.sizingOptions = []
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let table = NSTableView()
        var items: [Item] = []
        var created = 0
        var reused = 0
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { items[row].height }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier(items[row].session == nil ? items[row].id : "session")
            let cell: Cell
            if let old = tableView.makeView(withIdentifier: id, owner: nil) as? Cell { cell = old; reused += 1 }
            else { cell = Cell(); cell.identifier = id; created += 1 }
            cell.host.rootView = items[row].content
            return cell
        }
        func apply(_ next: [Item]) {
            let old = items
            var ids = old.map(\.id)
            items = next
            let wanted = Set(next.map(\.id))
            table.beginUpdates()
            for index in ids.indices.reversed() where !wanted.contains(ids[index]) {
                ids.remove(at: index); table.removeRows(at: IndexSet(integer: index), withAnimation: [])
            }
            for (index, item) in next.enumerated() {
                if let source = ids.firstIndex(of: item.id) {
                    if source != index { ids.insert(ids.remove(at: source), at: index); table.moveRow(at: source, to: index) }
                } else {
                    ids.insert(item.id, at: index); table.insertRows(at: IndexSet(integer: index), withAnimation: [])
                }
            }
            table.endUpdates()
            let heights = IndexSet(next.indices.filter { index in old.first(where: { $0.id == next[index].id })?.height != next[index].height })
            if !heights.isEmpty { table.noteHeightOfRows(withIndexesChanged: heights) }
            // Keep visible hosts; let NSTableView reuse offscreen cells.
            for index in next.indices {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? Cell {
                    cell.host.rootView = next[index].content
                }
            }
        }
        var visibleSessions: [WorkspaceSession] {
            let range = table.rows(in: table.visibleRect)
            guard range.location != NSNotFound else { return [] }
            return items.enumerated().filter { NSLocationInRange($0.offset, range) }.compactMap { $0.element.session }
        }
    }
}
#endif
