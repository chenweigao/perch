import AppKit
import SwiftUI
import WorkbenchCore

@MainActor func checkDocumentReadingUI() async throws {
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    AppLanguage.applyToSystem(.zhHans)
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-documents-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = root.appendingPathComponent("Report.md")
    let next = root.appendingPathComponent("sub/Next page.md")
    let paragraphs = (1...35).map { "## Chapter \($0)\n\n正文 \($0)：A useful finding with **clear evidence** and a next step.\n\n" }.joined()
    try ("# 项目方案\n\n[打开下一份文档](sub/Next%20page.md#结论) · [跳到章节](#chapter-20)\n\n![图示](diagram.png)\n\n" + paragraphs).write(to: report, atomically: true, encoding: .utf8)
    try "# 第二份文档\n\nNotes.\n\n## 结论\n\nA separate result.\n\n[返回](../Report.md)".write(to: next, atomically: true, encoding: .utf8)
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<80 { for x in 0..<240 { image.setColor(NSColor(calibratedRed: 0.1, green: 0.6, blue: 0.6, alpha: 1), atX: x, y: y) } }
    try image.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("diagram.png"))
    let model = WorkbenchModel()
    defer { model.fileWindow.close(); model.shutdown() }
    let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "Documents fixture", destination: "")
    model.connections = [HostConnection(host: host)]
    model.registerEnvironment(kimi: KimiConnection(host: host), native: NativeAgentConnection(host: host))
    try await Task.sleep(for: .milliseconds(50))
    let first = WorkspaceSession(reference: SessionReference(hostID: host.id, terminalID: "doc-source", kind: .codex), title: "文档任务", directory: root.path, hostName: host.name, detail: "", online: true, section: .other, canMarkReviewed: false)
    let second = WorkspaceSession(reference: SessionReference(hostID: host.id, terminalID: "other-task", kind: .codex), title: "其他任务", directory: root.path, hostName: host.name, detail: "", online: true, section: .other, canMarkReviewed: false)
    model.catalog.replace([first, second])
    model.openOutcome(GroupOutcome(title: "方案", link: report.path, source: first.reference))
    let browser = model.fileBrowser, window = model.fileWindow.window!
    func settle() async throws {
        for _ in 0..<150 where browser.loading || browser.reading.document == nil { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(180))
        precondition(!browser.loading && browser.error == nil && browser.reading.document != nil)
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func texts() -> [ReplyTextView] { descendants(window.contentView!).compactMap { $0 as? ReplyTextView }.filter { !$0.string.isEmpty } }
    func capture(_ name: String, in target: NSWindow? = nil) {
        guard let folder = ProcessInfo.processInfo.environment["PERCH_DOCUMENT_CAPTURES"], let view = (target ?? window).contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
    try await settle()
    precondition(browser.reading.document!.outline.count == 36)
    precondition(browser.documents.current?.reading == true)
    precondition(browser.modifiedAt != nil && model.workspace.documents.first?.modifiedAt != nil)
    precondition(model.workspace.documents.first?.source == first.reference)
    model.documentLibraryActions!.togglePin()
    precondition(model.workspace.documents.first?.pinned == true)
    let readerText = texts().first { $0.string.contains("打开下一份文档") }!
    let link = readerText.textStorage!.attribute(.link, at: 0, effectiveRange: nil) as! URL
    precondition(link.scheme == "perch-document", "Relative links must survive attributed rendering")
    precondition(readerText.delegate!.textView!(readerText, clickedOnLink: link, at: 0))
    try await settle()
    precondition(browser.path == next.path && browser.documentAnchor == "结论")
    precondition(browser.documents.current?.source == first.reference)
    browser.navigateHistory(-1)
    try await settle()
    precondition(browser.path == report.path && browser.documents.canGoForward)
    browser.navigateDocument("#chapter-20")
    try await Task.sleep(for: .milliseconds(250))
    let chapter = texts().first { $0.string == "Chapter 20" }!
    precondition(chapter.enclosingScrollView!.contentView.bounds.origin.y > 500)
    let offset = chapter.enclosingScrollView!.contentView.bounds.origin.y
    browser.navigateDocument("sub/Next%20page.md")
    try await settle()
    precondition((browser.documents.tabs.first { $0.path == report.path }?.offset ?? 0) > 500)
    browser.navigateHistory(-1)
    try await settle()
    precondition(texts().contains { $0.enclosingScrollView!.contentView.bounds.origin.y > 500 }, "Back must restore the report's reading position")
    print("Document restored offset from \(offset)")
    browser.findQuery = "正文 30"
    try await Task.sleep(for: .milliseconds(250))
    precondition(browser.documents.current?.reading == true && browser.reading.document!.matchingSections(browser.findQuery).count == 1)
    let found = texts().first { $0.string.contains("正文 30") }!
    let range = (found.string as NSString).range(of: "正文 30")
    precondition(found.textStorage!.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil)
    found.setSelectedRange(range)
    precondition(found.extraMenuItems?().first?.isEnabled == true)
    UserDefaults.standard.set(20.0, forKey: "perch.document.fontSize")
    try await Task.sleep(for: .milliseconds(200))
    let resized = texts().first { $0.string.contains("正文 30") }!
    precondition(abs((resized.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize - 20) < 0.1)
    model.open(second)
    precondition(browser.documents.current?.source == first.reference)
    let item = resized.extraMenuItems!().first!
    precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
    try await Task.sleep(for: .milliseconds(150))
    precondition(window.attachedSheet != nil, "Rendered selection opens a feedback draft")
    if let sheet = window.attachedSheet {
        sheet.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        guard let editor = sheet.firstResponder as? NSTextView else { fatalError("Feedback input must be focused") }
        editor.insertText("请补充验证依据", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(120))
        sheet.displayIfNeeded(); capture("document-feedback", in: sheet)
        let submit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        precondition(sheet.performKeyEquivalent(with: submit))
        try await Task.sleep(for: .milliseconds(180))
        let draft = model.agentConnections(for: host.id)?.native.drafts[first.reference.terminalID] ?? ""
        precondition(draft.contains("请补充验证依据") && draft.contains(report.path) && draft.contains("Chapter 30") && draft.contains("正文 30"))
        precondition(model.agentConnections(for: host.id)?.native.drafts[second.reference.terminalID]?.contains("请补充验证依据") != true)
        precondition(window.attachedSheet == nil)
    }
    browser.findQuery = ""
    browser.navigateDocument("#")
    UserDefaults.standard.set(16.0, forKey: "perch.document.fontSize")
    try await Task.sleep(for: .milliseconds(800))
    for width: CGFloat in [480, 720, 1100] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.setContentSize(NSSize(width: width, height: 640)); window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(180))
            precondition(abs(window.contentView!.bounds.width - width) < 1)
            capture("document-\(Int(width))-\(appearance == .aqua ? "light" : "dark")")
        }
    }
    browser.navigateDocument("missing.md")
    for _ in 0..<100 where browser.loading { try await Task.sleep(for: .milliseconds(20)) }
    precondition(browser.content == .missing && browser.documents.canGoBack)
    browser.navigateHistory(-1); try await settle()
    precondition(browser.path == report.path && browser.documents.current?.source == first.reference)
    model.fileWindow.close()
    let saved = try JSONDecoder().decode(LocalWorkspace.self, from: JSONEncoder().encode(model.workspace))
    precondition(saved.documents.contains { $0.path == report.path && $0.pinned })
    model.openProjectDocument(saved.documents.first { $0.path == report.path }!)
    try await settle()
    precondition(browser.path == report.path && browser.documents.current?.source == first.reference)
    browser.navigateDocument("javascript:alert(1)")
    precondition(browser.error == nil && browser.reading.notice != nil && browser.path == report.path)
    let cancelled = Task { await DocumentParser.shared.parse("# Cancelled") }
    cancelled.cancel(); let cancelledResult = await cancelled.value; precondition(cancelledResult == nil)
    let projectWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    projectWindow.isReleasedWhenClosed = false
    projectWindow.contentViewController = NSHostingController(rootView: ProjectWorkbenchSheet(model: model, location: saved.documents.first!.project).background(Color(nsColor: .windowBackgroundColor)))
    projectWindow.orderFront(nil)
    try await Task.sleep(for: .milliseconds(200))
    capture("project-documents", in: projectWindow); projectWindow.close()
    let isolated = FileWorkspaceState(defaults: .standard)
    isolated.activate(host: UUID(), cwd: "/project")
    isolated.select("/project/a.md"); isolated.select("/project/b.md")
    precondition(isolated.historyEntry(-1)?.path == "/project/a.md")
    isolated.select("/project/c.md"); precondition(!isolated.canGoForward)
    isolated.activate(host: UUID(), cwd: "/project"); precondition(!isolated.canGoBack)
    isolated.select("/project/a.md", source: first.reference)
    let closedRecorder = isolated.offsetRecorder()
    isolated.select("/project/b.md", source: second.reference)
    _ = isolated.close("/project/a.md")
    closedRecorder(321)
    let closed = isolated.historyEntry(-1)!
    precondition(closed.path == "/project/a.md" && closed.source == first.reference && closed.offset == 321)
    isolated.restoreVisit(closed); isolated.select(closed.path, source: closed.source)
    precondition(isolated.current?.offset == 321 && isolated.current?.source == first.reference)
    print("Document reading UI passed: relative links, anchors, search, typography, selection, positions, library and narrow/light/dark windows")
}
