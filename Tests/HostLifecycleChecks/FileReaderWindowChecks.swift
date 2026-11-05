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
    precondition(abs(window.contentView!.bounds.width - 960) < 1,
                 "Initial content must not shrink the native reader's default width")
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
    // Batch close: a surviving current read stays mounted; a closed one moves
    // the reader to the surviving selection; closing all empties the strip.
    let mounted = model.fileBrowser.completedFileReadID
    model.fileBrowser.closeOtherFiles(file.path)
    precondition(model.fileBrowser.documents.tabs.map(\.path) == [file.path] && model.fileBrowser.path == file.path
        && model.fileBrowser.completedFileReadID == mounted,
                 "Closing other tabs keeps the surviving read mounted")
    model.fileBrowser.open(report.path)
    try await settle()
    precondition(model.fileBrowser.documents.tabs.map(\.path) == [file.path, report.path])
    model.fileBrowser.closeFilesAfter(file.path)
    try await settle()
    precondition(model.fileBrowser.documents.tabs.map(\.path) == [file.path] && model.fileBrowser.path == file.path,
                 "Closing tabs after an earlier tab moves the displaced reader to it")
    model.fileBrowser.open(report.path)
    try await settle()
    model.fileBrowser.closeAllFiles()
    precondition(model.fileBrowser.documents.tabs.isEmpty && model.fileBrowser.path.isEmpty && model.fileBrowser.fileRequest == nil,
                 "Closing all tabs empties the strip and cancels the mounted read")
    let titled = [FileReadingTab(path: "/a/main.swift"), FileReadingTab(path: "/b/main.swift"), FileReadingTab(path: "/a/Other.swift")]
    precondition(FileTabStrip.title(for: titled[0], in: titled) == "a/main.swift"
        && FileTabStrip.title(for: titled[1], in: titled) == "b/main.swift"
        && FileTabStrip.title(for: titled[2], in: titled) == "Other.swift",
        "Duplicate tab names are disambiguated by parent folder")
    let isolated = FileWorkspaceState(defaults: .standard)
    let hostID = UUID()
    isolated.activate(host: hostID, cwd: "/p")
    for path in ["/p/one.swift", "/p/two.swift", "/p/three.swift", "/p/four.swift"] { isolated.select(path) }
    precondition(isolated.closeAfter("/p/two.swift") == "/p/two.swift" && isolated.tabs.map(\.path) == ["/p/one.swift", "/p/two.swift"],
                 "Closing after a tab moves the selection back to it")
    precondition(isolated.closeAfter("/p/two.swift") == "/p/two.swift" && isolated.tabs.count == 2,
                 "Closing after the last tab is a no-op")
    isolated.select("/p/three.swift"); isolated.select("/p/four.swift")
    precondition(isolated.closeOthers(of: "/p/one.swift") == "/p/one.swift" && isolated.tabs.map(\.path) == ["/p/one.swift"])
    let restored = FileWorkspaceState(defaults: .standard)
    restored.activate(host: hostID, cwd: "/p")
    precondition(restored.tabs.map(\.path) == ["/p/one.swift"] && restored.selected == "/p/one.swift",
                 "Batch closes persist like single closes")
    isolated.closeAll()
    precondition(isolated.tabs.isEmpty && isolated.selected == nil)
    print("PASS: native file window, 480/720/1100 light/dark widths, chrome <100pt, selection, tabs, batch close, close cancellation and restored frame")
    fflush(stdout)
    if CommandLine.arguments.contains("preview") {
        model.fileWindow.window?.setContentSize(NSSize(width: 960, height: 640))
        try await Task.sleep(for: .seconds(120))
    }
}
