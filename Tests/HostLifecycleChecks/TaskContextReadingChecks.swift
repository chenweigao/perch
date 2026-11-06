import AppKit
import SwiftUI
import WorkbenchCore

@MainActor func checkTaskContextReadingPositions() async throws {
    let controller = TaskContextWindowController()
    let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "Reading fixture", destination: "")
    let a = SessionReference(hostID: host.id, terminalID: "reading-a", kind: .claude)
    let b = SessionReference(hostID: host.id, terminalID: "reading-b", kind: .claude)
    let reading = controller.readingState(for: a)
    reading.allFiles = true; reading.completedTasks = true
    precondition(controller.readingState(for: a) === reading)
    for other in [b, SessionReference(hostID: UUID(), terminalID: a.terminalID, kind: a.kind),
                  SessionReference(hostID: a.hostID, terminalID: a.terminalID, kind: .codex)] {
        precondition(controller.readingState(for: other) !== reading)
        precondition(!controller.readingState(for: other).allFiles)
    }
    reading.files.activate(host: host.id, cwd: "/tmp")
    reading.files.select("/tmp/report.md", source: a)
    reading.files.offsetRecorder()(480)
    let recreated = RemoteFileBrowser(documents: reading.files)
    recreated.configure(host: host, cwd: "/tmp")
    precondition(recreated.documents.current?.offset == 480 && recreated.documents.current?.source == a,
                 "Recreating a page must retain its session's file position")
    recreated.cancel()
    let otherFiles = controller.readingState(for: b).files
    otherFiles.activate(host: host.id, cwd: "/tmp")
    otherFiles.select("/tmp/report.md", source: b)
    precondition(otherFiles.current?.offset == 0, "Same host, directory and path must not share task reading positions")

    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 360),
                          styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil); window.contentView = nil }
    func scrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView).first
    }
    func mount(_ state: TaskContextReadingState, rows: Int = 60) async throws -> NSScrollView {
        window.contentView = NSHostingView(rootView:
            TaskContextScrollView(reading: state, onScrolled: { _ in }) {
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in Text("任务文件 \(row)").frame(height: 36) }
                }.frame(maxWidth: .infinity)
            })
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<80 where scrollView(window.contentView!) == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        return scrollView(window.contentView!)!
    }
    func expect(_ scroll: NSScrollView, offset: CGFloat) async throws {
        for _ in 0..<80 where abs(scroll.contentView.bounds.origin.y - offset) > 2 {
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(abs(scroll.contentView.bounds.origin.y - offset) <= 2,
                     "Expected overview offset \(offset), got \(scroll.contentView.bounds.origin.y)")
    }
    let first = try await mount(reading)
    first.contentView.scroll(to: NSPoint(x: 0, y: 600)); first.reflectScrolledClipView(first.contentView)
    for _ in 0..<80 where reading.overviewOffset < 590 { try await Task.sleep(for: .milliseconds(25)) }
    precondition(abs(reading.overviewOffset - 600) <= 2)
    window.contentView = NSView()
    try await expect(mount(reading), offset: 600)
    try await expect(mount(controller.readingState(for: b)), offset: 0)
    try await expect(mount(reading), offset: 600)
    precondition(reading.allFiles && reading.completedTasks, "Expanded sections must survive the round trip")
    try await expect(mount(reading, rows: 2), offset: 0)
    print("PASS: native inspector overview remount, session isolation, expansion memory and shorter-content clamp")
}
