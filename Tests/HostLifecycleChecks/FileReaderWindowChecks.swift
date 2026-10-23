import AppKit
import SwiftUI
import WorkbenchCore

@MainActor func checkFileReaderWindow() async throws {
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    AppLanguage.applyToSystem(.zhHans)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-file-reader-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Example.swift")
    let report = root.appendingPathComponent("Report.md")
    try ("let value = \"" + String(repeating: "long source ", count: 160) + "\"\n").write(to: file, atomically: true, encoding: .utf8)
    try "# Report\n\nA separate reader keeps the conversation visible.\n".write(to: report, atomically: true, encoding: .utf8)
    let model = WorkbenchModel()
    defer { model.shutdown() }
    model.fileBrowser.configure(host: SSHHost(id: ExecutionEnvironment.localHostID, name: "Local fixture", destination: ""), cwd: root.path)
    model.fileBrowser.open(file.path)
    model.showFileViewer = true
    model.fileWindow.show(model: model)
    let window = model.fileWindow.window!
    precondition(window.isVisible && window.styleMask.contains(.resizable))
    precondition(window.contentMinSize == NSSize(width: 480, height: 320))
    func settle() async throws {
        for _ in 0..<100 where model.fileBrowser.loading { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(120))
        precondition(!model.fileBrowser.loading && model.fileBrowser.error == nil)
    }
    try await settle()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func sourceScroll() -> NSScrollView {
        descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "PerchReviewSource" }!.enclosingScrollView!
    }
    let original = sourceScroll()
    let source = original.documentView as! NSTextView
    source.setSelectedRange(NSRange(location: 4, length: 5))
    for width: CGFloat in [480, 720, 1100] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(100))
            let host = window.contentView!, scroll = sourceScroll()
            let frame = scroll.convert(scroll.bounds, to: host)
            let header = host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
            precondition(scroll === original && source.selectedRange() == NSRange(location: 4, length: 5),
                         "Resizing must preserve the mounted source reader and selection")
            precondition(abs(frame.width - width) < 1 && abs(frame.maxX - host.bounds.maxX) < 1,
                         "Long source lines must scroll within the window: \(frame)")
            precondition(header < 100, "Default file chrome must stay under 100pt, got \(header)")
        }
    }
    model.fileBrowser.open(report.path)
    try await settle()
    precondition(model.fileBrowser.documents.tabs.count == 2 && model.fileBrowser.previewKind == .markdown)
    model.fileBrowser.open(file.path)
    try await settle()
    precondition(model.fileBrowser.documents.selected == file.path)
    // AppKit constrains restored frames to the screen; CI has a 1024pt display.
    // Verify persistence with a non-default size that fits, after the wide layout checks.
    window.setContentSize(NSSize(width: 720, height: 500))
    window.center()
    try await Task.sleep(for: .milliseconds(100))
    model.fileWindow.close()
    precondition(model.fileWindow.window == nil && !model.showFileViewer && model.fileBrowser.fileRequest == nil,
                 "Closing the native reader must cancel its page read and clear presentation state")
    model.showFileViewer = true
    model.fileBrowser.open(file.path)
    model.fileWindow.show(model: model)
    try await settle()
    precondition(model.fileBrowser.documents.tabs.count == 2, "Closing and reopening must preserve file tabs")
    precondition(abs(model.fileWindow.window!.contentView!.bounds.width - 720) < 1,
                 "The native reader must restore its resized width, got \(model.fileWindow.window!.contentView!.bounds.width)")
    print("PASS: native file window, 480/720/1100 light/dark widths, chrome <100pt, selection, tabs, close cancellation and restored frame")
    fflush(stdout)
    if CommandLine.arguments.contains("preview") {
        model.fileWindow.window?.setContentSize(NSSize(width: 960, height: 640))
        try await Task.sleep(for: .seconds(120))
    }
}
