import AppKit
import SwiftUI
import WorkbenchCore

/// The production workspace with deterministic sessions and a disposable Git
/// repository. No saved environments, network connections, or real drafts.
@MainActor func checkNativeDesign() async throws {
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    AppLanguage.applyToSystem(.zhHans)
    let persistentPreview = Bundle.main.object(forInfoDictionaryKey: "PerchDesignPreview") as? Bool == true
    NSApp.setActivationPolicy(persistentPreview ? .regular : .accessory)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-design-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }
    try git(["init", "-q"])
    let before = "func restoreSession(id: String) {\n    restoreMessages(for: id)\n}\n"
    let after = "func restoreSession(id: String) {\n    let state = sessionStates[id]\n    restoreDraft(for: id)\n    restoreMessages(for: id)\n}\n"
    try before.write(to: root.appendingPathComponent("SessionState.swift"), atomically: true, encoding: .utf8)
    try "// Session switching checks\n".write(to: root.appendingPathComponent("SwitchingChecks.swift"), atomically: true, encoding: .utf8)
    try git(["add", "."])
    try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid", "commit", "-qm", "Fixture"])
    try after.write(to: root.appendingPathComponent("SessionState.swift"), atomically: true, encoding: .utf8)
    try "// Session switching checks\n// Preserve the selected draft\n".write(to: root.appendingPathComponent("SwitchingChecks.swift"), atomically: true, encoding: .utf8)

    let titles = ["Perch 界面苹果风格设计优化", "AWP 持续探索｜诊断、比较与规模性能 [ca1adc03]", "整理验收报告",
                  "DeepSeek-V4.1-Flash 跨机缓存加载慢", "长文本阅读体验", "随手记与问题收集"]
    let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "Mac mini", destination: "")
    var running = true
    var revision = 1
    var abortedTurns: [String] = []
    var selectedModels: [Int: String] = [:]
    var selectedEfforts: [Int: String] = [:]
    let modelOptions: [[String: Any]] = [
        ["id": "gpt-5.4", "name": "GPT-5.4", "provider": "openai", "agent": "codex",
         "thinking": ["low", "medium", "high", "xhigh"], "defaultThinking": "high"],
        ["id": "gpt-5.4-mini", "name": "GPT-5.4 mini", "provider": "openai", "agent": "codex",
         "thinking": ["low", "medium", "high"], "defaultThinking": "medium"],
    ]
    func summary(_ index: Int) -> [String: Any] {
        ["id": "design-\(index)", "provider": "codex", "title": titles[index], "cwd": root.path,
         "busy": index == 0 && running, "archived": false, "updated": Date().timeIntervalSince1970 - Double(index * 120),
         "completed": 1, "pending": index == 2 ? 1 : 0,
         "model": selectedModels[index] ?? "gpt-5.4", "thinking": selectedEfforts[index] ?? "high",
         "turnId": "design-turn-\(index)",
         "turnState": running ? "running" : "stopped"]
    }
    let connection = NativeAgentConnection(host: host) { path, body in
        if path == "/models" {
            return try JSONSerialization.data(withJSONObject: ["models": modelOptions])
        }
        if path.hasSuffix("/abort") {
            abortedTurns.append(body.flatMap { $0["turnId"].string } ?? "")
            running = false
            revision += 1
            return Data("{}".utf8)
        }
        if path == "/sessions" {
            return try JSONSerialization.data(withJSONObject: ["sessions": titles.indices.map(summary)])
        }
        let index = Int(path.components(separatedBy: "design-").last?.prefix(1) ?? "0") ?? 0
        if path.hasSuffix("/model") {
            selectedModels[index] = body?["model"].string
            revision += 1
            return Data("{}".utf8)
        }
        if path.hasSuffix("/thinking") {
            selectedEfforts[index] = body?["level"].string
            revision += 1
            return Data("{}".utf8)
        }
        var data = summary(index)
        data["revision"] = revision
        data["messages"] = [
            ["id": "question", "role": "user", "created_at": "", "content": [["type": "text", "text": "检查快速切换会话时的状态隔离，给出最小修改。"]]],
            ["id": "answer", "role": "assistant", "created_at": "", "content": [["type": "text", "text": "已检查会话加载与草稿恢复逻辑。\n\n### 初步发现\n\n- 加载状态应随会话独立保存。\n- 草稿与滚动位置需要分别恢复。\n\n接下来会核对快速切换时的请求取消与状态恢复。"]]]
        ]
        data["interactions"] = []
        return try JSONSerialization.data(withJSONObject: data)
    }
    UserDefaults.standard.set(try JSONEncoder().encode([host]), forKey: "hosts")
    let model = WorkbenchModel()
    defer { model.shutdown() }
    model.connections = [HostConnection(host: host)]
    model.registerEnvironment(kimi: KimiConnection(host: host), native: connection)
    try await connection.refresh()
    try await Task.sleep(for: .milliseconds(80))
    let first = model.allSessions.first { $0.reference.terminalID == "design-0" }!
    let pin = model.allSessions.first { $0.reference.terminalID == "design-1" }!
    if !model.workspace.starred.contains(pin.reference) { model.toggleStar(pin.reference) }
    model.open(first)
    try await Task.sleep(for: .milliseconds(150))
    let window = NativeDesignWindow(contentRect: NSRect(x: 30, y: 40, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Perch · 原生设计对照"
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    defer { window.close(); window.contentViewController = nil }
    let hosting = NSHostingController(rootView: WorkbenchView(model: model).environment(\.locale, Locale(identifier: "zh-Hans")))
    hosting.sizingOptions = []
    window.contentViewController = hosting
    window.setContentSize(NSSize(width: 1440, height: 900))
    window.makeKeyAndOrderFront(nil)
    // The 1440 × 900 design geometry must not depend on the display: CI screens
    // are smaller, and AppKit would otherwise shrink the window to fit them.
    window.setFrame(NSRect(origin: window.frame.origin, size: window.frameRect(forContentRect:
        NSRect(origin: .zero, size: NSSize(width: 1440, height: 900))).size), display: true)
    let keepAlive = Task { @MainActor in
        while !Task.isCancelled {
            try await connection.poll()
            try await Task.sleep(for: .seconds(2))
        }
    }
    defer { keepAlive.cancel() }
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .seconds(1))
    precondition(window.contentView!.bounds.width >= 1000, "Design checks require a real window-sized viewport")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let draft = descendants(window.contentView!).compactMap { $0 as? DraftTextView }.first!
    let reply = descendants(window.contentView!).compactMap { $0 as? ReplyTextView }.first { $0.string.contains("初步发现") }!
    func splitController(_ view: NSView) -> WorkbenchSplitController? {
        var responder: NSResponder? = view
        while let current = responder {
            if let split = current as? WorkbenchSplitController { return split }
            if let controller = current as? NSViewController {
                var parent = controller.parent
                while let candidate = parent {
                    if let split = candidate as? WorkbenchSplitController { return split }
                    parent = candidate.parent
                }
            }
            responder = current.nextResponder
        }
        return nil
    }
    let split = splitController(draft)!
    precondition(split.floatingInspectorView == nil, "Do not create a hidden inspector hosting tree at launch")
    precondition(split.splitViewItems.count == 1, "Floating panels must not become split columns")
    model.taskContextWindow.showPage(.task, model: model)
    try await Task.sleep(for: .milliseconds(400))
    window.contentView!.layoutSubtreeIfNeeded()
    precondition(split.floatingInspectorView!.bounds.height < 120,
                 "The first opening of an initially hidden empty inspector must use its measured content height")
    model.taskContextWindow.showPage(.changes, model: model)
    try await Task.sleep(for: .milliseconds(500))
    window.contentView!.layoutSubtreeIfNeeded()
    let inspector = split.floatingInspectorView!
    let inspectorFrame = inspector.convert(inspector.bounds, to: window.contentView)
    let card = split.detailCardView!
    let cardFrame = card.convert(card.bounds, to: window.contentView)
    let draftFrame = draft.convert(draft.bounds, to: window.contentView)
    let replyFrame = reply.convert(reply.bounds, to: window.contentView)
    func distanceFromTop(_ frame: NSRect) -> CGFloat {
        window.contentView!.isFlipped ? frame.minY : window.contentView!.bounds.maxY - frame.maxY
    }
    let backdrop = split.windowBackdropView!
    let backdropFrame = backdrop.convert(backdrop.bounds, to: window.contentView)
    let windowCorner = WorkbenchWindowBackdropView.windowCornerRadius(of: window)
    precondition(!window.isOpaque && backdrop.fixedCornerRadius == nil && abs(backdrop.glassCornerRadius - windowCorner) < 0.5 &&
                 abs(backdropFrame.width - window.contentView!.bounds.width) < 1 &&
                 abs(backdropFrame.height - window.contentView!.bounds.height) < 1,
                 "The window must be one Liquid Glass backdrop shaped like the window: backdrop=\(backdropFrame), corner=\(backdrop.glassCornerRadius), window corner=\(windowCorner), opaque=\(window.isOpaque)")
    precondition(split.sidebarOverlayBackdropView?.fixedCornerRadius == WorkbenchTheme.Radius.panel &&
                 split.sidebarOverlayBackdropView?.isHidden == true,
                 "Wide windows draw navigation straight on the window glass; only the narrow overlay gets its own glass panel")
    precondition(abs(distanceFromTop(cardFrame) - WorkspaceLayoutMetrics.contentTopInset) < 1 &&
                 distanceFromTop(inspectorFrame) > distanceFromTop(cardFrame) &&
                 inspectorFrame.height <= WorkspaceLayoutMetrics.inspectorMaximumHeight + 1,
                 "The reading sheet must float below the toolbar, with a shorter inset inspector")
    precondition(inspectorFrame.height < 500,
                 "A short diff must size to its contents rather than fill a 680pt inspector")
    precondition(connection.models(for: .codex).count == 2 &&
                 connection.model(for: connection.snapshot!)?.supportsThinking == true,
                 "The design fixture must include a real model catalog and adjustable reasoning controls")
    precondition(cardFrame.maxX + WorkspaceLayoutMetrics.sidebarGap <= inspectorFrame.minX + 1,
                 "The floating inspector must have its own lane and visible gap: card=\(cardFrame), inspector=\(inspectorFrame)")
    precondition(replyFrame.maxX < inspectorFrame.minX && draftFrame.maxX < inspectorFrame.minX,
                 "The inspector must not cover the reply or composer/send lane: reply=\(replyFrame), composer=\(draftFrame), inspector=\(inspectorFrame)")
    let draftX = draft.convert(draft.bounds, to: window.contentView).minX
    let replyX = reply.convert(reply.bounds, to: window.contentView).minX
    precondition(abs(draftX - replyX) < 2, "Composer and reply must share the reading rail: draft=\(draftX), reply=\(replyX)")
    let title = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "WorkbenchTitle" }!.view!
    let titleX = title.convert(title.bounds, to: window.contentView).minX
    precondition(abs(titleX - cardFrame.minX - WorkbenchTheme.Reading.inset) < 2,
                 "The toolbar title stays anchored to the pane while the reading column centers")
    let toolbarActions = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "WorkbenchActions" }!.view!
    let actionsRight = toolbarActions.convert(toolbarActions.bounds, to: window.contentView).maxX
    precondition(window.contentView!.bounds.maxX - actionsRight < 40 && actionsRight > inspectorFrame.maxX - 40,
                 "Toolbar actions belong at the window edge, above the inspector")
    for changedTitle in ["短标题", "恢复后的长会话标题：检查工具栏对齐和右侧悬浮面板开合时的位置"] {
        model.rename(first, title: changedTitle)
        try await Task.sleep(for: .milliseconds(200))
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(abs(title.convert(title.bounds, to: window.contentView).minX - titleX) < 2,
                     "A changing session title must not move the toolbar's left alignment")
    }
    model.rename(first, title: first.title)
    try await Task.sleep(for: .milliseconds(200))
    precondition(abs(draftFrame.midX - cardFrame.midX) < 2 &&
                 abs(replyX - (cardFrame.midX - ReplyStyle.readingWidth / 2)) < 2,
                 "Reply and editor must center in the space remaining beside the inspector")
    // Exercise the sidebar toolbar action, including multiple changes before
    // AppKit has applied the preceding spacer constraint.
    let sidebarToggle = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "WorkbenchSidebarToggle" }!.view!
    for cycle in 0..<3 {
        split.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(200))
        window.contentView!.layoutSubtreeIfNeeded()
        let collapsedTitle = title.convert(title.bounds, to: window.contentView)
        let toggleFrame = sidebarToggle.convert(sidebarToggle.bounds, to: window.contentView)
        precondition(collapsedTitle.minX >= toggleFrame.maxX && collapsedTitle.minX < titleX - 100,
                     "Collapsed sidebar must place the title after window controls: cycle=\(cycle), title=\(collapsedTitle), toggle=\(toggleFrame)")
        split.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(200))
        window.contentView!.layoutSubtreeIfNeeded()
        let reopenedX = title.convert(title.bounds, to: window.contentView).minX
        precondition(abs(reopenedX - titleX) < 2,
                     "Reopening sidebar must restore title alignment without accumulated offsets: cycle=\(cycle), expected=\(titleX), actual=\(reopenedX)")
    }
    for _ in 0..<10 { split.toggleSidebar(nil) }
    try await Task.sleep(for: .milliseconds(200))
    window.contentView!.layoutSubtreeIfNeeded()
    precondition(abs(title.convert(title.bounds, to: window.contentView).minX - titleX) < 2 &&
                 abs(toolbarActions.convert(toolbarActions.bounds, to: window.contentView).maxX - actionsRight) < 2,
                 "Rapid sidebar toggles must not drift the title or trailing actions")
    print("PASS: sidebar close/reopen and rapid toggles preserve toolbar alignment")
    let savedDraft = draft.string
    model.taskContextWindow.embeddedVisible = false
    try await Task.sleep(for: .milliseconds(300))
    window.contentView!.layoutSubtreeIfNeeded()
    let closedCardFrame = card.convert(card.bounds, to: window.contentView)
    let closedDraftFrame = draft.convert(draft.bounds, to: window.contentView)
    precondition(abs(toolbarActions.convert(toolbarActions.bounds, to: window.contentView).maxX - actionsRight) < 2 &&
                 abs(title.convert(title.bounds, to: window.contentView).minX - titleX) < 2,
                 "Inspector toggles must not shift the toolbar title or actions")
    let closedReply = descendants(window.contentView!).compactMap { $0 as? ReplyTextView }.first { $0.string.contains("初步发现") }!
    let closedReplyFrame = closedReply.convert(closedReply.bounds, to: window.contentView)
    precondition(closedCardFrame.width > cardFrame.width + 300 &&
                 closedDraftFrame.minX > draftX + 100 &&
                 abs(closedDraftFrame.midX - closedCardFrame.midX) < 2 &&
                 abs(closedReplyFrame.minX - closedDraftFrame.minX) < 2 &&
                 draft.string == savedDraft,
                 "Closing the inspector must re-center the same composer and reply in the enlarged card")
    model.taskContextWindow.embeddedVisible = true
    try await Task.sleep(for: .milliseconds(300))
    window.contentView!.layoutSubtreeIfNeeded()
    precondition(abs(draft.convert(draft.bounds, to: window.contentView).minX - draftX) < 2 &&
                 descendants(window.contentView!).compactMap { $0 as? DraftTextView }.first === draft,
                 "Reopening the inspector must restore centering without replacing the editor")
    precondition(model.changesBrowser.gitStatus != nil && model.selectedReference == first.reference)
    model.taskContextWindow.page = .task
    try await Task.sleep(for: .milliseconds(500))
    window.contentView!.layoutSubtreeIfNeeded()
    let compactHeight = split.floatingInspectorView!.bounds.height
    precondition(compactHeight >= 64 && compactHeight < 240,
                 "An empty task inspector must shrink to a compact card: \(compactHeight)")
    model.taskContextWindow.page = .changes
    try await Task.sleep(for: .milliseconds(500))
    window.contentView!.layoutSubtreeIfNeeded()
    precondition(split.floatingInspectorView!.bounds.height > compactHeight + 80,
                 "Switching from an empty task to a diff must grow the same mounted panel")
    /// Distances from the window's top edge, so titlebar controls can be compared
    /// with the floating panels regardless of view flipping.
    func fromTop(_ view: NSView?) -> [String: Double] {
        guard let view, view.window === window else { return [:] }
        let rect = view.convert(view.bounds, to: nil)
        return ["minX": Double(rect.minX), "maxX": Double(rect.maxX),
                "top": Double(window.frame.height - rect.maxY), "midY": Double(window.frame.height - rect.midY),
                "height": Double(rect.height)]
    }
    let toggle = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "WorkbenchSidebarToggle" }?.view
    let chrome: [String: Any] = [
        "windowCornerRadius": Double(windowCorner),
        "titlebarHeight": Double(window.frame.height - window.contentLayoutRect.height),
        "closeButton": fromTop(window.standardWindowButton(.closeButton)), "sidebarToggle": fromTop(toggle),
        "title": fromTop(title), "actions": fromTop(toolbarActions),
        "sidebar": fromTop(split.floatingSidebarView), "conversation": fromTop(card),
    ]
    print("Native window chrome: \(chrome)")
    if let folder = ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"] {
        func rectangle(_ rect: NSRect) -> [String: Double] {
            ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
        }
        let geometry: [String: Any] = [
            "scope": "native window geometry; view-cache PNGs exclude composited Liquid Glass, *-composited-*.png include it",
            "window": rectangle(window.contentView!.bounds), "conversation": rectangle(cardFrame),
            "inspector": rectangle(inspectorFrame), "reply": rectangle(replyFrame), "composerText": rectangle(draftFrame),
            "inspectorClosedConversation": rectangle(closedCardFrame), "inspectorClosedComposerText": rectangle(closedDraftFrame),
            "titleX": Double(titleX), "sidebarWidth": Double(split.floatingSidebarWidth), "chrome": chrome,
        ]
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("native-layout.json"))
    }
    func capture(_ name: String) async throws {
        guard let folder = ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"],
              let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        // View caches omit what the window server composites: Liquid Glass and
        // shadows. System captures keep them where the session may record the
        // screen; elsewhere they fail or come back empty, which is not a defect.
        // Glass beyond the display has nothing to sample, so only whole windows.
        guard let screen = window.screen, screen.frame.contains(window.frame) else { return }
        let screenHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        let area = window.frame.insetBy(dx: -32, dy: -32)
        let region = [area.minX, screenHeight - area.maxY, area.width, area.height].map { String(Int($0.rounded())) }
        for (suffix, target) in [("window", ["-l", String(window.windowNumber)]), ("screen", ["-R", region.joined(separator: ",")])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-t", "png"] + target +
                [URL(fileURLWithPath: folder).appendingPathComponent("\(name)-composited-\(suffix).png").path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            for _ in 0..<50 where process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate() }
        }
    }
    try await capture("native-light")
    UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: AppAppearance.defaultsKey)
    try await Task.sleep(for: .milliseconds(200))
    precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                 "The appearance setting must reach the native window and every floating host")
    try await capture("native-dark")
    UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: AppAppearance.defaultsKey)
    try await Task.sleep(for: .milliseconds(200))
    precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    // On-screen frames: the largest window this display holds, then a narrow one
    // whose sidebar floats over the card on its own glass panel.
    let wideFrame = window.frame
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 20, dy: 20) ?? wideFrame
    func place(width: CGFloat) async throws {
        window.setFrame(NSRect(x: visible.minX, y: visible.minY, width: min(width, visible.width),
                               height: min(wideFrame.height, visible.height)), display: true)
        try await Task.sleep(for: .milliseconds(300))
        window.contentView!.layoutSubtreeIfNeeded()
    }
    try await place(width: wideFrame.width)
    try await capture("native-fit-light")
    UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: AppAppearance.defaultsKey)
    try await Task.sleep(for: .milliseconds(200))
    try await capture("native-fit-dark")
    UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: AppAppearance.defaultsKey)
    try await Task.sleep(for: .milliseconds(200))
    try await place(width: 900)
    precondition(split.isSidebarOverlayingContent && split.sidebarOverlayBackdropView?.isHidden == false,
                 "A narrow window must back the overlaying sidebar with its glass panel")
    try await capture("native-narrow-light")
    window.setFrame(wideFrame, display: true)
    try await Task.sleep(for: .milliseconds(300))
    window.contentView!.layoutSubtreeIfNeeded()
    print("PASS: production workspace, aligned reply/composer, independent changes inspector, native light and dark")
    if Bundle.main.object(forInfoDictionaryKey: "PerchDesignPreview") as? Bool == true && !CommandLine.arguments.contains("native-design") {
        let appearanceMenu = NativeDesignAppearanceMenu(window: window)
        while window.isVisible { try await Task.sleep(for: .seconds(1)) }
        withExtendedLifetime(appearanceMenu) {}
    } else if CommandLine.arguments.contains("preview") {
        print("Native design preview: \(Bundle.main.bundleURL.path)")
        try await Task.sleep(for: .seconds(120))
    } else {
        connection.stop()
        for _ in 0..<80 where connection.stops.phase(for: first.reference) != .stopped || connection.snapshot?.busy != false {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(connection.stops.phase(for: first.reference) == .stopped && connection.snapshot?.busy == false,
                     "The preview's stop control must reach the runtime-confirmed stopped state")
        precondition(abortedTurns == ["design-turn-0"], "Stop must target the visible turn exactly once")
        print("PASS: preview stop reaches confirmed stopped state")
        connection.setModel(connection.models(for: .codex)[1], for: "design-0")
        for _ in 0..<80 where connection.configuringSessions.contains("design-0") {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await connection.poll()
        precondition(connection.snapshot?.model == "gpt-5.4-mini" && selectedModels[0] == "gpt-5.4-mini")
        connection.setThinking(.medium, for: "design-0")
        for _ in 0..<80 where connection.configuringSessions.contains("design-0") {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await connection.poll()
        precondition(connection.snapshot?.thinking == "medium" && selectedEfforts[0] == "medium")
        print("PASS: model and effort changes reach the fixture runtime and return in the selected session")
    }
}

/// Keeps the requested design size on displays smaller than the design.
private final class NativeDesignWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Preview-only controls let visual reviews capture the same live window in
/// both appearances, including system-composited material and shadows.
@MainActor private final class NativeDesignAppearanceMenu: NSObject {
    private weak var window: NSWindow?
    private let menu = NSMenu(title: "外观")

    init(window: NSWindow) {
        self.window = window
        super.init()
        for (title, tag) in [("浅色", 0), ("深色", 1)] {
            let item = NSMenuItem(title: title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = tag == 0 ? .on : .off
            menu.addItem(item)
        }
        let main = NSApp.mainMenu ?? NSMenu()
        let item = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
        NSApp.mainMenu = main
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        window?.appearance = NSAppearance(named: sender.tag == 0 ? .aqua : .darkAqua)
        for item in menu.items { item.state = item === sender ? .on : .off }
    }
}
