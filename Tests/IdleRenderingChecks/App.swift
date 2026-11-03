import AppKit
import SwiftUI
import QuartzCore

// Production indicator and shimmer, with only their theme color tokens stubbed.
enum WorkbenchTheme { static let quietNS = NSColor.secondaryLabelColor; static let inkNS = NSColor.labelColor }
@MainActor final class State: ObservableObject {
    @Published var running = true
    @Published var title = "Preparing a task"
}
struct Fixture: View {
    @ObservedObject var state: State
    var body: some View {
        HStack {
            if state.running {
                ForEach(0..<24) { _ in PerchBusyIndicator(size: 24) }
                ShimmerGlint(text: state.title, size: 14).frame(width: 150, height: 24)
            }
        }.padding(30)
    }
}
func require(_ condition: Bool, _ message: String = "Expected lifecycle state") {
    if !condition { print("FAIL: " + message); exit(1) }
}
@main struct IdleRenderingChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let state = State()
        let host = NSHostingView(rootView: Fixture(state: state))
        host.wantsLayer = true
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 800, height: 160),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.contentView = host
        func animations(_ layer: CALayer?) -> Int {
            guard let layer else { return 0 }
            return (layer.animationKeys() ?? []).filter { (layer.animation(forKey: $0)?.repeatCount ?? 0) > 1000 }.count
                + (layer.sublayers ?? []).reduce(0) { $0 + animations($1) }
                + animations(layer.mask)
        }
        func hasAnimation(_ key: String, in layer: CALayer?) -> Bool {
            guard let layer else { return false }
            return layer.animation(forKey: key) != nil
                || (layer.sublayers ?? []).contains { hasAnimation(key, in: $0) }
                || (layer.mask.map { hasAnimation(key, in: $0) } ?? false)
        }
        func bothAnimate() -> Bool { hasAnimation("turn", in: host.layer) && hasAnimation("sweep", in: host.layer) }
        Task { @MainActor in
            @MainActor func wait() async { try? await Task.sleep(for: .milliseconds(600)); host.layoutSubtreeIfNeeded(); CATransaction.flush() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await wait()
            require(NSApp.isActive && bothAnimate(), "Active visible indicators must animate")
            // Drive the same notifications AppKit delivers on a visible window.
            // NSApp.deactivate() alone need not hand focus to another app in CI.
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            await wait()
            require(window.isVisible && animations(host.layer) == 0,
                         "A visible inactive window must not retain repeating animations")
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            await wait()
            require(bothAnimate(), "Activation must resume without a new network event")
            window.orderOut(nil)
            await wait()
            require(animations(host.layer) == 0, "Detached/occluded windows must not retain repeating animations")
            state.title = "Reading a file"
            await wait()
            require(animations(host.layer) == 0, "Title changes while idle must not restart animation")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await wait()
            require(bothAnimate(), "Visible effects must resume the latest title")
            host.isHidden = true
            await wait()
            require(animations(host.layer) == 0, "Hidden ancestors must suspend animation")
            host.isHidden = false
            await wait()
            require(bothAnimate())
            NSApp.hide(nil)
            await wait()
            require(animations(host.layer) == 0, "Application hiding must suspend animation")
            state.title = "Thinking"
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            await wait()
            require(bothAnimate(), "Application activation must resume")
            state.running = false
            await wait()
            require(animations(host.layer) == 0, "A completed turn must stay stopped")
            window.orderOut(nil)
            print("PASS: production sun and shimmer animate only in an active, visible window; title changes, hide/unhide and completion remain correct")
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
}
