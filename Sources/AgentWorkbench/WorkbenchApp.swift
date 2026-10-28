import AppKit
import SwiftUI
import WorkbenchCore

#if !PERCH_ACCEPTANCE
@main
struct WorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: WorkbenchModel { delegate.model }
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage: AppLanguage = .system
    @AppStorage(AppAppearance.defaultsKey) private var appAppearance: AppAppearance = .system
    private var L: LocalizedUIStrings { LocalizedUIStrings(locale: appLanguage.resolvedLocale) }

    var body: some Scene {
        WindowGroup("Perch", id: "main") {
            WorkbenchView(model: model).preferredColorScheme(appAppearance.colorScheme)
                .frame(minWidth: 940, minHeight: 620)
                // The workspace paints its own Liquid Glass backdrop; the scene must not fill behind it.
                .containerBackground(Color.clear, for: .window)
                .background(CompanionRegistration(model: model))
                .environment(\.locale, appLanguage.resolvedLocale)
                .onAppear { AppLanguage.applyToSystem(appLanguage) }
                .task { await AppUpdateChecker.shared.checkThrottled() }
                .onChange(of: appLanguage) { _, value in
                    AppLanguage.applyToSystem(value)
                    model.refreshLocalizedCatalog()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandMenu(L("工作台")) {
                Button(L("任务浮窗")) { CompanionWindowController.shared.toggle() }
                Button(L("长任务托管")) { model.showFollowUps = true }
            }
            CommandGroup(replacing: .appInfo) {
                Button(L("About Perch")) {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Perch",
                        .credits: NSAttributedString(string: L("A home for your agents."))
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("新建会话")) { model.startNewTask() }.keyboardShortcut("n")
                Button(L("添加机器…")) { model.configureHost() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button(L("新建远端终端…")) { model.showNewTerminal = true }.keyboardShortcut("t")
                    .disabled(model.selectedConnection?.online != true)
            }
            CommandMenu(L("Conversation")) {
                Button(L("搜索项目与会话")) { CompanionWindowController.shared.showMain(); model.showSessionSearch = true }.keyboardShortcut("k")
                Button(L("Find in conversation")) {
                    if model.fileWindow.window?.isKeyWindow == true {
                        NotificationCenter.default.post(name: .init("PerchFindInFile"), object: nil)
                        return
                    }
                    model.showConversationFind = true
                    NotificationCenter.default.post(name: .init("PerchFocusFind"), object: nil)
                }.keyboardShortcut("f").disabled(!model.showFileViewer && !model.showKimi && !model.showNative)
                Button(L("Next match")) {
                    if model.fileWindow.window?.isKeyWindow == true { model.fileBrowser.findIndex += 1 }
                    else { NotificationCenter.default.post(name: .init("PerchFindNext"), object: 1) }
                }.keyboardShortcut("g").disabled(!model.showFileViewer && !model.showConversationFind)
                Button(L("Previous match")) {
                    if model.fileWindow.window?.isKeyWindow == true { model.fileBrowser.findIndex -= 1 }
                    else { NotificationCenter.default.post(name: .init("PerchFindNext"), object: -1) }
                }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!model.showFileViewer && !model.showConversationFind)
                Divider()
                Button(L("导出当前会话（Markdown）…")) { model.exportSelectedConversation(markdown: true) }
                    .disabled(!model.showKimi && !model.showNative)
                Button(L("导出当前会话（JSON）…")) { model.exportSelectedConversation(markdown: false) }
                    .disabled(!model.showKimi && !model.showNative)
                Divider()
                Button(L("Back")) { model.navigate(-1) }.keyboardShortcut("[", modifiers: .command).disabled(!model.canNavigate(-1))
                Button(L("Forward")) { model.navigate(1) }.keyboardShortcut("]", modifiers: .command).disabled(!model.canNavigate(1))
                Button(L("下一个待处理会话")) { model.nextAttentionTask() }.keyboardShortcut("j", modifiers: [.command, .shift])
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
        MenuBarExtra("Perch", systemImage: "bird") {
            Button(L("任务浮窗 · ⌃⌥P")) { CompanionWindowController.shared.show() }
            Button(L("打开工作台")) { model.showHome(); CompanionWindowController.shared.showMain() }
            Button(L("长任务托管")) { model.showFollowUps = true; CompanionWindowController.shared.showMain() }
            Divider()
            Button(L("退出 Perch")) { NSApp.terminate(nil) }
        }
        Settings { WorkbenchSettings(model: model).environment(\.locale, appLanguage.resolvedLocale) }
    }
}

#endif
