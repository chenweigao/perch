import AppKit
import SwiftUI
import WorkbenchCore

@main
struct WorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = WorkbenchModel()
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage: AppLanguage = .system
    private var L: LocalizedUIStrings { LocalizedUIStrings(locale: appLanguage.resolvedLocale) }
    var body: some Scene {
        WindowGroup("Perch") {
            WorkbenchView(model: model).preferredColorScheme(.light)
                .frame(minWidth: 940, minHeight: 620)
                .environment(\.locale, appLanguage.resolvedLocale)
                .onAppear { delegate.model = model; model.start(); AppLanguage.applyToSystem(appLanguage) }
                .onChange(of: appLanguage) { _, value in
                    AppLanguage.applyToSystem(value)
                    model.refreshLocalizedCatalog()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button(L("About Perch")) {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Perch",
                        .credits: NSAttributedString(string: L("A home for your agents."))
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("新建任务…")) { model.showNewKimi = true }.keyboardShortcut("n")
                Button(L("添加机器…")) { model.showAddHost = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button(L("新建远端终端…")) { model.showNewTerminal = true }.keyboardShortcut("t")
                    .disabled(!model.selectedConnection.online)
            }
            CommandMenu(L("Conversation")) {
                Button(L("搜索任务")) { model.showSessionSearch = true }.keyboardShortcut("k")
                Button(L("Find in conversation")) {
                    model.showConversationFind = true
                    NotificationCenter.default.post(name: .init("PerchFocusFind"), object: nil)
                }.keyboardShortcut("f").disabled(!model.showKimi && !model.showNative)
                Button(L("Next match")) { NotificationCenter.default.post(name: .init("PerchFindNext"), object: 1) }.keyboardShortcut("g").disabled(!model.showConversationFind)
                Button(L("Previous match")) { NotificationCenter.default.post(name: .init("PerchFindNext"), object: -1) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!model.showConversationFind)
                Divider()
                Button(L("Back")) { model.navigate(-1) }.keyboardShortcut("[", modifiers: .command).disabled(!model.canNavigate(-1))
                Button(L("Forward")) { model.navigate(1) }.keyboardShortcut("]", modifiers: .command).disabled(!model.canNavigate(1))
                Button(L("Next task needing attention")) { model.nextAttentionTask() }.keyboardShortcut("j", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button(L("终端显示信息…")) { model.inspectRendering() }.disabled(model.selectedTerminal == nil)
            }
            CommandGroup(after: .sidebar) {
                Button(L("切换当前会话置顶")) {
                    if let reference = model.selectedReference { model.toggleStar(reference) }
                }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.selectedReference == nil)
                Button(L("重新连接机器")) { model.reconnectSelectedEnvironment() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button(L("关闭当前本地视图")) {
                    if let id = model.tabs.selectedID { model.close(id) }
                }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
        Settings { WorkbenchSettings(model: model).environment(\.locale, appLanguage.resolvedLocale) }
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
        do { try model?.flushDrafts() }
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
