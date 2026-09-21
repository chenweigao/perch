import AppKit
import SwiftUI

@main
struct WorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = WorkbenchModel()
    var body: some Scene {
        WindowGroup("Perch") {
            WorkbenchView(model: model).preferredColorScheme(.light)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear { delegate.model = model; model.start() }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Perch") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Perch",
                        .credits: NSAttributedString(string: "A home for your agents.")
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("新建任务…") { model.showNewKimi = true }.keyboardShortcut("n")
                Button("添加机器…") { model.showAddHost = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("新建远端终端…") { model.showNewTerminal = true }.keyboardShortcut("t")
                    .disabled(!model.selectedConnection.online)
            }
            CommandGroup(after: .help) {
                Button("终端显示信息…") { model.inspectRendering() }.disabled(model.selectedTerminal == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("切换当前会话置顶") {
                    if let reference = model.selectedReference { model.toggleStar(reference) }
                }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.selectedReference == nil)
                Button("重新连接机器") { model.selectedConnection.connect() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("关闭当前本地视图") {
                    if let id = model.tabs.selectedID { model.close(id) }
                }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
        Settings { WorkbenchSettings(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkbenchModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = model?.native.queue.exitWarningCount ?? 0
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有 \(count) 条消息待发送或结果未确认"
        alert.informativeText = "退出会丢失这些消息的本地队列记录。已交给远端的任务会继续运行；未确认的消息请先核对会话。"
        alert.addButton(withTitle: "留在 Perch")
        alert.addButton(withTitle: "退出并丢弃本地记录")
        if alert.runModal() == .alertFirstButtonReturn {
            sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
