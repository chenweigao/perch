import AppKit
import SwiftUI
import WorkbenchCore

/// Real native controls and production routes; isolated local files and preferences only.
@MainActor func checkWorkflowPolish() async throws {
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    AppLanguage.applyToSystem(.zhHans)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-workflow-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Code.swift"), report = root.appendingPathComponent("Result.md")
    try "let first = 1\nlet second = 2\nlet third = 3\n".write(to: file, atomically: true, encoding: .utf8)
    try "# Result\n\nDone".write(to: report, atomically: true, encoding: .utf8)
    let model = WorkbenchModel()
    defer { model.fileWindow.close(); model.shutdown() }
    let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "Fixture", destination: "")
    model.connections = [HostConnection(host: host)]
    model.registerEnvironment(kimi: KimiConnection(host: host), native: NativeAgentConnection(host: host))
    // Drain the registration callbacks before installing the synthetic catalog.
    try await Task.sleep(for: .milliseconds(50))
    let first = WorkspaceSession(reference: SessionReference(hostID: host.id, terminalID: "first", kind: .codex),
        title: "First task", directory: root.path, hostName: host.name, detail: "", online: true, section: .other, canMarkReviewed: false)
    let second = WorkspaceSession(reference: SessionReference(hostID: host.id, terminalID: "second", kind: .codex),
        title: "Second task", directory: root.path, hostName: host.name, detail: "", online: true, section: .attention, canMarkReviewed: false)
    let offline = WorkspaceSession(reference: SessionReference(hostID: host.id, terminalID: "offline", kind: .codex),
        title: "Offline", directory: root.path, hostName: host.name, detail: "", online: false, section: .attention, canMarkReviewed: false)
    model.catalog.replace([first, offline, second])
    func capture(_ window: NSWindow, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["PERCH_WORKFLOW_CAPTURES"],
              let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
    let before = model.selectedReference
    model.openWorkspaceFile(GroupOutcome(title: "Code", link: "Code.swift", source: first.reference),
                            location: SidebarProjectLocation(hostID: host.id, directory: root.appendingPathComponent("different-project").path, hostName: host.name), line: 2)
    func settle() async throws {
        for _ in 0..<100 where model.fileBrowser.loading { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(120))
        precondition(!model.fileBrowser.loading && model.fileBrowser.error == nil)
    }
    try await settle()
    let reader = model.fileWindow.window!
    capture(reader, "file-light")
    precondition(model.selectedReference == before && model.fileBrowser.targetLine == 2 && model.fileBrowser.cwd == root.path)
    precondition(model.fileBrowser.documents.current?.source == first.reference)
    model.openOutcome(GroupOutcome(title: "Report", link: report.path, source: second.reference))
    try await settle()
    precondition(model.fileWindow.window === reader && model.fileBrowser.documents.tabs.count == 2)
    precondition(model.fileBrowser.documents.current?.source == second.reference)
    func key(_ window: NSWindow, _ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    precondition(reader.performKeyEquivalent(with: key(reader, "[", 33, [.command, .shift])))
    try await settle()
    precondition(model.fileBrowser.path == file.path && model.fileBrowser.documents.current?.source == first.reference)
    model.open(second)
    try await Task.sleep(for: .milliseconds(100))
    precondition(model.fileBrowser.path == file.path && model.fileBrowser.documents.current?.source == first.reference,
                 "Main conversation changes cannot retarget a file tab or its quote")
    model.stageArtifactFeedback("Quoted source", to: model.fileBrowser.documents.current!.source!)
    precondition(model.agentConnections(for: host.id)?.native.drafts[first.reference.terminalID]?.contains("Quoted source") == true)
    precondition(model.agentConnections(for: host.id)?.native.drafts[second.reference.terminalID]?.contains("Quoted source") != true)
    let restored = FileWorkspaceState(); restored.activate(host: host.id, cwd: root.path)
    precondition(restored.current?.source == first.reference, "Persisted tabs retain the quote destination")
    precondition(reader.performKeyEquivalent(with: key(reader, "w", 13, .command)))
    try await settle()
    precondition(reader.isVisible && model.fileBrowser.documents.tabs.count == 1 && model.fileBrowser.path == report.path)
    model.fileWindow.close()
    // A missing origin needs a choice; never silently use an unrelated selected conversation.
    model.openOutcome(GroupOutcome(title: "Unknown origin", link: file.path))
    precondition(model.pendingFileOutcome != nil)
    model.fileWindow.close()

    model.catalog.replace([first, offline, second])
    model.open(first)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 740, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    window.contentViewController = NSHostingController(rootView: UnifiedSearchView(model: model).background(Color(nsColor: .windowBackgroundColor)))
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(250))
    precondition((window.firstResponder as? NSTextView)?.isFieldEditor == true,
                 "Search must focus input: responder=\(String(describing: window.firstResponder)), key=\(window.isKeyWindow), active=\(NSApp.isActive)")
    window.appearance = NSAppearance(named: .aqua)
    window.displayIfNeeded(); capture(window, "search-light")
    window.sendEvent(key(window, String(UnicodeScalar(NSDownArrowFunctionKey)!), 125))
    try await Task.sleep(for: .milliseconds(100))
    window.sendEvent(key(window, "\r", 36))
    try await Task.sleep(for: .milliseconds(150))
    precondition(model.selectedReference == second.reference, "Down + Return opens the next available result, skipping offline rows")
    model.workspace.followedSessions = [first.reference, second.reference, offline.reference]
    for (name, view, size) in [
        ("project", AnyView(ProjectWorkbenchSheet(model: model, location: SidebarProjectLocation(hostID: host.id, directory: root.path, hostName: host.name))), NSSize(width: 720, height: 700)),
        ("companion", AnyView(CompanionView(model: model, openMain: {})), NSSize(width: 340, height: 560))
    ] {
        window.contentViewController = NSHostingController(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.setContentSize(size)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(200))
            window.displayIfNeeded(); capture(window, name + "-" + suffix)
        }
    }
    precondition(workspaceTaskPriority(second) < workspaceTaskPriority(first) && workspaceTaskPriority(first) < workspaceTaskPriority(offline))
    print("PASS: shared reader routes/line/tab/frame identity, per-tab quote persistence, main-selection isolation, close-tab and focused keyboard search")
}
