import AppKit
import SwiftUI

@MainActor
enum ToolbarProbe {
    static var controls: [String: NSView] = [:]
    static var selection = ""
    static var payload = ""
}

struct ToolbarButtonProbe: NSViewRepresentable {
    var id = "model"
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        ToolbarProbe.controls[id] = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

@MainActor
private func click(_ point: NSPoint, in window: NSWindow) {
    window.makeKeyAndOrderFront(nil)
    for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        window.sendEvent(event)
    }
}

@MainActor
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "ToolbarChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor
private func pause() async throws { try await Task.sleep(for: .milliseconds(200)) }

@MainActor
private func press(_ id: String) async throws {
    guard let view = ToolbarProbe.controls[id], let window = view.window else {
        throw NSError(domain: "Missing control: " + id, code: 1)
    }
    click(view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), in: window)
    try await pause()
}

@MainActor
private func openPanel(_ main: NSWindow, thinking: Bool = false) async throws -> NSWindow {
    let view = ToolbarProbe.controls["model"]!
    let point = NSPoint(x: thinking ? view.bounds.maxX - 25 : 25, y: view.bounds.midY)
    click(view.convert(point, to: nil), in: main)
    try await pause()
    guard let panel = NSApp.windows.first(where: { $0.isVisible && $0 !== main }) else {
        throw NSError(domain: "Model panel did not open", code: 1)
    }
    return panel
}

@MainActor
private func closePanel(_ panel: NSWindow) async throws {
    panel.makeKeyAndOrderFront(nil)
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: panel.windowNumber, context: nil,
                                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                isARepeat: false, keyCode: 53)!
    panel.sendEvent(event)
    try await pause()
    try expect(!panel.isVisible, "Escape must dismiss the panel")
}

@MainActor
private func chooseModel(_ query: String, in panel: NSWindow) async throws {
    let field = views(panel.contentView!).compactMap { $0 as? NSTextField }.first(where: \.isEditable)!
    field.selectText(nil)
    (field.currentEditor() as! NSTextView).insertText(query, replacementRange: NSRange(location: NSNotFound, length: 0))
    try await pause()
    let list = views(panel.contentView!).compactMap { $0 as? NSScrollView }.first!
    let frame = list.convert(list.bounds, to: nil)
    click(NSPoint(x: frame.midX, y: frame.maxY - 30), in: panel)
    try await pause()
    try expect(!panel.isVisible, "Choosing a model must dismiss its panel")
}

@MainActor
private func checkLayout(_ label: String) throws {
    let composer = ToolbarProbe.controls["composer"]!
    let bounds = composer.convert(composer.bounds, to: nil)
    let frames = ["model", "permission", "send"].map { id -> CGRect in
        let view = ToolbarProbe.controls[id]!
        return view.convert(view.bounds, to: nil)
    }
    try expect(frames.allSatisfy { bounds.contains($0) }, "Controls overflow the composer: " + label)
    try expect(!frames[0].intersects(frames[1]) && !frames[1].intersects(frames[2]), "Controls overlap: " + label)
    try expect(frames[0].width >= 50, "Model selector is squeezed out: " + label)
    if ToolbarProbe.selection.hasPrefix("fixture/long") {
        try expect(frames[0].width >= 260, "Long model names must remain readable beside the longest effort label")
    }
    print("PASS layout", label, frames)
}

@MainActor
func runToolbarChecks() async {
    let agent = ProcessInfo.processInfo.environment["COMPOSER_PREVIEW_AGENT"] ?? "kimi"
    var result: [String: Any] = ["agent": agent, "status": "failed"]
    do {
        for _ in 0..<100 {
            if ToolbarProbe.controls["model"]?.window != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let main = ToolbarProbe.controls["model"]?.window else { throw NSError(domain: "No preview window", code: 1) }
        try await pause()
        try checkLayout("wide Chinese")
        let panel = try await openPanel(main)
        if ["qoder", "claude"].contains(agent) {
            try expect(!views(panel.contentView!).contains { $0 is NSTextField }, "Agents without model capabilities must remain read-only")
            try await closePanel(panel)
        } else {
            try await closePanel(panel)
            let lowPanel = try await openPanel(main, thinking: true)
            click(NSPoint(x: 80, y: lowPanel.frame.height - 60), in: lowPanel)
            try await pause()
            try expect(ToolbarProbe.selection == "fixture/reasoner|low", "Low thinking row did not update selection")
            try expect(!lowPanel.isVisible, "Selecting effort must close its popover")
            let highPanel = try await openPanel(main, thinking: true)
            click(NSPoint(x: 80, y: highPanel.frame.height - 60 - 3 * 33), in: highPanel)
            try await pause()
            try expect(ToolbarProbe.selection == "fixture/reasoner|xhigh", "Extra high thinking row did not update selection")
            try await chooseModel("Deep", in: openPanel(main))
            try expect(ToolbarProbe.selection == "fixture/deep|max", "Model switch must resolve unsupported effort to its own default")
            try await chooseModel("Plain", in: openPanel(main))
            try expect(ToolbarProbe.selection == "fixture/plain|nil", "A non-reasoning model must clear the selected effort")
            try await chooseModel("long", in: openPanel(main))
            try expect(ToolbarProbe.selection == "fixture/long|auto", "The extended model must select its reported default")
            let extended = try await openPanel(main, thinking: true)
            click(NSPoint(x: 80, y: extended.frame.height - 60 - 5 * 33), in: extended)
            try await pause()
            try expect(ToolbarProbe.selection == "fixture/long|xhigh", "Extended effort rows must be reachable")
            print("PASS: separate model/effort pickers, dismiss on selection, fallback and extended levels")
        }
        try await press("narrow")
        try checkLayout("narrow Chinese long model")
        try await press("english")
        try checkLayout("narrow English long model")
        let englishPanel = try await openPanel(main)
        try await closePanel(englishPanel)
        try await press("english")
        if !["qoder", "claude"].contains(agent) {
            let reset = try await openPanel(main)
            try await chooseModel("Reasoner", in: reset)
            try expect(ToolbarProbe.selection == "fixture/reasoner|xhigh", "Switching models must preserve a supported effort")
            try await press("offline")
            let offline = try await openPanel(main, thinking: true)
            let selection = ToolbarProbe.selection
            click(NSPoint(x: 65, y: offline.frame.height - 60), in: offline)
            try await pause()
            try expect(ToolbarProbe.selection == selection, "Offline controls must not modify selection")
            try await closePanel(offline)
            try await press("offline")
            try await press("running")
            let running = try await openPanel(main, thinking: true)
            click(NSPoint(x: 65, y: running.frame.height - 60), in: running)
            try await pause()
            if agent != "kimi" { try expect(ToolbarProbe.selection == selection, "Native running sessions must not change thinking") }
            if running.isVisible { try await closePanel(running) }
            try await press("running")
            try await press("empty")
            let empty = try await openPanel(main)
            try await closePanel(empty)
            try await press("empty")
            try await press("send")
            try expect(ToolbarProbe.payload.hasPrefix("model=fixture/reasoner thinking="), "Send must use the selected configuration")
            print("PASS: visible entry in offline/running/empty states and selected configuration at send")
        }
        result["status"] = "passed"
    } catch {
        result["error"] = error.localizedDescription
        print("FAIL:", error.localizedDescription)
    }
    if let path = ProcessInfo.processInfo.environment["COMPOSER_TOOLBAR_RESULT"] {
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        catch { print("FAIL: could not save result", error); fflush(stdout); exit(1) }
    }
    print(result)
    fflush(stdout)
    if result["status"] as? String != "passed" { exit(1) }
    NSApp.terminate(nil)
}
