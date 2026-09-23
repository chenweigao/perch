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
    private let permissionProviders: [SessionKind] = [.kimi, .omp, .qoder, .codex, .claude]
    var body: some View {
        Form {
            Section {
                Picker("界面语言", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
                }
                .onChange(of: appLanguage) { _, newValue in AppLanguage.applyToSystem(newValue) }
            } header: {
                SettingsSectionHeader("语言 / Language", systemImage: "globe", tint: .blue)
            }
            Section {
                SettingsRow(action: { showLocal = true }) {
                    HostIdentityIcon(hostID: ExecutionEnvironment.localHostID).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("本机 Agent").foregroundStyle(.primary)
                        localAgentStatus
                    }
                }
                ForEach(model.connections) { connection in
                    VStack(alignment: .leading, spacing: 10) {
                        HostSettingsRow(connection: connection) {
                            editingHost = connection.host
                            showSSH = true
                        }
                        if let agents = model.agentConnections(for: connection.id) {
                            HostConnectionControls(model: model, connection: connection,
                                                   kimi: agents.kimi, native: agents.native)
                        }
                    }
                }
                Button { editingHost = nil; showSSH = true } label: {
                    Label("添加 SSH 环境…", systemImage: "plus")
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } header: {
                SettingsSectionHeader("Agent 与执行环境", systemImage: "server.rack", tint: .teal)
            } footer: {
                Text("开启自动连接后立即连接，并在 Perch 启动时连接。关闭会断开当前连接；也可用按钮临时连接或断开，不改变启动偏好。远端任务继续运行。")
            }
            Section {
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
                HStack {
                    Spacer()
                    Button("恢复安全默认") {
                        for provider in permissionProviders {
                            PermissionDefaults.restoreSafeDefault(for: provider)
                            permissionModes[provider] = PermissionDefaults.mode(for: provider)
                        }
                    }
                }
            } header: {
                SettingsSectionHeader("新会话默认权限", systemImage: "lock.shield", tint: .orange)
            } footer: {
                Text("只影响新建会话。Kimi、Qoder 与 Claude Code 可在会话输入框旁调整；OMP 与 Codex 的权限在创建时固定。")
            }
            Section {
                Toggle("Notify when Perch is in the background", isOn: $model.notificationsEnabled)
                if let error = model.notificationError { Text(error).font(.caption).foregroundStyle(.orange) }
            } header: {
                SettingsSectionHeader("Task notifications", systemImage: "bell.badge", tint: .red)
            } footer: {
                Text("Completed responses, requests for input, and failures. Click a notification to open the task.")
            }
            Section {
                SettingsRow(action: { showSummary = true }) {
                    Image(systemName: "sparkles").frame(width: 20).foregroundStyle(.secondary)
                    Text("活动叙事").foregroundStyle(.primary)
                } trailing: {
                    (summarySettings.configuration.enabled ? Text("已开启") : Text("默认关闭"))
                        .font(.caption)
                        .foregroundStyle(summarySettings.configuration.enabled ? Color.green : Color.secondary)
                }
                if summarySettings.configuration.enabled {
                    Button("关闭活动叙事") { summarySettings.disable() }
                }
            } header: {
                SettingsSectionHeader("界面", systemImage: "paintbrush", tint: .purple)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("侧边栏可拖动调整宽度，系统会记住位置。透明度与动态效果遵循 macOS 辅助功能设置。")
                    Text(verbatim: "Perch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
        }.formStyle(.grouped).frame(width: 560, height: 740)
            .sheet(isPresented: $showLocal) { LocalAgentSetupSheet(model: model) }
            .sheet(isPresented: $showSummary) { ActivitySummarySettingsSheet() }
            .sheet(isPresented: $showSSH, onDismiss: model.setupDismissed) { AddHostSheet(model: model, host: editingHost) }
    }

    @ViewBuilder private var localAgentStatus: some View {
        switch model.localOMP {
        case .found(_, let version):
            Label("已找到 omp \(version)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .unusable:
            Label("找到了可执行文件，但无法使用", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .missing:
            Text("未找到本机 omp").font(.caption).foregroundStyle(.secondary)
        case nil:
            Text("尚未检测。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func permissionMode(for provider: SessionKind) -> String? {
        permissionModes[provider] ?? PermissionDefaults.mode(for: provider)
    }
}

/// Section title with a small colored symbol tile, in the spirit of System Settings.
private struct SettingsSectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color

    init(_ title: LocalizedStringKey, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

private struct HostSettingsRow: View {
    @ObservedObject var connection: HostConnection
    let action: () -> Void

    var body: some View {
        SettingsRow(action: action) {
            HostIdentityIcon(hostID: connection.id).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.host.name).foregroundStyle(.primary)
                Text(connection.host.destination).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HostConnectionControls: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var connection: HostConnection
    @ObservedObject var kimi: KimiConnection
    @ObservedObject var native: NativeAgentConnection

    private var sshRequested: Bool { kimi.connecting || native.wantsConnection }
    private var sshOnline: Bool {
        (!connection.host.enabledAgents.contains(.kimi) || kimi.online) &&
        (!connection.host.hasNativeAgents || native.online)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if connection.host.enabledAgents.contains(.kimi) || connection.host.hasNativeAgents {
                connectionRow("SSH Agent", online: sshOnline, requested: sshRequested,
                              autoConnect: Binding(get: { connection.host.autoConnectSSH },
                                  set: { model.setAutoConnect($0, for: connection.id, herdr: false) })) {
                    if sshRequested { model.disconnectSSH(connection.id) }
                    else { model.connectSSH(connection.id) }
                }
            }
            if connection.host.enabledAgents.contains(.terminal) {
                connectionRow("Herdr", online: connection.online, requested: connection.wantsConnection,
                              autoConnect: Binding(get: { connection.host.autoConnectHerdr },
                                  set: { model.setAutoConnect($0, for: connection.id, herdr: true) })) {
                    if connection.wantsConnection { model.disconnectHerdr(connection.id) }
                    else { connection.connect() }
                }
            }
        }.padding(.leading, 36)
    }

    private func connectionRow(_ title: String, online: Bool, requested: Bool,
                               autoConnect: Binding<Bool>, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title).fontWeight(.medium)
                Circle().fill(online ? Color.green : requested ? Color.orange : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                if online { Text("已连接").foregroundStyle(.secondary) }
                else if requested { Text("连接中").foregroundStyle(.secondary) }
                else { Text("未连接").foregroundStyle(.secondary) }
                Spacer()
                Button(action: action) {
                    if requested { Text("断开") } else { Text("连接") }
                }.buttonStyle(.bordered)
            }
            Toggle("启动时自动连接", isOn: autoConnect)
                .toggleStyle(.switch).controlSize(.mini)
                .accessibilityLabel(Text("\(title) 启动时自动连接"))
        }.font(.caption)
    }
}

/// Full-width row that stays visually quiet until hovered, then opens a sheet on click.
private struct SettingsRow<Content: View, Trailing: View>: View {
    let action: () -> Void
    let content: Content
    let trailing: Trailing
    @State private var hovered = false

    init(action: @escaping () -> Void,
         @ViewBuilder content: () -> Content,
         @ViewBuilder trailing: () -> Trailing) {
        self.action = action
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                content
                Spacer(minLength: 8)
                trailing
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(hovered ? 0.05 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

private extension SettingsRow where Trailing == EmptyView {
    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(action: action, content: content) { EmptyView() }
    }
}
