import SwiftUI
import WorkbenchCore

struct WorkbenchSettings: View {
    @Bindable var model: WorkbenchModel
    @AppStorage("companion.background") private var background = false
    @State private var showLocal = false
    @State private var showSSH = false
    @State private var showSummary = false
    @State private var diagnosticsOn = PerfDiagnostics.shared.enabled
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @State private var editingHost: SSHHost?
    @State private var permissionModes: [SessionKind: String] = [:]
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage: AppLanguage = .system
    @AppStorage(AppAppearance.defaultsKey) private var appAppearance: AppAppearance = .system
    @UILocalization private var L
    private let readingSize = ReadingBodySize.shared
    private let permissionProviders: [SessionKind] = [.kimi, .omp, .qoder, .qoderintl, .codex, .claude]
    @AppStorage("settings.pane") private var pane = SettingsPane.agents
    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                SettingsSectionHeader(pane.title, systemImage: pane.systemImage, tint: pane.tint)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Form {
                switch pane {
                case .language: languagePane
                case .agents: agentsPane
                case .permissions: permissionsPane
                case .notifications: notificationsPane
                case .appearance: appearancePane
                case .diagnostics: diagnosticsPane
                case .about: aboutPane
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(width: 800, height: 740)
        .sheet(isPresented: $showLocal) { LocalAgentSetupSheet(model: model) }
        .sheet(isPresented: $showSummary) { ActivitySummarySettingsSheet() }
        .sheet(isPresented: $showSSH, onDismiss: model.setupDismissed) { AddHostSheet(model: model, host: editingHost) }
    }

    private var languagePane: some View {
        Section {
            Picker("界面语言", selection: $appLanguage) {
                ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
            }
            .onChange(of: appLanguage) { _, newValue in AppLanguage.applyToSystem(newValue) }
        }
    }

    private var agentsPane: some View {
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
                        if connection.host.isLocal { showLocal = true }
                        else { editingHost = connection.host; showSSH = true }
                    }
                    if let agents = model.agentConnections(for: connection.id) {
                        HostConnectionControls(model: model, connection: connection,
                                               kimi: agents.kimi, native: agents.native)
                    }
                }
            }
            Button { editingHost = nil; showSSH = true } label: {
                Label("添加机器…", systemImage: "plus")
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(WorkbenchTheme.accent)
        } footer: {
            Text("开启自动连接后立即连接，并在 Perch 启动时连接。关闭会断开当前连接；也可用按钮临时连接或断开，不改变启动偏好。远端任务继续运行。")
        }
    }

    private var permissionsPane: some View {
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
        } footer: {
            Text("只影响新建会话。Kimi、Qoder 与 Claude Code 可在会话输入框旁调整；OMP 与 Codex 的权限在创建时固定。")
        }
    }

    private var notificationsPane: some View {
        Section {
            Toggle("关闭主窗口后继续在菜单栏运行", isOn: $background)
            if let error = model.companionShortcutError { Text(error).font(.subheadline).foregroundStyle(.orange) }
            Toggle("Notify when Perch is in the background", isOn: $model.notificationsEnabled)
            Toggle("仅通知需要我处理的任务", isOn: $model.notifyAttentionOnly)
                .disabled(!model.notificationsEnabled)
            if let error = model.notificationError { Text(error).font(.subheadline).foregroundStyle(.orange) }
        } footer: {
            Text("完成通知会合并；确认、提问与失败立即通知。可在会话右键菜单中单独静音。")
        }
    }

    private var appearancePane: some View {
        Section {
            Picker("外观", selection: $appAppearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            Picker("正文字号", selection: Binding(get: { readingSize.value }, set: { readingSize.set($0) })) {
                ForEach(ReadingBodySize.sizes, id: \.self) { size in
                    Text(verbatim: size == ReadingBodySize.standard ? L("\(Int(size)) pt（默认）") : "\(Int(size)) pt")
                        .tag(size)
                }
            }
            SettingsRow(action: { showSummary = true }) {
                Image(systemName: "sparkles").frame(width: 20).foregroundStyle(.secondary)
                Text("活动叙事与 Recap").foregroundStyle(.primary)
            } trailing: {
                (summarySettings.configuration.enabled ? Text("已开启") : Text("默认关闭"))
                    .font(.subheadline)
                    .foregroundStyle(summarySettings.configuration.enabled ? Color.green : Color.secondary)
            }
            if summarySettings.configuration.enabled {
                Button("关闭活动叙事") { summarySettings.disable() }
            }
        } footer: {
            Text("正文字号影响对话、思考与工具记录和输入框，也可用 ⌘= 放大、⌘− 缩小、⌘0 恢复默认。侧边栏可拖动调整宽度，系统会记住位置。透明度与动态效果遵循 macOS 辅助功能设置。")
        }
    }

    private var diagnosticsPane: some View {
        Section {
            Toggle("性能诊断", isOn: $diagnosticsOn)
                .onChange(of: diagnosticsOn) { _, on in PerfDiagnostics.shared.setEnabled(on) }
            Button("导出诊断报告…") { PerfDiagnostics.shared.exportReport() }
                .disabled(!diagnosticsOn)
            if diagnosticsOn {
                Button("注入一次 120ms 卡顿（校验）") { PerfDiagnostics.injectCalibrationStall() }
            }
        } footer: {
            Text("开启后记录正文渲染各阶段耗时与掉帧，以及掉帧期间主线程上的工作，并发送 Instruments 的 Points of Interest signpost。复现卡顿：开启后在一段真实的长对话里滚动，直到出现卡顿，再导出诊断报告。校验按钮让主线程停顿 120ms，报告中应出现一次 calibration_stall。报告不含消息内容；关闭即清空并停止记录。")
        }
    }

    private var aboutPane: some View {
        Section {
            LabeledContent("版本", value: versionLabel)
            LabeledContent("更新") { updateCheck }
        } footer: {
            Text("有新版本时可在发布页下载安装包，或拉取最新代码重新构建。")
        }
    }

    private enum SettingsPane: String, CaseIterable, Identifiable {
        case language, agents, permissions, notifications, appearance, diagnostics, about
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .language: "语言 / Language"
            case .agents: "Agent 与执行环境"
            case .permissions: "新会话默认权限"
            case .notifications: "Task notifications"
            case .appearance: "界面"
            case .diagnostics: "诊断"
            case .about: "关于"
            }
        }
        var systemImage: String {
            switch self {
            case .language: "globe"
            case .agents: "server.rack"
            case .permissions: "lock.shield"
            case .notifications: "bell.badge"
            case .appearance: "paintbrush"
            case .diagnostics: "stethoscope"
            case .about: "info.circle"
            }
        }
        var tint: Color {
            switch self {
            case .language: .blue
            case .agents: .teal
            case .permissions: .orange
            case .notifications: .red
            case .appearance: .purple
            case .diagnostics: .indigo
            case .about: .gray
            }
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let revision = info?["PerchSourceRevision"] as? String ?? ""
        return revision.isEmpty ? "Perch \(version)" : "Perch \(version) (\(revision))"
    }

    /// Version check against the public repository's tags. Never auto-installs:
    /// Perch ships source, so the update path is pull + rebuild.
    @ViewBuilder private var updateCheck: some View {
        let checker = AppUpdateChecker.shared
        HStack(spacing: 8) {
            switch checker.state {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.mini)
            case .upToDate:
                Label("已是最新版本", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .available(let latest):
                Label("有新版本 \(latest)", systemImage: "arrow.down.circle").foregroundStyle(.orange)
                Link("查看发布", destination: URL(string: "https://github.com/chenweigao/perch/releases")!)
            case .failed(let reason):
                Text(reason).foregroundStyle(.secondary)
            }
            Button("检查更新") { Task { await checker.checkNow() } }
                .disabled(checker.state == .checking)
        }.font(.subheadline)
        .task { await checker.checkThrottled() }
    }

    @ViewBuilder private var localAgentStatus: some View {
        let count = model.localAgents.values.filter { $0.executablePath != nil }.count
        if count > 0 {
            Text("已发现 \(count) 个本机 Agent").font(.subheadline).foregroundStyle(.secondary)
        } else {
            Text("检测 Kimi、Codex 等本机 Agent").font(.subheadline).foregroundStyle(.secondary)
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
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip, style: .continuous))
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
                Text(connection.host.destination).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HostConnectionControls: View {
    @Bindable var model: WorkbenchModel
    @ObservedObject var connection: HostConnection
    let kimi: KimiConnection
    let native: NativeAgentConnection

    private var sshRequested: Bool { kimi.connecting || native.wantsConnection }
    private var sshOnline: Bool {
        (!connection.host.enabledAgents.contains(.kimi) || kimi.online) &&
        (!connection.host.hasNativeAgents || native.online)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if connection.host.enabledAgents.contains(.kimi) || connection.host.hasNativeAgents {
                connectionRow(connection.host.isLocal ? L("本机 Agent") : "SSH Agent", online: sshOnline, requested: sshRequested,
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
            // Flipping it connects or disconnects now, and sets the launch preference.
            Toggle("自动连接", isOn: autoConnect)
                .toggleStyle(.switch).controlSize(.mini)
                .accessibilityLabel(Text("\(title) 自动连接"))
        }.font(.subheadline)
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
        .background(hovered ? WorkbenchTheme.Fill.hover : .clear,
                    in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row, style: .continuous))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

private extension SettingsRow where Trailing == EmptyView {
    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(action: action, content: content) { EmptyView() }
    }
}
