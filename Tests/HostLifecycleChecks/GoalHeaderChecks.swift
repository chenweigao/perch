import AppKit
import SwiftUI
import WorkbenchCore

@MainActor func checkGoalHeader() async throws {
    AppLanguage.applyToSystem(.zhHans)
    let objective = "完成 Perch 会话阅读体验优化，让正文清晰、工具过程按需展开，并在验收后提交 PR。"
    let goal = KimiGoal(objective: objective, status: "active", turnsUsed: 12, tokensUsed: 48320)
    var controls: [String] = []
    var measuredHeight: CGFloat = 0
    let bar = GoalHeaderBar(goal: goal, isRunning: true, isStale: false, controlsEnabled: true) { controls.append($0) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
    let host = NSHostingView(rootView: bar.frame(maxHeight: .infinity, alignment: .top).environment(\.locale, Locale(identifier: "zh-Hans")))
    let window = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 720, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(250))

    func click(x: CGFloat, top: CGFloat) {
        let point = host.convert(NSPoint(x: x, y: host.isFlipped ? top : host.bounds.height - top), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
    let collapsedHeight = measuredHeight
    precondition(collapsedHeight > 40 && collapsedHeight < 130)
    click(x: 140, top: 28)
    try await Task.sleep(for: .milliseconds(200))
    precondition(measuredHeight > collapsedHeight + 40, "Click opens the full objective and usage below the header")
    click(x: 140, top: 28)
    try await Task.sleep(for: .milliseconds(150))
    precondition(abs(measuredHeight - collapsedHeight) < 1, "Click collapses goal details")
    click(x: 620, top: 43)
    precondition(controls == ["pause"], "Visible pause action controls continuation")

    var wideHeights: [String: CGFloat] = [:]
    for (name, state, running, stale, width) in [
        ("running", "active", true, false, 720.0),
        ("waiting", "active", false, false, 720.0),
        ("paused", "paused", false, false, 720.0),
        ("paused-current-turn", "paused", true, false, 720.0),
        ("complete", "complete", false, false, 720.0),
        ("offline-narrow", "active", true, true, 420.0)
    ] {
        let preview = GoalHeaderBar(goal: KimiGoal(objective: objective, status: state, turnsUsed: 12, tokensUsed: 48320),
                                    isRunning: running, isStale: stale, controlsEnabled: true, onControl: { _ in })
            .frame(width: width).environment(\.locale, Locale(identifier: "zh-Hans"))
        let layoutHost = NSHostingView(rootView: preview)
        window.contentView = layoutHost
        window.setContentSize(NSSize(width: width, height: 200))
        try await Task.sleep(for: .milliseconds(100))
        precondition(layoutHost.fittingSize.height > 40 && layoutHost.fittingSize.height < 130, "Collapsed goal remains a compact header at narrow widths")
        if !stale { wideHeights[name] = layoutHost.fittingSize.height }
    }
    // The header sits above the transcript: a turn starting or ending must not
    // change its height (the activity bar, not the goal, shows the running state).
    // A one-line objective lets the status column, not the text, set the height.
    for running in [true, false] {
        let preview = GoalHeaderBar(goal: KimiGoal(objective: "整理阅读画布", status: "active", turnsUsed: 1, tokensUsed: 900),
                                    isRunning: running, isStale: false, controlsEnabled: true, onControl: { _ in })
            .frame(width: 720).environment(\.locale, Locale(identifier: "zh-Hans"))
        let layoutHost = NSHostingView(rootView: preview)
        window.contentView = layoutHost
        window.setContentSize(NSSize(width: 720, height: 200))
        try await Task.sleep(for: .milliseconds(100))
        wideHeights[running ? "short-running" : "short-waiting"] = layoutHost.fittingSize.height
    }
    let reference = wideHeights["running"]!
    precondition(wideHeights.filter { !$0.key.hasPrefix("short") }.values.allSatisfy { abs($0 - reference) < 0.5 },
                 "Goal header height changes with run state: \(wideHeights)")
    precondition(abs(wideHeights["short-running"]! - wideHeights["short-waiting"]!) < 0.5,
                 "Short goal header height changes when a turn starts: \(wideHeights)")
    print("PASS: goal header disclosure, direct pause, compact running/paused/complete/stale layouts, run-state-independent height")
}
