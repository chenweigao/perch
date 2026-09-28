import AppKit
import SwiftUI
import WorkbenchCore

/// Visual fixture for the inline new-task page. Seeds one fake host plus draft
/// defaults into this preview's own defaults domain; nothing contacts a network.
@main struct NewTaskPreviewApp: App {
    @NSApplicationDelegateAdaptor(NewTaskPreviewDelegate.self) private var delegate
    @StateObject private var model: WorkbenchModel

    init() {
        let host = SSHHost(name: "dev-env", destination: "fixture.invalid", enabledAgents: [.kimi, .omp, .codex],
                           autoConnectSSH: false, autoConnectHerdr: false)
        UserDefaults.standard.set(try? JSONEncoder().encode([host]), forKey: "hosts")
        UserDefaults.standard.set("/opt/demo/perch", forKey: "new.cwd.\(host.id.uuidString)")
        UserDefaults.standard.set("把登录页改成两栏布局，左侧放品牌插画", forKey: "new.task.prompt")
        let model = WorkbenchModel()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup("新建任务预览", id: ProcessInfo.processInfo.environment["PERCH_PREVIEW_NARROW"] == "1" ? "narrow-workflow" : "regular-workflow") {
            NewTaskView(model: model, native: model.native, kimi: model.kimi)
                .preferredColorScheme(.light)
        }.defaultSize(width: ProcessInfo.processInfo.environment["PERCH_PREVIEW_NARROW"] == "1" ? 620 : 1100, height: 760)
    }
}

final class NewTaskPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Screenshot helper: the window number doubles as the CGWindowID.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let window = NSApp.windows.first {
                print("WINDOW_ID=\(window.windowNumber)")
                fflush(stdout)
            }
        }
    }
}
