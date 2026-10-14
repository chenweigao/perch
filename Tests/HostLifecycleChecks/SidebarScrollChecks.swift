import AppKit
import SwiftUI
import Observation

@MainActor @Observable private final class SidebarScrollState {
    var selected: String?
    var revision = 0
    var context = "a"
    var moveSelectedToTop = false
    var selectionFrame = CGRect.zero
}
private struct SidebarRowFrame: NSViewRepresentable {
    let id: String
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
private struct SidebarScrollFixture: View {
    @Bindable var state: SidebarScrollState
    var body: some View {
        WorkspaceSidebarShell(page: .other, attentionCount: 0, environmentSummary: "Fixture",
            onSearch: {}, onNew: {}, onHome: {}, onInbox: {}, onArchive: {},
            scrollTargetID: state.selected, scrollContext: state.context,
            selectionFrame: state.selectionFrame) {
                let selectedFirst = state.moveSelectedToTop ? [state.selected].compactMap { $0 } : []
                ForEach(selectedFirst + (0..<100).map { "fixture-row-\($0)" }.filter { !selectedFirst.contains($0) }, id: \.self) { id in
                    Button { state.selected = id } label: {
                        Text("会话 \(id) · 状态 \(state.revision)")
                            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).id(id)
                        .background(SidebarRowFrame(id: id))
                        .trackSelectionFrame(selected: state.selected == id, into: $state.selectionFrame)
                }
            } environments: { EmptyView() }
    }
}
@MainActor func checkSidebarScroll() async throws {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 640),
                          styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let state = SidebarScrollState()
    let host = NSHostingView(rootView: SidebarScrollFixture(state: state))
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(300))
    let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first!
    let document = scroll.documentView!
    func row(_ id: String) -> NSView {
        descendants(host).first { $0.identifier?.rawValue == id }!
    }
    func rowFrame(_ id: String) -> NSRect { row(id).convert(row(id).bounds, to: document) }
    func position(_ y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    position(420)
    try await Task.sleep(for: .milliseconds(100))
    let viewport = scroll.documentVisibleRect
    let visible = (0..<100).map { "fixture-row-\($0)" }.filter { viewport.insetBy(dx: 0, dy: 10).contains(rowFrame($0)) }
    precondition(visible.count >= 4)
    // Click both edges of the visible range; either would jump with anchor .center.
    for id in [visible.first!, visible.last!, visible[1]] {
        let before = scroll.documentVisibleRect
        let view = row(id)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0)!)
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(state.selected == id, "Click must select the actual sidebar row")
        precondition(abs(scroll.documentVisibleRect.minY - before.minY) < 1,
                     "Clicking a visible session must not reposition the sidebar")
    }
    state.selected = "fixture-row-90"
    try await Task.sleep(for: .milliseconds(150))
    precondition(abs(rowFrame(state.selected!).maxY - scroll.documentVisibleRect.maxY) < 2,
                 "An external selection below the viewport reveals only to the nearest edge")
    state.selected = "fixture-row-2"
    try await Task.sleep(for: .milliseconds(150))
    precondition(abs(rowFrame(state.selected!).minY - scroll.documentVisibleRect.minY) < 2,
                 "An external selection above the viewport reveals only to the nearest edge")
    position(420)
    let beforeUpdate = scroll.documentVisibleRect
    state.revision += 1
    try await Task.sleep(for: .milliseconds(150))
    precondition(abs(scroll.documentVisibleRect.minY - beforeUpdate.minY) < 1,
                 "Background status refresh must not reveal the offscreen selected session again")
    // A regroup that moves a visible selection keeps it on screen.
    state.selected = "fixture-row-50"
    try await Task.sleep(for: .milliseconds(150))
    precondition(scroll.documentVisibleRect.contains(rowFrame(state.selected!)), "Selection must be revealed before regrouping")
    state.moveSelectedToTop = true
    state.context = "b"
    try await Task.sleep(for: .milliseconds(150))
    precondition(scroll.documentVisibleRect.contains(rowFrame(state.selected!)),
                 "Regrouping must follow the visible selection to its new position")
    // The same regroup must not yank the reader when the selection is offscreen.
    position(420)
    try await Task.sleep(for: .milliseconds(100))
    precondition(!scroll.documentVisibleRect.contains(rowFrame(state.selected!)), "Fixture must start from an offscreen selection")
    let parked = scroll.documentVisibleRect
    state.moveSelectedToTop = false
    state.context = "c"
    try await Task.sleep(for: .milliseconds(150))
    precondition(scroll.documentVisibleRect.minY == parked.minY,
                 "Regrouping must not reveal an offscreen selection")
    print("PASS: actual sidebar clicks preserve position, external selections reveal minimally, background updates preserve browsing position, regrouping follows only visible selections")
}
