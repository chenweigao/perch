import AppKit
import SwiftUI
import WorkbenchCore

@main struct LocalizationPreviewApp: App {
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .zhHans
    var body: some Scene {
        WindowGroup("Localization Preview") {
            PreviewWorkspace().equatable().environment(\.locale, language.resolvedLocale)
        }.defaultSize(width: 1050, height: 720)
    }
}
private struct PreviewWorkspace: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { true }
    var body: some View {
        WorkspaceSplitView(newConversation: {}, sidebar: { PreviewSidebar() }, header: { PreviewHeader() }, actions: { Text("当前会话") }, content: { PreviewControls() })
    }
}
private struct PreviewHeader: View {
    @UILocalization private var L
    var body: some View { Text(L("工作台")) }
}
private struct PreviewSidebar: View {
    @UILocalization private var L
    var body: some View {
        WorkspaceSidebarShell(page: .home, attentionCount: 2, environmentSummary: L("\(3) 个 SSH"), onSearch: {}, onHome: {}, onInbox: {}, onArchive: {}) {
            Text("最近会话")
            Text(L("未命名会话"))
            Text(L(key: "等待确认"))
        } environments: { Text("环境与 Agent") }
    }
}
private struct PreviewControls: View {
    @UILocalization private var L
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .zhHans
    @State private var count = 0
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("English") { language = .en }
                Button("中文") { language = .zhHans }
                Button("System") { language = .system }
            }
            Button("Retain state: \(count)") { count += 1 }
            Text("工作台")
            Text(L("\(3) 个 SSH"))
            Text("Offline fixture — no sessions or agents are opened.")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
