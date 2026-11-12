import AppKit
import SwiftUI

@MainActor
enum ToolbarProbe {
    static var controls: [String: NSView] = [:]
    static var selection = ""
    static var payload = ""
    static var stops = 0
    static var sends = 0
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
private func focus(_ window: NSWindow) {
    // A physical click activates its app; a synthetic window event does not.
    // Never show a dismissed popover just to make an assertion pass.
    guard window.isVisible else { return }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
}

@MainActor
private func click(_ point: NSPoint, in window: NSWindow) {
    focus(window)
    for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        window.sendEvent(event)
    }
}

@MainActor
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition {
        print("Window evidence", "active", NSApp.isActive, "key", NSApp.keyWindow?.windowNumber as Any,
              "windows", NSApp.windows.map { "\($0.windowNumber):visible=\($0.isVisible):key=\($0.isKeyWindow)" })
        throw NSError(domain: "ToolbarChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
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
    for _ in 0..<2 {
        click(view.convert(point, to: nil), in: main)
        for _ in 0..<40 {
            if let panel = NSApp.windows.first(where: { $0.isVisible && $0 !== main }) {
                try await pause()
                return panel
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    throw NSError(domain: "Model panel did not open", code: 1)
}

@MainActor
private func expectDismissed(_ panel: NSWindow, _ message: String) async throws {
    for _ in 0..<40 where panel.isVisible {
        try await Task.sleep(for: .milliseconds(50))
    }
    try expect(!panel.isVisible, message)
}

@MainActor
private func closePanel(_ panel: NSWindow) async throws {
    focus(panel)
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: panel.windowNumber, context: nil,
                                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                isARepeat: false, keyCode: 53)!
    panel.sendEvent(event)
    try await pause()
    if panel.isVisible { panel.sendEvent(event) }
    try await expectDismissed(panel, "Escape must dismiss the panel")
}

@MainActor
private func chooseModel(_ query: String, in panel: NSWindow) async throws {
    focus(panel)
    let field = views(panel.contentView!).compactMap { $0 as? NSTextField }.first(where: \.isEditable)!
    field.selectText(nil)
    (field.currentEditor() as! NSTextView).insertText(query, replacementRange: NSRange(location: NSNotFound, length: 0))
    try await pause()
    for (characters, code) in [("\u{f701}", UInt16(125)), ("\r", UInt16(36))] {
        try expect(panel.isVisible, "The model panel must remain open before a selection key")
        focus(panel)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        panel.sendEvent(event)
        try await pause()
    }
    try expect(panel.isVisible, "Choosing a model must keep the PI model/reasoning surface open")
    try await closePanel(panel)
}

@MainActor
private func chooseThinking(_ index: Int, in panel: NSWindow) async throws {
    focus(panel)
    guard let slider = views(panel.contentView!).compactMap({ $0 as? NSSlider }).first else {
        throw NSError(domain: "Missing reasoning slider", code: 1)
    }
    let tick = slider.rectOfTickMark(at: index)
    let bar = (slider.cell as! NSSliderCell).barRect(flipped: slider.isFlipped)
    // AppKit places endpoint tick centers at x=0 and x=width. A hit on the
    // boundary can miss the hosted slider after coordinate rounding. Use the
    // interior of the same endpoint segment, as a reader clicking its label does.
    let inset = max(1, slider.knobThickness / 2)
    let x = min(slider.bounds.maxX - inset, max(slider.bounds.minX + inset, tick.midX))
    let point = slider.convert(NSPoint(x: x, y: bar.midY), to: nil)
    let before = slider.doubleValue
    // Native sliders run a tracking loop on mouse-down; queue the release first.
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    NSApp.postEvent(up, atStart: true)
    panel.sendEvent(down)
    try await pause()
    print("Reasoning pointer", index, "value", before, "->", slider.doubleValue,
          "enabled", slider.isEnabled, "frame", slider.frame, "tick", tick, "bar", bar)
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
        try expect(frames[0].width >= 190 && frames[0].width <= 320, "Long model names must retain the PI label/badge/caret width")
    }
    print("PASS layout", label, frames)
}

@MainActor
func runToolbarChecks() async {
    let agent = ProcessInfo.processInfo.environment["COMPOSER_PREVIEW_AGENT"] ?? "kimi"
    let newTask = ProcessInfo.processInfo.environment["COMPOSER_PREVIEW_NEW_TASK"] == "1"
    var result: [String: Any] = ["agent": agent, "status": "failed"]
    do {
        for _ in 0..<100 {
            if ToolbarProbe.controls["model"]?.window != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let main = ToolbarProbe.controls["model"]?.window else { throw NSError(domain: "No preview window", code: 1) }
        focus(main)
        for _ in 0..<40 {
            if NSApp.isActive && main.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try expect(NSApp.isActive && main.isKeyWindow, "The preview must have keyboard focus before testing controls")
        try await pause()
        try checkLayout("wide Chinese")
        let panel = try await openPanel(main)
        if agent == "claude" && !newTask {
            try expect(!views(panel.contentView!).contains { $0 is NSTextField }, "Existing Claude sessions must keep model controls read-only")
            try await closePanel(panel)
        } else {
            try await closePanel(panel)
            let lowPanel = try await openPanel(main, thinking: true)
            try await chooseThinking(0, in: lowPanel)
            try expect(ToolbarProbe.selection == "fixture/reasoner|low", "Low reasoning stop did not update selection")
            try expect(lowPanel.isVisible, "Selecting reasoning must keep its menu open")
            let slider = views(lowPanel.contentView!).compactMap { $0 as? NSSlider }.first!
            lowPanel.makeFirstResponder(slider)
            let end = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: lowPanel.windowNumber,
                                      context: nil, characters: "\u{f72b}", charactersIgnoringModifiers: "\u{f72b}",
                                      isARepeat: false, keyCode: 119)!
            lowPanel.sendEvent(end); try await pause()
            try expect(ToolbarProbe.selection == "fixture/reasoner|xhigh", "End must reach the last reasoning stop")
            try await closePanel(lowPanel)
            try await chooseModel("Deep", in: openPanel(main))
            try expect(ToolbarProbe.selection == "fixture/deep|max", "Model switch must resolve unsupported effort to its own default")
            try await chooseModel("Plain", in: openPanel(main))
            try expect(ToolbarProbe.selection == "fixture/plain|nil", "A non-reasoning model must clear the selected effort")
            try await chooseModel("long", in: openPanel(main))
            try expect(ToolbarProbe.selection == "fixture/long|auto", "The extended model must select its reported default")
            let extended = try await openPanel(main, thinking: true)
            try await chooseThinking(5, in: extended)
            try expect(ToolbarProbe.selection == "fixture/long|xhigh", "Extended reasoning stops must be reachable")
            try await closePanel(extended)
            print("PASS: combined model/reasoning menu, pointer/keyboard stops, fallback and extended levels")
        }
        try await press("narrow")
        try checkLayout("narrow Chinese long model")
        try await press("english")
        try checkLayout("narrow English long model")
        let englishPanel = try await openPanel(main)
        try await closePanel(englishPanel)
        try await press("english")
        if agent != "claude" || newTask {
            let reset = try await openPanel(main)
            try await chooseModel("Reasoner", in: reset)
            try expect(ToolbarProbe.selection == "fixture/reasoner|xhigh", "Switching models must preserve a supported effort")
            try await press("offline")
            let offline = try await openPanel(main, thinking: true)
            let selection = ToolbarProbe.selection
            try await chooseThinking(0, in: offline)
            try expect(ToolbarProbe.selection == selection, "Offline controls must not modify selection")
            try await closePanel(offline)
            try await press("offline")
            try await press("running")
            let running = try await openPanel(main, thinking: true)
            try await chooseThinking(0, in: running)
            try expect(ToolbarProbe.selection == selection, "Native running sessions must not change thinking")
            if running.isVisible { try await closePanel(running) }
            try await press("running")
            try await press("empty")
            let empty = try await openPanel(main)
            try await closePanel(empty)
            try await press("empty")
            try await press("send")
            try expect(ToolbarProbe.payload.hasPrefix("model=fixture/reasoner thinking="), "Send must use the selected configuration")
            print("PASS: visible entry in offline/running/empty states and selected configuration at send")
            // Exercise the native control after send clears the draft: the 28pt
            // stop target must survive running, attention and stopping.
            func animatedArcs(_ layer: CALayer?) -> Int {
                guard let layer else { return 0 }
                return (layer.animation(forKey: "strokeStart") == nil ? 0 : 1)
                    + (layer.sublayers ?? []).reduce(0) { $0 + animatedArcs($1) }
            }
            func arcs() -> Int {
                views(main.contentView!).reduce(0) { $0 + animatedArcs($1.layer) }
            }
            let actionSize = ToolbarProbe.controls["send"]!.bounds.size
            try expect(actionSize == CGSize(width: 28, height: 28), "Running action must keep its 28pt target")
            try expect(arcs() == 0, "PI's stop control stays static while the turn runs")
            try await press("draft")
            try await press("send")
            try expect(ToolbarProbe.sends == 2 && ToolbarProbe.stops == 0, "A running composer with a draft must send")
            try await press("finish-turn")
            try await press("send")
            try expect(ToolbarProbe.sends == 3 && ToolbarProbe.stops == 0, "Natural completion must restore Send")
            for control in ["waiting", "offline"] {
                try await press(control)
                try expect(arcs() == 0, "No chase while " + control)
                try expect(ToolbarProbe.controls["send"]!.bounds.size == actionSize, "State changes must not resize the action")
                try await press(control)
                try expect(arcs() == 0, "The primary action must stay static after " + control)
            }
            try await press("send")
            try expect(ToolbarProbe.stops == 1 && arcs() == 0, "Stop must fire once and end the activity chase")
            try await press("send")
            try expect(ToolbarProbe.stops == 1, "Stopping control must reject repeated requests")
            try await press("confirm-stop")
            try expect(arcs() == 0 && ToolbarProbe.controls["send"]!.bounds.size == actionSize,
                       "Completion must restore idle without moving the control")
            print("PASS: draft sends while running, natural completion, stop confirmation, stable static action")
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
