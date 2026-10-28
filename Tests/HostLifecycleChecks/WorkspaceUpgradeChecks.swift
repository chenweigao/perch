import AppKit
import SwiftUI
import WorkbenchCore

@MainActor func checkWorkspaceUpgradeUI() async throws {
    let domain = Bundle.main.bundleIdentifier!
    UserDefaults.standard.removePersistentDomain(forName: domain)
    AppLanguage.applyToSystem(.zhHans)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-workspace-ui-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "Local fixture", destination: "")
    let a = root.appendingPathComponent("a.swift"), b = root.appendingPathComponent("report.md")
    try "let value = 42\n// find me\n".write(to: a, atomically: true, encoding: .utf8)
    try "# Report\n\nFixture result".write(to: b, atomically: true, encoding: .utf8)
    let browser = RemoteFileBrowser()
    browser.configure(host: host, cwd: root.path)
    browser.open(a.path)
    let stale = browser.fileRequest!
    browser.open(b.path)
    await browser.loadFile(stale)
    precondition(browser.content == nil && browser.loading, "A superseded response cannot publish")
    await browser.loadFile(browser.fileRequest!)
    precondition(browser.path == b.path && browser.documents.selected == b.path && !browser.loading)
    browser.open(a.path)
    await browser.loadFile(browser.fileRequest!)
    browser.open(b.path)
    let closing = browser.fileRequest!
    browser.closeFile(b.path)
    await browser.loadFile(closing)
    precondition(browser.path == a.path && browser.content == nil && browser.loading,
                 "Closing a pending tab must discard its late response")
    await browser.loadFile(browser.fileRequest!)
    browser.open(b.path); await browser.loadFile(browser.fileRequest!)
    browser.open(a.path); await browser.loadFile(browser.fileRequest!)
    let recorder = browser.documents.offsetRecorder()
    recorder(123)
    browser.documents.setReading(false)
    let restored = FileWorkspaceState()
    restored.activate(host: host.id, cwd: root.path)
    precondition(restored.current?.path == a.path && restored.current?.offset == 123 && restored.current?.reading == false)
    browser.configure(host: host, cwd: root.appendingPathComponent("other").path)
    recorder(999)
    precondition(browser.documents.tabs.isEmpty, "Late offset callbacks cannot contaminate a different project")

    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    browser.configure(host: host, cwd: root.path)
    browser.open(a.path)
    window.contentView = NSHostingView(rootView: RemoteFilePanel(browser: browser, onClose: {}))
    window.makeKeyAndOrderFront(nil)
    for _ in 0..<100 where browser.loading { try await Task.sleep(for: .milliseconds(20)) }
    precondition(!browser.loading && browser.error == nil, "Mounting the production panel must perform its page-bound read")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for width: CGFloat in [720, 360] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.setContentSize(NSSize(width: width, height: 600)); window.appearance = NSAppearance(named: appearance)
            browser.findQuery = "value"
            try await Task.sleep(for: .milliseconds(100))
            precondition(descendants(window.contentView!).compactMap { $0 as? NSTextView }.contains { $0.string.contains("let value = 42") })
        }
    }
    browser.closeFile(a.path)
    precondition(browser.fileRequest?.path == b.path)
    browser.cancel()

    let model = WorkbenchModel()
    defer { model.shutdown() }
    let reference = SessionReference(hostID: host.id, terminalID: "fixture", kind: .codex)
    let item = WorkspaceSession(reference: reference, title: "Verify workspace reading", directory: root.path,
                                hostName: host.name, detail: "Inspecting the latest report", online: true,
                                section: .running, canMarkReviewed: false, updatedAt: 100)
    model.catalog.replace([item])
    model.toggleFollow(reference)
    precondition(model.workspace.followedSessions.contains(reference))
    let location = SidebarProjectLocation(hostID: host.id, directory: root.path, hostName: host.name)
    var brief = ProjectBrief(); brief.goal = "Complete the project"; brief.nextStep = "Review the report"
    model.updateBrief(brief, for: location)
    var idle = FollowUpRule(session: item, trigger: .inactivity, dueAt: Date(), idleMinutes: 5, prompt: "", now: Date(timeIntervalSince1970: 100))
    model.addFollowUp(idle)
    model.processFollowUps(now: Date(timeIntervalSince1970: 500))
    precondition(model.workspace.followUps.last?.status == .notified && model.followUpNotices.count == 1)
    model.processFollowUps(now: Date(timeIntervalSince1970: 600))
    precondition(model.followUpNotices.count == 1, "Inactivity alerts are one-shot")
    idle.id = UUID(); idle.status = .needsReview
    model.addFollowUp(idle); model.cancelFollowUp(idle.id)
    precondition(model.workspace.followUps.last?.status == .cancelled)
    model.workspace.companionDrafts[reference.id] = "Preserved draft"
    try model.persistFollowUpIntent()

    var openedMain = false
    let companion = CompanionWindowController.shared
    companion.configure(model: model, openMain: { openedMain = true })
    companion.show()
    let floating = NSApp.windows.first { $0 is NSPanel && $0.title == L("Perch · 任务浮窗") }
    precondition(floating?.level == .floating && floating?.isVisible == true)
    companion.toggle(); precondition(floating?.isVisible == false)
    companion.toggle(); precondition(floating?.isVisible == true)
    companion.showMain(); precondition(openedMain)
    companion.shutdown()

    let views: [(String, AnyView, CGFloat, CGFloat)] = [
        ("companion", AnyView(CompanionView(model: model, openMain: {})), 360, 560),
        ("project", AnyView(ProjectWorkbenchSheet(model: model, location: location)), 720, 700),
        ("search", AnyView(UnifiedSearchView(model: model)), 740, 620),
        ("followups", AnyView(FollowUpManager(model: model)), 660, 700),
        ("delivery", AnyView(DeliveryEditor(model: model, initial: DeliveryRecord(project: location, title: "Workspace upgrade"))), 640, 720)
    ]
    for (_, view, width, height) in views {
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "zh-Hans")))
        window.setContentSize(NSSize(width: width, height: height))
        try await Task.sleep(for: .milliseconds(200))
        precondition(window.contentView!.bounds.width >= width)
    }
    print("PASS: file task/identity and reading restoration, 720/360 light/dark source views, one-shot inactivity and five native workspace surfaces")
}
