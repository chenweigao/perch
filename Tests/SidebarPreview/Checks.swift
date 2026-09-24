import AppKit
import SwiftUI

extension View {
    func sidebarProbe(_ id: String, value: String = "") -> some View {
        accessibilityIdentifier(id).background(SidebarProbe(id: id, value: value).allowsHitTesting(false))
    }
}

private struct SidebarProbe: NSViewRepresentable {
    let id: String
    let value: String
    func makeNSView(context: Context) -> SidebarProbeView { SidebarProbeView() }
    func updateNSView(_ view: SidebarProbeView, context: Context) {
        view.id = id; view.value = value
        SidebarChecks.probes[id] = view
    }
    static func dismantleNSView(_ view: SidebarProbeView, coordinator: ()) {
        if SidebarChecks.probes[view.id] === view { SidebarChecks.probes.removeValue(forKey: view.id) }
    }
}

final class SidebarProbeView: NSView {
    var id = ""
    var value = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor enum SidebarChecks {
    static var probes: [String: SidebarProbeView] = [:]
    private static let sections = [("favorites", "preview.favorite"), ("groups", "preview.group"), ("recent", "preview.running")]
    private static let mode = ProcessInfo.processInfo.environment["SIDEBAR_CHECK_MODE"]

    static func configure() {
        guard mode != nil else { return }
        precondition(Bundle.main.bundleIdentifier == "dev.agentworkbench.sidebarpreview")
        setbuf(stdout, nil)
        if mode == "collapse" {
            for (id, _) in sections { UserDefaults.standard.removeObject(forKey: "sidebar.\(id).expanded") }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: sidebar interaction timed out\n", stderr)
            _exit(1)
        }
    }

    static func runIfRequested() async {
        guard let mode else { return }
        do {
            try await Task.sleep(for: .milliseconds(500))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "侧栏隔离验收" }) else {
                throw Failure("Missing sidebar preview window")
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if mode == "collapse" {
                try await collapse(window)
            } else if mode == "restore" {
                for (id, row) in sections {
                    try expectSection(id, expanded: false, in: window)
                    try require(element(row, in: window) == nil, "Collapsed \(id) restored its rows")
                }
                try require(element("preview.newGroup", in: window) != nil, "Missing collapsed group action")
                try require(element("preview.filterMenu", in: window) != nil, "Missing collapsed filter action")
                for (id, row) in sections {
                    try await toggle(id, expanded: true, fraction: 0.03, in: window)
                    try require(element(row, in: window) != nil, "Missing restored \(id) rows")
                }
                for (id, _) in sections { UserDefaults.standard.removeObject(forKey: "sidebar.\(id).expanded") }
            } else {
                throw Failure("Unknown sidebar check mode: \(mode)")
            }
            UserDefaults.standard.synchronize()
            print("PASS: sidebar \(mode) — real header clicks, independent sections and persisted state")
            NSApp.terminate(nil)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func collapse(_ window: NSWindow) async throws {
        for (id, row) in sections {
            try expectSection(id, expanded: true, in: window)
            try require(element(row, in: window) != nil, "Missing initial \(id) rows")
        }
        try click("preview.group", in: window)
        try await wait(in: window) { text("preview.selection", in: window).contains("Perch 开源") }
        for (id, row) in sections {
            try await toggle(id, expanded: false, fraction: 0.75, in: window)
            try require(element(row, in: window) == nil, "Collapsed \(id) still exposes its rows")
            for (other, _) in sections where other != id { try expectSection(other, expanded: true, in: window) }
            try require(text("preview.selection", in: window).contains("Perch 开源"), "Folding changed the selected page")
            try await toggle(id, expanded: true, fraction: 0.03, in: window)
            try require(element(row, in: window) != nil, "Expanding \(id) did not restore its rows")
        }
        try click("preview.reduceMotion", in: window)
        try await toggle("groups", expanded: false, fraction: 0.75, in: window)
        try click("preview.newGroup", in: window)
        try await wait(in: window) { text("preview.groupCreations", in: window).contains("1") }
        try expectSection("groups", expanded: false, in: window)
        try await toggle("recent", expanded: false, fraction: 0.75, in: window)
        try require(element("preview.allSessions", in: window) == nil, "Collapsed recents still exposes All Sessions")
        let keys = [(UInt16(119), "\u{F72B}"), (UInt16(124), "\u{F703}"),
                    (UInt16(119), "\u{F72B}"), (UInt16(36), "\r")]
        for (step, (keyCode, characters)) in keys.enumerated() {
            let timer = Timer(timeInterval: 0.2 + Double(step) * 0.15, repeats: false) { _ in
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: characters, charactersIgnoringModifiers: characters,
                                                isARepeat: false, keyCode: keyCode)!
                    NSApp.postEvent(event, atStart: false)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        try click("preview.filterMenu", in: window)
        try await wait(in: window) { text("preview.filter", in: window).contains("运行中") }
        try await Task.sleep(for: .milliseconds(200))
        try expectSection("recent", expanded: false, in: window)
        try expectSection("groups", expanded: false, in: window)
        try expectSection("favorites", expanded: true, in: window)
        try await toggle("recent", expanded: true, fraction: 0.03, in: window)
        try require(element("preview.running", in: window) != nil, "Filtered running session missing")
        try require(element("preview.completed", in: window) == nil, "Filter was lost on expansion")
        try require(element("preview.allSessions", in: window) != nil, "All Sessions did not return")
        try require(text("preview.selection", in: window).contains("Perch 开源"), "Header actions changed selection")
        try await toggle("recent", expanded: false, fraction: 0.75, in: window)
        try await toggle("favorites", expanded: false, fraction: 0.75, in: window)
        for (id, _) in sections { try expectSection(id, expanded: false, in: window) }
    }

    private static func toggle(_ id: String, expanded: Bool, fraction: CGFloat, in window: NSWindow) async throws {
        let row = sections.first { $0.0 == id }!.1
        try click("sidebar.section.\(id)", fraction: fraction, in: window)
        try await wait(in: window) {
            UserDefaults.standard.bool(forKey: "sidebar.\(id).expanded") == expanded &&
                (element(row, in: window) != nil) == expanded
        }
        try expectSection(id, expanded: expanded, in: window)
    }

    private static func expectSection(_ id: String, expanded: Bool, in window: NSWindow) throws {
        let stored = UserDefaults.standard.object(forKey: "sidebar.\(id).expanded") as? Bool ?? true
        try require(stored == expanded, "Incorrect persisted \(id) state")
        guard let section = element("sidebar.section.\(id)", in: window) else { throw Failure("Missing \(id) header") }
        try require(expanded ? section.bounds.height > 47 : abs(section.bounds.height - 47) < 1,
                    "Incorrect rendered \(id) height: \(section.bounds.height)")
    }

    private static func click(_ id: String, fraction: CGFloat = 0.5, in window: NSWindow) throws {
        guard let target = element(id, in: window) else { throw Failure("Missing click target: \(id)") }
        let frame = window.convertToScreen(target.convert(target.bounds, to: nil))
        let screenPoint = id.hasPrefix("sidebar.section.")
            ? NSPoint(x: frame.minX + 10 + (frame.width - 44) * fraction, y: frame.maxY - 28)
            : NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
        let point = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func element(_ id: String, in window: NSWindow) -> SidebarProbeView? {
        guard let view = probes[id], view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return view
    }

    private static func text(_ id: String, in window: NSWindow) -> String {
        element(id, in: window)?.value ?? ""
    }

    private static func wait(in window: NSWindow, until ready: () -> Bool) async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            if ready() { return }
        }
        throw Failure("Sidebar UI did not reach the expected state")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
