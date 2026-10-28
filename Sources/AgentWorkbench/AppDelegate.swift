import AppKit
import WorkbenchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One owner for startup, every scene, draft flushing and shutdown.
    /// Scene appearance is not guaranteed for the nested AppKit workspace.
    let model = WorkbenchModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Idle unless Settings → 诊断 → 性能诊断 is on.
        FrameHitchMonitor.shared.install()
        model.start()
    }
    func applicationWillTerminate(_ notification: Notification) { CompanionWindowController.shared.shutdown(); model.shutdown() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do { try model.flushDrafts() }
        catch {
            let alert = NSAlert()
            alert.messageText = L("Drafts could not be saved")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("Keep Perch open"))
            alert.addButton(withTitle: L("Quit anyway"))
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !UserDefaults.standard.bool(forKey: "companion.background") }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { CompanionWindowController.shared.showMain() }; return true
    }
}
