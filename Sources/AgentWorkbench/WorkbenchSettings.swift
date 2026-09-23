import SwiftUI
import WorkbenchCore

struct WorkbenchSettings: View {
    @ObservedObject var model: WorkbenchModel
    @State private var showLocal = false
    @State private var showSSH = false
    @State private var showSummary = false
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @State private var editingHost: SSHHost?
    @State private var permissionModes: [SessionKind: String] = [:]
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage: AppLanguage = .system
    private let permissionProviders: [SessionKind] = [.kimi, .omp, .qoder, .codex]
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
            Section("新会话默认权限") {
                ForEach(permissionProviders, id: \.rawValue) { provider in
                    PermissionPicker(provider: provider,
                                     capability: PermissionCatalog.capability(for: provider, selected: permissionMode(for: provider)),
                                     layout: .form, allowsSelection: true) { mode in
                        permissionModes[provider] = mode
                        PermissionDefaults.set(mode, for: provider)
                    }
                }
                PermissionPicker(provider: .dsh,
                                 capability: PermissionCatalog.capability(for: .dsh),
                                 layout: .form, allowsSelection: false) { _ in }
                Button("恢复安全默认") {
                    for provider in permissionProviders {
                        PermissionDefaults.restoreSafeDefault(for: provider)
                        permissionModes[provider] = PermissionDefaults.mode(for: provider)
                    }
                }
                Text("只影响新建会话。Kimi 与 Qoder 可在会话输入框旁调整；OMP 与 Codex 的权限在创建时固定。")
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
        }.formStyle(.grouped).frame(width: 480, height: 760)
            .sheet(isPresented: $showLocal) { LocalAgentSetupSheet(model: model) }
            .sheet(isPresented: $showSummary) { ActivitySummarySettingsSheet() }
            .sheet(isPresented: $showSSH, onDismiss: model.setupDismissed) { AddHostSheet(model: model, host: editingHost) }
    }

    private func permissionMode(for provider: SessionKind) -> String? {
        permissionModes[provider] ?? PermissionDefaults.mode(for: provider)
    }
}
