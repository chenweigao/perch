import AppKit
import ApplicationServices
import SwiftUI
import WorkbenchCore

/// The production workspace with deterministic sessions and a disposable Git
/// repository. No saved environments, network connections, or real drafts.
@MainActor func checkNativeDesign() async throws {
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    AppLanguage.applyToSystem(.zhHans)
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    let persistentPreview = Bundle.main.object(forInfoDictionaryKey: "PerchDesignPreview") as? Bool == true
    NSApp.setActivationPolicy(persistentPreview ? .regular : .accessory)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-design-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let emptyDirectory = root.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
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
        ["id": "design-\(index)", "provider": "codex", "title": titles[index], "cwd": index == 1 ? emptyDirectory.path : root.path,
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
        if index == 0 {
            let questionAndAnswer = data["messages"] as! [[String: Any]]
            // The rail check measures the visible answer. Text followed by tools
            // is intermediate process content and is intentionally indented.
            data["messages"] = [questionAndAnswer[0]] + [
                ["id": "plan", "role": "assistant", "created_at": "", "content": [
                    ["type": "tool_use", "tool_call_id": "plan", "tool_name": "TodoList", "input": ["todos": [
                        ["title": "定位会话加载与恢复逻辑", "status": "done"],
                        ["title": "分离草稿和滚动位置", "status": "done"],
                        ["title": "验证快速切换会话与返回后的状态", "status": "in_progress"]]]]]],
                ["id": "plan-result", "role": "tool", "created_at": "", "content": [
                    ["type": "tool_result", "tool_call_id": "plan", "is_error": false, "output": "Updated"]]]
            ] + [questionAndAnswer[1]]
        }
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
    let window = NativeDesignWindow(contentRect: NSRect(x: 30, y: 40, width: 1536, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Perch · 原生设计对照"
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    defer { window.close(); window.contentViewController = nil }
    let hosting = NSHostingController(rootView: WorkbenchView(model: model).environment(\.locale, Locale(identifier: "zh-Hans")))
    hosting.sizingOptions = []
    window.contentViewController = hosting
    // The window must fit the 748 pt reading column beside the default inspector:
    // 1536 leaves the space to center it; smaller windows let it clamp narrower.
    window.setContentSize(NSSize(width: 1536, height: 900))
    window.makeKeyAndOrderFront(nil)
    // The 1536 × 900 design geometry must not depend on the display: CI screens
    // are smaller, and AppKit would otherwise shrink the window to fit them.
    window.setFrame(NSRect(origin: window.frame.origin, size: window.frameRect(forContentRect:
        NSRect(origin: .zero, size: NSSize(width: 1536, height: 900))).size), display: true)
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
    precondition(draft.font?.pointSize == 14, "The mounted composer shares the default 14 pt reading size")
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
    precondition(abs(split.floatingInspectorView!.bounds.height - split.detailCardView!.bounds.height) < 1,
                 "The first opening of an empty inspector must fill the workspace sheet")
    model.taskContextWindow.showPage(.changes, model: model)
    try await Task.sleep(for: .milliseconds(500))
    window.contentView!.layoutSubtreeIfNeeded()
    let inspector = split.floatingInspectorView!
    let inspectorFrame = inspector.convert(inspector.bounds, to: window.contentView)
    let card = split.detailCardView!
    let cardFrame = card.convert(card.bounds, to: window.contentView)
    func checkSidebarEdges() {
        let sidebar = split.floatingSidebarView!
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: window.contentView)
        let contentFrame = card.convert(card.bounds, to: window.contentView)
        let sidebarTop = window.contentView!.isFlipped ? sidebarFrame.minY : window.contentView!.bounds.maxY - sidebarFrame.maxY
        let sidebarBottom = window.contentView!.isFlipped ? sidebarFrame.maxY : sidebarFrame.minY
        let contentBottom = window.contentView!.isFlipped ? contentFrame.maxY : contentFrame.minY
        precondition(abs(sidebarBottom - contentBottom) < 1 &&
                     abs(sidebarTop - WorkspaceLayoutMetrics.contentTopInset) < 1,
                     "Sidebar controls stay below the window controls and share the main container's bottom edge: sidebar=\(sidebarFrame), content=\(contentFrame)")
    }
    checkSidebarEdges()
    let draftFrame = draft.convert(draft.bounds, to: window.contentView)
    let replyFrame = reply.convert(reply.bounds, to: window.contentView)
    func distanceFromTop(_ frame: NSRect) -> CGFloat {
        window.contentView!.isFlipped ? frame.minY : window.contentView!.bounds.maxY - frame.maxY
    }
    func distanceFromBottom(_ frame: NSRect) -> CGFloat {
        window.contentView!.isFlipped ? window.contentView!.bounds.maxY - frame.maxY : frame.minY
    }
    let backdrop = split.windowBackdropView!
    let backdropFrame = backdrop.convert(backdrop.bounds, to: window.contentView)
    let windowCorner = WorkbenchWindowBackdropView.windowCornerRadius(of: window)
    precondition(!window.isOpaque && backdrop.fixedCornerRadius == nil && abs(backdrop.glassCornerRadius - windowCorner) < 0.5 &&
                 abs(backdropFrame.width - window.contentView!.bounds.width) < 1 &&
                 abs(backdropFrame.height - window.contentView!.bounds.height) < 1,
                 "The window must be one Liquid Glass backdrop shaped like the window: backdrop=\(backdropFrame), corner=\(backdrop.glassCornerRadius), window corner=\(windowCorner), opaque=\(window.isOpaque)")
    let panelRadius = WorkbenchTheme.Radius.framePanel(windowCorner: windowCorner, inset: WorkspaceLayoutMetrics.frameInset)
    precondition(abs(split.panelCornerRadius - panelRadius) < 0.5 &&
                 card.layer?.cornerRadius == split.panelCornerRadius &&
                 split.sidebarOverlayBackdropView?.fixedCornerRadius == split.panelCornerRadius,
                 "Frame panels must be concentric with the window corner: window=\(windowCorner), panels=\(split.panelCornerRadius), expected=\(panelRadius)")
    precondition(split.sidebarOverlayBackdropView?.isHidden == true,
                 "Wide windows draw navigation straight on the window glass; only the narrow overlay gets its own glass panel")
    precondition(abs(distanceFromTop(cardFrame) - WorkspaceLayoutMetrics.frameInset) < 1 &&
                 abs(distanceFromBottom(cardFrame) - WorkspaceLayoutMetrics.frameInset) < 1 &&
                 abs(window.contentView!.bounds.maxX - cardFrame.maxX - WorkspaceLayoutMetrics.frameInset) < 1 &&
                 abs(distanceFromTop(inspectorFrame) - distanceFromTop(cardFrame)) < 1 &&
                 abs(inspectorFrame.height - cardFrame.height) < 1 &&
                 abs(inspectorFrame.maxX - cardFrame.maxX) < 1,
                 "The main floating container must have equal top, bottom, and trailing margins, shared with the full-height inspector")
    precondition(inspector.superview === card && (inspector.layer?.shadowOpacity ?? 0) == 0,
                 "The inspector belongs inside the sheet without a separate elevation")
    precondition(connection.models(for: .codex).count == 2 &&
                 connection.model(for: connection.snapshot!)?.supportsThinking == true,
                 "The design fixture must include a real model catalog and adjustable reasoning controls")
    precondition(replyFrame.maxX < inspectorFrame.minX && draftFrame.maxX < inspectorFrame.minX,
                 "The inspector must not cover the reply or composer/send lane: reply=\(replyFrame), composer=\(draftFrame), inspector=\(inspectorFrame)")
    let draftX = draft.convert(draft.bounds, to: window.contentView).minX
    let replyX = reply.convert(reply.bounds, to: window.contentView).minX
    precondition(abs(draftX - replyX) < 2, "Composer and reply must share the reading rail: draft=\(draftX), reply=\(replyX)")
    // The composer bar floats over the transcript without a divider across the card.
    let contentHeight = window.contentView!.bounds.height
    let draftTop = window.contentView!.isFlipped ? draftFrame.minY : contentHeight - draftFrame.maxY
    let divider = horizontalRule(in: window.contentView!, from: draftTop - 110, to: draftTop - 20,
                                 xRange: (cardFrame.minX + 30)...(cardFrame.maxX - 30))
    precondition(divider == nil, "The composer bar must not draw a divider across the reading card: y=\(String(describing: divider)), composer top=\(draftTop)")
    let title = split.headerTitleView!
    let titleX = title.convert(title.bounds, to: window.contentView).minX
    precondition(title.isDescendant(of: card) && abs(titleX - cardFrame.minX - WorkbenchTheme.Reading.inset) < 2,
                 "The unified header title lives inside the main container and stays anchored to the pane")
    let toolbarActions = split.headerActionsView!
    let actionsRight = toolbarActions.convert(toolbarActions.bounds, to: window.contentView).maxX
    precondition(toolbarActions.isDescendant(of: card) &&
                 window.contentView!.bounds.maxX - actionsRight < 40 && actionsRight > inspectorFrame.maxX - 40,
                 "Header actions belong at the main container's trailing edge, above the inspector")
    for changedTitle in ["短标题", "恢复后的长会话标题：检查工具栏对齐和右侧悬浮面板开合时的位置"] {
        model.rename(first, title: changedTitle)
        try await Task.sleep(for: .milliseconds(200))
        window.contentView!.layoutSubtreeIfNeeded()
        precondition(abs(title.convert(title.bounds, to: window.contentView).minX - titleX) < 2,
                     "A changing session title must not move the header's left alignment")
    }
    model.rename(first, title: first.title)
    try await Task.sleep(for: .milliseconds(200))
    let readingCenterX = (cardFrame.minX + inspectorFrame.minX) / 2
    precondition(abs(draftFrame.midX - readingCenterX) < 2 &&
                 abs(replyX - (readingCenterX - ReplyStyle.readingWidth / 2)) < 2,
                 "Reply and editor must center in the space remaining beside the inspector")
    for cycle in 0..<3 {
        split.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(200))
        window.contentView!.layoutSubtreeIfNeeded()
        let collapsedCard = card.convert(card.bounds, to: window.contentView)
        let collapsedTitle = title.convert(title.bounds, to: window.contentView)
        precondition(collapsedTitle.minX >= collapsedCard.minX + 100 &&
                     collapsedTitle.minX < titleX - 100,
                     "Collapsed sidebar must shift the title clear of the top-left window controls inside the expanded main container: cycle=\(cycle), title=\(collapsedTitle), card=\(collapsedCard)")
        split.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(200))
        window.contentView!.layoutSubtreeIfNeeded()
        let reopenedX = title.convert(title.bounds, to: window.contentView).minX
        checkSidebarEdges()
        precondition(abs(reopenedX - titleX) < 2,
                     "Reopening sidebar must restore title alignment without accumulated offsets: cycle=\(cycle), expected=\(titleX), actual=\(reopenedX)")
    }
    for _ in 0..<10 { split.toggleSidebar(nil) }
    try await Task.sleep(for: .milliseconds(200))
    window.contentView!.layoutSubtreeIfNeeded()
    precondition(abs(title.convert(title.bounds, to: window.contentView).minX - titleX) < 2 &&
                 abs(toolbarActions.convert(toolbarActions.bounds, to: window.contentView).maxX - actionsRight) < 2,
                 "Rapid sidebar toggles must not drift the title or trailing actions")
    print("PASS: sidebar close/reopen and rapid toggles preserve unified header alignment")
    let savedDraft = draft.string
    model.taskContextWindow.embeddedVisible = false
    try await Task.sleep(for: .milliseconds(300))
    window.contentView!.layoutSubtreeIfNeeded()
    let closedCardFrame = card.convert(card.bounds, to: window.contentView)
    let closedDraftFrame = draft.convert(draft.bounds, to: window.contentView)
    precondition(abs(toolbarActions.convert(toolbarActions.bounds, to: window.contentView).maxX - actionsRight) < 2 &&
                 abs(title.convert(title.bounds, to: window.contentView).minX - titleX) < 2,
                 "Inspector toggles must not shift the unified header title or actions")
    let closedReply = descendants(window.contentView!).compactMap { $0 as? ReplyTextView }.first { $0.string.contains("初步发现") }!
    let closedReplyFrame = closedReply.convert(closedReply.bounds, to: window.contentView)
    precondition(abs(closedCardFrame.width - cardFrame.width) < 1 &&
                 closedDraftFrame.minX > draftX + 100 &&
                 abs(closedDraftFrame.midX - closedCardFrame.midX) < 2 &&
                 abs(closedReplyFrame.minX - closedDraftFrame.minX) < 2 &&
                 draft.string == savedDraft,
                 "Closing the inspector must re-center the same composer and reply inside the unchanged sheet")
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
    precondition(abs(compactHeight - card.bounds.height) < 1,
                 "An empty task inspector keeps the sheet's full height")
    model.taskContextWindow.page = .changes
    try await Task.sleep(for: .milliseconds(500))
    window.contentView!.layoutSubtreeIfNeeded()
    precondition(split.floatingInspectorView === inspector && abs(inspector.bounds.height - compactHeight) < 1,
                 "Switching task and diff pages must keep the same full-height inspector")
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
    let actualTitlebarHeight = window.frame.height - window.contentLayoutRect.height
    precondition(window.toolbarStyle == .unifiedCompact && actualTitlebarHeight <= 44,
                 "Use the native compact toolbar rather than sliding content underneath a tall toolbar: \(actualTitlebarHeight)")
    let liveCardFrame = card.convert(card.bounds, to: nil)
    let liveCardTop = window.frame.height - liveCardFrame.maxY
    let liveCardRight = window.frame.width - liveCardFrame.maxX
    precondition(abs(liveCardTop - WorkspaceLayoutMetrics.frameInset) < 1 &&
                 abs(liveCardFrame.minY - WorkspaceLayoutMetrics.frameInset) < 1 &&
                 abs(liveCardRight - WorkspaceLayoutMetrics.frameInset) < 1,
                 "The main floating container must have equal top, bottom, and trailing margins (12pt)")
    let closeFrame = fromTop(window.standardWindowButton(.closeButton))
    if let toggle {
        precondition(abs((fromTop(toggle)["midY"] ?? 0) - (closeFrame["midY"] ?? 0)) < 2,
                     "Sidebar toggle must share the window controls' vertical center")
    }
    for control in [title, toolbarActions] {
        precondition(abs((fromTop(control)["midY"] ?? 0) - (closeFrame["midY"] ?? 0)) < 2,
                     "Unified header title/actions must share the native toolbar's vertical center: title/actions=\(fromTop(control)), trafficLights=\(closeFrame)")
    }
    precondition(abs((fromTop(title)["midY"] ?? 0) - (fromTop(toolbarActions)["midY"] ?? 0)) < 2,
                 "Unified header title and actions must share the same vertical center inside the main container")
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
    // Too narrow for all three, wide enough without navigation: the sidebar steps
    // aside instead of the inspector covering the reply, and comes back on request.
    window.setFrame(NSRect(x: visible.minX, y: visible.minY, width: 1100,
                           height: min(wideFrame.height, visible.height)), display: true)
    try await Task.sleep(for: .milliseconds(300))
    window.contentView!.layoutSubtreeIfNeeded()
    let yieldingReply = descendants(window.contentView!).compactMap { $0 as? ReplyTextView }.first { $0.string.contains("初步发现") }!
    let yieldingReplyFrame = yieldingReply.convert(yieldingReply.bounds, to: window.contentView)
    let yieldingInspectorFrame = inspector.convert(inspector.bounds, to: window.contentView)
    precondition(split.isSidebarYieldingToInspector && split.floatingSidebarView!.isHidden &&
                 !split.isInspectorOverlayingContent && yieldingReplyFrame.maxX < yieldingInspectorFrame.minX,
                 "At 1100 pt the inspector must sit beside the reply, not over it: reply=\(yieldingReplyFrame), inspector=\(yieldingInspectorFrame)")
    split.toggleSidebar(nil)
    try await Task.sleep(for: .milliseconds(200))
    window.contentView!.layoutSubtreeIfNeeded()
    precondition(split.isSidebarShown && !split.isSidebarYieldingToInspector && !split.isInspectorOverlayingContent,
                 "Asking for a yielding sidebar must bring it back without overlaying the inspector")
    try await place(width: 900)
    let narrowSidebarFrame = split.floatingSidebarView!.convert(split.floatingSidebarView!.bounds, to: window.contentView)
    let narrowTitleFrame = title.convert(title.bounds, to: window.contentView)
    precondition(split.isSidebarOverlayingContent && split.sidebarOverlayBackdropView?.isHidden == false &&
                 narrowTitleFrame.minX > narrowSidebarFrame.maxX,
                 "A narrow window must back the overlaying sidebar with its glass panel and shift the header title clear of the sidebar: title=\(narrowTitleFrame), sidebar=\(narrowSidebarFrame)")
    checkSidebarEdges()
    try await capture("native-narrow-light")
    split.setFloatingSidebarVisible(false)
    try await place(width: 700)
    let narrowDraftFrame = draft.convert(draft.bounds, to: window.contentView)
    let narrowInspectorFrame = inspector.convert(inspector.bounds, to: window.contentView)
    try await capture("native-compact-light")
    precondition(narrowDraftFrame.maxX < narrowInspectorFrame.minX &&
                 abs(inspector.bounds.height - card.bounds.height) < 1,
                 "At 700 pt the integrated inspector must not cover the composer: editor=\(narrowDraftFrame), inspector=\(narrowInspectorFrame)")
    split.setFloatingSidebarVisible(true)
    window.setFrame(wideFrame, display: true)
    try await Task.sleep(for: .milliseconds(300))
    window.contentView!.layoutSubtreeIfNeeded()
    // Sidebar rows show only the title and status dots; full title, host, path,
    // agent and time are all in the hover tooltip.
    let rowTooltip = SessionRowChrome(title: "长会话标题", subtitle: nil,
                                      hostName: "Mac mini", directory: "/tmp/perch",
                                      detail: "Codex · 结果待查看", updatedAt: Date().timeIntervalSince1970 - 60,
                                      compact: true, selected: false, canOpen: true,
                                      onOpen: {}, indicator: { EmptyView() }).tooltip
    precondition(rowTooltip.contains("长会话标题") && rowTooltip.contains("Mac mini") &&
                 rowTooltip.contains("/tmp/perch") && rowTooltip.contains("Codex") &&
                 rowTooltip.contains("分钟") || rowTooltip.contains("min"),
                 "Hover tooltip must include full title, host, directory, agent and time: \(rowTooltip)")
    model.taskContextWindow.embeddedVisible = false
    try await Task.sleep(for: .milliseconds(250))
    try await capture("native-inspector-closed-light")
    // Exercise multiple pinned sessions, multi-line draft with @reference + attachment, and the task overview in the right column.
    let savedStarred = model.workspace.starred
    for item in model.allSessions.prefix(4) where !model.workspace.starred.contains(item.reference) {
        model.toggleStar(item.reference)
    }
    let sampleAttachment = root.appendingPathComponent("SessionState.swift")
    connection.attachments["design-0"] = [sampleAttachment]
    connection.drafts["design-0"] = "核对 @\"\(sampleAttachment.path)\" 的状态恢复边界：\n1. 右栏展开/收起保留草稿与阅读位置\n2. 顶部会话概述区分已完成、进行中与计划"
    model.taskContextWindow.showPage(.task, model: model)
    try await Task.sleep(for: .milliseconds(400))
    try await capture("native-task-overview-light")
    model.taskContextWindow.readingState(for: first.reference).overviewExpanded = true
    try await Task.sleep(for: .milliseconds(250))
    try await capture("native-task-overview-expanded-light")
    model.taskContextWindow.readingState(for: first.reference).overviewExpanded = false
    connection.attachments["design-0"] = nil
    connection.drafts["design-0"] = ""
    model.workspace.starred = savedStarred
    model.taskContextWindow.showPage(.changes, model: model)
    try await Task.sleep(for: .milliseconds(250))
    print("PASS: production workspace, aligned reply/composer, integrated full-height inspector, native light and dark")
    let files = model.inspectorFiles
    func waitForFile(_ ready: () -> Bool) async throws {
        for _ in 0..<60 where !ready() { try await Task.sleep(for: .milliseconds(50)) }
        precondition(ready(), "File inspector must finish its page-owned read: path=\(files.path), error=\(String(describing: files.error))")
        window.contentView!.layoutSubtreeIfNeeded()
    }
    model.toggleFileViewer()
    try await waitForFile {
        if case .directory(let entries) = files.content { return entries.contains { $0.name == "SessionState.swift" } }
        return false
    }
    precondition(model.taskContextWindow.isShowing(.files) && model.fileWindow.window == nil && !model.showFileViewer,
                 "The files toolbar action must browse the working directory without opening a reader window")
    let directoryHeight = split.floatingInspectorView!.bounds.height
    precondition(abs(directoryHeight - card.bounds.height) < 1, "A short directory fills the integrated lane")
    files.open(root.appendingPathComponent("SessionState.swift").path)
    try await waitForFile {
        if case .text(let text, _, _) = files.content { return text == after }
        return false
    }
    try await Task.sleep(for: .milliseconds(150))
    precondition(abs(split.floatingInspectorView!.bounds.height - directoryHeight) < 1 && model.fileWindow.window == nil,
                 "Selecting a file keeps the inspector's height and reads inline")
    files.openParent()
    try await waitForFile { if case .directory = files.content { return files.path == root.path }; return false }
    model.toggleFileViewer()
    try await waitForFile { files.fileRequest == nil && !files.loading }
    model.toggleFileViewer()
    try await waitForFile { model.taskContextWindow.isShowing(.files) && files.path == root.path }
    // Replace an outstanding read by a different session's directory.
    files.open(root.appendingPathComponent("SessionState.swift").path)
    model.open(pin)
    try await waitForFile {
        if case .directory(let entries) = files.content {
            return files.source == pin.reference && files.path == emptyDirectory.path && entries.isEmpty
        }
        return false
    }
    try await Task.sleep(for: .milliseconds(150))
    precondition(abs(split.floatingInspectorView!.bounds.height - directoryHeight) < 1,
                 "An empty directory keeps the lane height and never retains another session's file")
    model.open(first)
    try await waitForFile { files.source == first.reference && files.path == root.path && !files.loading }
    files.open(root.appendingPathComponent("SessionState.swift").path)
    try await waitForFile { if case .text = files.content { return true }; return false }
    model.expandInspectorFile()
    precondition(model.fileWindow.window != nil && model.fileBrowser.path == files.path && model.fileBrowser !== files,
                 "Expand Reader must explicitly hand off the selected file without sharing navigation state")
    model.fileWindow.close()
    precondition(model.taskContextWindow.isShowing(.files) && files.content != nil,
                 "Closing the detached reader must preserve the inspector preview")
    window.makeKeyAndOrderFront(nil)
    model.taskContextWindow.showPage(.changes, model: model)
    try await Task.sleep(for: .milliseconds(200))
    print("PASS: file inspector first reveal, inline preview, parent navigation, reopen, session isolation and explicit expansion")
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

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        var rowPoint: CGPoint?
        let sidebarMaxX = split.floatingSidebarView!.convert(split.floatingSidebarView!.bounds, to: nil).maxX
        for element in taskPanelElements(window) where element.identifier == "sidebar.row" {
            let node = element.node
            guard node.responds(to: NSSelectorFromString("accessibilityFrame")),
                  let frame = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
                  frame.minX < sidebarMaxX, frame.height >= 20, frame.height <= 40 else { continue }
            rowPoint = CGPoint(x: frame.midX, y: frame.midY)
            break
        }
        guard let rowPoint else {
            let identifiers = taskPanelElements(window).map { element -> String in
                guard let frame = (element.node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
                    return "\(element.identifier ?? "nil"){}"
                }
                return "\(element.identifier ?? "nil"){\(frame)}"
            }
            preconditionFailure("Sidebar session row must expose a native hover target: \(identifiers)")
        }
        func postMouse(_ type: CGEventType, at point: CGPoint) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
            event.post(tap: .cghidEventTap)
        }
        func moveMouse(to point: CGPoint) {
            CGWarpMouseCursorPosition(point)
            let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
            event.post(tap: .cghidEventTap)
        }
        moveMouse(to: CGPoint(x: 600, y: 500))
        try await Task.sleep(for: .milliseconds(100))
        moveMouse(to: rowPoint)
        try await Task.sleep(for: .milliseconds(700))
        let localMouse = window.mouseLocationOutsideOfEventStream
        let localRow = window.convertFromScreen(rowPoint)
        FileHandle.standardError.write(Data("HOVER-DIAG: rowPoint=\(rowPoint), localRow=\(localRow), localMouse=\(localMouse), hit=\(String(describing: window.contentView?.hitTest(localMouse))), window=\(window.frame), mouse=\(NSEvent.mouseLocation), active=\(NSApp.isActive), key=\(window.isKeyWindow), ids=\(taskPanelIdentifiers(window))\n".utf8))
        guard let actionsFrame = taskPanelControl(window, "sidebar.row.actions") else {
            preconditionFailure("Hovering a session row must reveal its ellipsis action")
        }
        guard let previewWindow = NSApp.windows.first(where: { taskPanelControl($0, "sidebar.row.preview") != nil }) else {
            preconditionFailure("Hovering a session row must open the styled preview after its delay")
        }
        if let folder = ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"],
           let view = previewWindow.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("sidebar-hover-preview.png"))
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            postMouse(type, at: CGPoint(x: actionsFrame.midX, y: actionsFrame.midY))
        }
        try await Task.sleep(for: .milliseconds(250))
        guard let menuWindow = NSApp.windows.first(where: { taskPanelLabel($0, "重命名…") != nil }) else {
            preconditionFailure("The ellipsis action must open the same session actions as the context menu")
        }
        if let folder = ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"],
           let view = menuWindow.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("sidebar-actions-menu.png"))
        }
        previewWindow.close()
        menuWindow.close()
        let center = card.convert(card.bounds, to: nil)
        moveMouse(to: CGPoint(x: center.midX, y: center.midY))
        print("PASS: sidebar delayed styled preview, hover ellipsis and native session actions menu")
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
