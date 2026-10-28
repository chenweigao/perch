import AppKit
import Foundation
import WorkbenchCore

/// Launch and termination must work before any SwiftUI scene appears.
@MainActor func checkAppStartup() throws {
    let defaults = UserDefaults.standard
    let previousHosts = defaults.data(forKey: "hosts")
    defer {
        if let previousHosts { defaults.set(previousHosts, forKey: "hosts") }
        else { defaults.removeObject(forKey: "hosts") }
    }
    let host = SSHHost(name: "Startup fixture", destination: "startup.invalid", enabledAgents: [.kimi, .codex])
    defaults.set(try JSONEncoder().encode([host]), forKey: "hosts")
    let delegate = AppDelegate()
    let model = delegate.model
    precondition(!model.kimi.connecting && !model.native.wantsConnection)

    // No onAppear, view task, scene registration, or suspension: connection tasks
    // are cancelled below before they can perform any SSH or HTTP operations.
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    precondition(delegate.model === model)
    precondition(model.kimi.connecting && model.native.wantsConnection,
                 "Launch must start the model used by scenes, without appearance callbacks")
    model.native.drafts["startup-draft"] = "保留未发送的草稿"
    precondition(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    let restored = try DraftFile.applicationFile(namespace: "native-\(host.id)").load()
    precondition(restored.text["startup-draft"] == "保留未发送的草稿",
                 "Termination must flush the same model even before a scene appears")
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    precondition(!model.kimi.connecting && !model.native.wantsConnection,
                 "Termination must cancel client connections without scene registration")
    print("PASS: application-owned model starts and flushes/shuts down without scene appearance")
}
