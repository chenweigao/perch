import SwiftUI
import WorkbenchCore

struct WorkbenchSettings: View {
    @ObservedObject var model: WorkbenchModel
    @State private var showLocal = false
    @State private var showSSH = false
    @State private var showSummary = false
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @State private var editingHost: SSHHost?
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage: AppLanguage = .system
    @AppStorage(CodexPermissionMode.defaultsKey) private var codexPermissionMode: CodexPermissionMode = .ask
    var body: some View {
        Form {
            Section("语言 / Language") {
                Picker("界面语言", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
                }
                .onChange(of: appLanguage) { _, newValue in AppLanguage.applyToSystem(newValue) }
            }
            Section("Agent 与执行环境") {
                Button("管理本机 Agent…") { showLocal = true }
                Button("添加 SSH 环境…") { editingHost = nil; showSSH = true }
                ForEach(model.connections) { connection in
                    Button(connection.host.name) { editingHost = connection.host; showSSH = true }
                }
                Text("远程连接沿用本机 SSH 配置。连接、重连与移除机器都在侧边栏的环境入口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Codex 权限") {
                Picker("新任务默认权限", selection: $codexPermissionMode) {
                    ForEach(CodexPermissionMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                Text(codexPermissionMode.detail).font(.caption).foregroundStyle(.secondary)
                Text("仅影响新建 Codex 任务；已有任务可在输入框旁调整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Task notifications") {
                Toggle("Notify when Perch is in the background", isOn: $model.notificationsEnabled)
                Text("Completed responses, requests for input, and failures. Click a notification to open the task.").font(.caption).foregroundStyle(.secondary)
                if let error = model.notificationError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section("界面") {
                HStack {
                    Button("配置活动摘要…") { showSummary = true }
                    Spacer()
                    Text(summarySettings.configuration.enabled ? "已开启" : "默认关闭").foregroundStyle(.secondary)
                    if summarySettings.configuration.enabled { Button("关闭") { summarySettings.disable() } }
                }
                Text("侧边栏可拖动调整宽度，系统会记住位置。透明度与动态效果遵循 macOS 辅助功能设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 460, height: 620)
            .sheet(isPresented: $showLocal) { LocalAgentSetupSheet(model: model) }
            .sheet(isPresented: $showSummary) { ActivitySummarySettingsSheet() }
            .sheet(isPresented: $showSSH, onDismiss: model.setupDismissed) { AddHostSheet(model: model, host: editingHost) }
    }
}
