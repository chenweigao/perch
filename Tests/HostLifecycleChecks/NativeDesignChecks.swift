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
    var abortedTurns: [String] = []
    func summary(_ index: Int) -> [String: Any] {
        ["id": "design-\(index)", "provider": "codex", "title": titles[index], "cwd": root.path,
         "busy": index == 0 && running, "archived": false, "updated": Date().timeIntervalSince1970 - Double(index * 120),
         "completed": 1, "pending": index == 2 ? 1 : 0, "model": "gpt-5.4", "turnId": "design-turn-\(index)",
         "turnState": running ? "running" : "stopped"]
    }
    let connection = NativeAgentConnection(host: host) { path, body in
        if path.hasSuffix("/abort") {
            abortedTurns.append(body.flatMap { $0["turnId"].string } ?? "")
            running = false
            return Data("{}".utf8)
        }
        if path == "/sessions" {
            return try JSONSerialization.data(withJSONObject: ["sessions": titles.indices.map(summary)])
        }
        let index = Int(path.components(separatedBy: "design-").last?.prefix(1) ?? "0") ?? 0
        var data = summary(index)
        data["revision"] = running ? 1 : 2
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
    model.taskContextWindow.showPage(.changes, model: model)
    let window = NSWindow(contentRect: NSRect(x: 30, y: 40, width: 1440, height: 900),
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
    let inspector = split.floatingInspectorView!
    let inspectorFrame = inspector.convert(inspector.bounds, to: window.contentView)
    let card = split.detailCardView!
    let cardFrame = card.convert(card.bounds, to: window.contentView)
    let draftFrame = draft.convert(draft.bounds, to: window.contentView)
    let replyFrame = reply.convert(reply.bounds, to: window.contentView)
    precondition(cardFrame.maxX + WorkspaceLayoutMetrics.sidebarGap <= inspectorFrame.minX + 1,
                 "The floating inspector must have its own lane and visible gap: card=\(cardFrame), inspector=\(inspectorFrame)")
    precondition(replyFrame.maxX < inspectorFrame.minX && draftFrame.maxX < inspectorFrame.minX,
                 "The inspector must not cover the reply or composer/send lane: reply=\(replyFrame), composer=\(draftFrame), inspector=\(inspectorFrame)")
    let draftX = draft.convert(draft.bounds, to: window.contentView).minX
    let replyX = reply.convert(reply.bounds, to: window.contentView).minX
    precondition(abs(draftX - replyX) < 2, "Composer and reply must share the reading rail: draft=\(draftX), reply=\(replyX)")
    let title = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "WorkbenchTitle" }!.view!
    let titleX = title.convert(title.bounds, to: window.contentView).minX
    precondition(abs(titleX - replyX) < 2,
                 "The native toolbar title must follow the same reading rail: title=\(titleX), reply=\(replyX)")
    precondition(model.changesBrowser.gitStatus != nil && model.selectedReference == first.reference)
    if let folder = ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"] {
        func rectangle(_ rect: NSRect) -> [String: Double] {
            ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
        }
        let geometry: [String: Any] = [
            "scope": "native window geometry; view-cache PNGs exclude composited Liquid Glass",
            "window": rectangle(window.contentView!.bounds), "conversation": rectangle(cardFrame),
            "inspector": rectangle(inspectorFrame), "reply": rectangle(replyFrame), "composerText": rectangle(draftFrame),
            "titleX": Double(titleX), "sidebarWidth": Double(split.floatingSidebarWidth),
        ]
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("native-layout.json"))
    }
    func capture(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"],
              let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
    capture("native-light")
    window.appearance = NSAppearance(named: .darkAqua)
    try await Task.sleep(for: .milliseconds(200))
    capture("native-dark")
    window.appearance = NSAppearance(named: .aqua)
    try await Task.sleep(for: .milliseconds(200))
    print("PASS: production workspace, aligned reply/composer, independent changes inspector, native light and dark")
    if Bundle.main.object(forInfoDictionaryKey: "PerchDesignPreview") as? Bool == true && !CommandLine.arguments.contains("native-design") {
        while window.isVisible { try await Task.sleep(for: .seconds(1)) }
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
    }
}
