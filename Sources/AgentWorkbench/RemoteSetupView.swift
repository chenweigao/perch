import SwiftUI
import WorkbenchCore

struct AddHostSheet: View {
    @Bindable var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var setup: RemoteSetupController
    @State private var saveError: String?
    @State private var showFolders = false
    private var onReady: ((TaskLaunchDefaults) -> Void)?
    private var providers: [SessionKind] { RemoteSetup.agents.filter { onReady == nil || $0 != .terminal } }

    init(model: WorkbenchModel, host: SSHHost? = nil, onReady: ((TaskLaunchDefaults) -> Void)? = nil) {
        self.model = model; self.onReady = onReady
        let controller = RemoteSetupController(host: host)
        if onReady != nil && controller.provider == .terminal {
            controller.provider = host?.enabledAgents.first(where: { $0 != .terminal }) ?? .kimi
        }
        _setup = StateObject(wrappedValue: controller)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedStringKey(setup.original == nil ? "连接远程 Agent" : "配置远程 Agent")).font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    stepLabel("连接机器", step: .machine)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    stepLabel("准备 Agent", step: .agent)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    stepLabel("开始会话", step: .project)
                }
            }.padding(WorkbenchTheme.Dialog.padding)
            Divider()
            Form {
                switch setup.step {
                case .machine: machine
                case .agent: agent
                case .project: project
                }
                feedback
            }
            .formStyle(.grouped)
            .frame(minHeight: 340, maxHeight: 450)
            Divider()
            footer.padding(WorkbenchTheme.Dialog.padding)
        }.frame(width: 620)
            .onDisappear { setup.cancel() }
            .onChange(of: setup.provider) { _, _ in setup.invalidateAgent() }
            .onChange(of: setup.port) { _, _ in setup.invalidateAgent() }
            .onChange(of: setup.tokenPath) { _, _ in setup.invalidateAgent() }
            .onChange(of: setup.kimiEnvironment) { _, _ in setup.invalidateAgent() }
            .onChange(of: setup.directory) { _, _ in setup.invalidateProject() }
    }
    private func stepLabel(_ title: LocalizedStringKey, step: RemoteSetupController.Step) -> some View {
        HStack(spacing: 6) {
            Image(systemName: setup.step.rawValue > step.rawValue ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle")
            Text(title)
        }.font(.callout).foregroundStyle(setup.step == step ? .primary : .secondary)
            .accessibilityElement(children: .combine)
    }
    private var machine: some View {
        Section {
            if !setup.aliases.isEmpty && setup.original == nil {
                Menu("从 SSH 配置选择") {
                    ForEach(setup.aliases, id: \.self) { alias in Button(alias) { setup.destination = alias } }
                }.fixedSize()
            }
            TextField("SSH 地址", text: $setup.destination, prompt: Text("SSH 别名或 user@host"))
                .disabled(setup.original != nil)
            TextField("显示名称", text: $setup.name, prompt: Text("可选"))
            DisclosureGroup("首次使用 SSH？") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("端口、密钥与跳板机配置在 ~/.ssh/config。首次连接需在终端确认主机指纹；需要口令的密钥请先加入 SSH agent。")
                    Text("Host my-server\n    HostName server.example.com\n    User developer") // l10n-ignore
                        .font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                    Button("在终端连接") { setup.openTerminal() }.disabled(setup.destination.isEmpty)
                }.font(.callout).padding(.top, 8)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("连接代码所在的机器。Perch 使用你的 SSH 配置与密钥。")
                if setup.original != nil { Text("要连接另一台机器，请添加新机器。") }
            }
        }
        .disabled(setup.busy)
    }
    @ViewBuilder private var agent: some View {
        Section {
            Label(setup.destination, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            Picker("Agent", selection: $setup.provider) {
                ForEach(providers, id: \.self) { kind in
                    Label { Text(kind.label) } icon: { AgentMarkMenuImage.image(for: kind) }.tag(kind)
                }
            }.disabled(setup.busy)
        } footer: {
            Text("选择要使用的 Agent。只检查所选 Agent 所需的环境。")
        }
        if setup.provider == .kimi {
            Section {
                LabeledContent("远端端口") { TextField("58627", text: $setup.port).frame(width: 110) }
                LabeledContent("远端令牌文件") {
                    TextField("~/.kimi-code/server.token", text: $setup.tokenPath) // l10n-ignore
                }
                Toggle("由 Perch 托管 Kimi Web", isOn: Binding(get: { setup.kimiManaged },
                                                            set: { setup.kimiManaged = $0; setup.invalidateAgent() }))
                if setup.kimiManaged {
                    LabeledContent("启动环境变量") {
                        TextField("NAME=value", text: $setup.kimiEnvironment) // l10n-ignore
                    }
                }
            } header: {
                Text("高级设置")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("服务只通过 SSH 访问远端 127.0.0.1。填写文件路径即可，令牌不保存在 Mac 配置中。")
                    Text("托管时，服务未运行则由 Perch 启动；Kimi 升级或启动配置修改后，等所有会话空闲再自动重启。Perch 只重启自己启动的 Kimi Web。")
                }
            }
            .disabled(setup.busy)
        }
        if let original = setup.original, original.enabledAgents.contains(where: { $0 != setup.provider }) {
            Section {
                ForEach(original.enabledAgents.filter { $0 != setup.provider }, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { setup.enabledAgents.contains(kind) }, set: { enabled in
                        if enabled { setup.enabledAgents.insert(kind) } else { setup.enabledAgents.remove(kind) }
                    })) {
                        HStack(spacing: 6) {
                            AgentMark(kind: kind, size: 14)
                            Text(kind.label)
                        }
                    }
                }
            } header: {
                Text("其他自动连接的 Agent")
            }
            .disabled(setup.busy)
        }
        Section {
            if setup.checks.isEmpty {
                Text("检查会读取版本、连接服务并读取模型配置，不发送任务。").foregroundStyle(.secondary)
            } else {
                ForEach(setup.checks) { checkRow($0) }
            }
            HStack {
                if setup.checks.contains(where: \.needsManualRestart) {
                    Button("打开远端终端") { setup.openTerminal() }.disabled(setup.busy)
                }
                Button(setup.checkAgentTitle) { setup.checkAgent() }.disabled(setup.busy)
                Spacer()
                if !setup.checks.contains(where: \.needsManualRestart) {
                    Link("安装说明", destination: setup.installURL)
                }
            }
            if !setup.ready && !setup.busy && setup.failedCheck != nil { repairs }
        }
    }
    private func checkRow(_ check: RemoteSetupController.Check) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch check.status {
                case .checking: ProgressView().controlSize(.small)
                case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .needsAction: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .information: Image(systemName: "info.circle").foregroundStyle(.secondary)
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title).font(.callout.weight(.medium))
                if !check.detail.isEmpty { Text(check.detail).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                if check.needsManualRestart {
                    DisclosureGroup("重启步骤") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. 等待这台机器上该 Kimi Web 服务中的会话和后台任务结束。")
                            Text("2. 在远端按原来的启动方式停止并重新启动 Kimi Web。前台运行时，在原终端按 Control-C 后重新运行原命令；后台或托管服务请通过原来的服务管理方式重启。")
                            Text("沿用原来的端口（\(String(setup.host.kimiPort))）、令牌路径（\(setup.tokenPath)）与环境配置。")
                            Text("3. 返回 Perch 点击“重新检查”。运行版本与安装版本一致后，此提示会消失。")
                            Text("“重新检查”只核对状态；重开 Perch 不会重启远端 Kimi Web。")
                                .foregroundStyle(.secondary)
                        }.textSelection(.enabled).padding(.top, 6)
                    }.font(.subheadline).padding(.top, 4)
                }
            }
        }.accessibilityElement(children: check.needsManualRestart ? .contain : .combine)
    }
    private var repairs: some View {
        VStack(alignment: .leading, spacing: 10) {
            if setup.failedCheck == "runtime", let command = setup.installCommand {
                DisclosureGroup("安装 Agent") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("使用已核对的版本。Kimi 需要 Node.js 22.19+，Qoder 与 Codex 需要 Node.js，OMP 需要 Bun。安装完成后重新检查。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(command).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                        Button("在终端安装") { setup.openInstallTerminal() }
                    }.padding(.top, 8)
                }
            }
            if setup.needsBridge && ["runtime", "service"].contains(setup.failedCheck ?? "") {
                Text("Perch 安装所选 Agent 的桥接组件：Qoder 下载 SDK，DeepSeek 安装运行时；Codex 使用远端现有 CLI。已有任务不会被终止。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("安装 / 更新桥接组件") { setup.installBridge() }
            }
            HStack {
                if setup.provider == .kimi && setup.failedCheck == "service" {
                    Button("启动并检查 Kimi Web") { setup.startKimi() }
                }
                Button("打开远端终端") { setup.openTerminal() }
                if !setup.loginCommand.isEmpty && setup.failedCheck == "models" {
                    Button("登录 / 配置模型…") { setup.openTerminal(command: setup.loginCommand) }
                }
            }
            if setup.provider == .kimi && setup.failedCheck == "service" && !setup.kimiManaged {
                Text("由 Perch 启动的 Kimi Web 由 Perch 托管：Kimi 升级后，Perch 会在所有会话空闲时自动重启它。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if setup.provider == .dsh {
                Text("在远端 shell 或服务环境中设置 DEEPSEEK_API_KEY；Perch 不读取或保存它的值。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var project: some View {
        Section {
            Label("Agent 已连接", systemImage: "checkmark.circle.fill").font(.headline)
            HStack(spacing: 6) {
                AgentMark(kind: setup.provider, size: 14)
                Text(setup.host.name + " · " + setup.provider.label)
            }.foregroundStyle(.secondary)
        }
        Section {
            TextField("远端项目目录", text: $setup.directory, prompt: Text("绝对路径"))
            HStack {
                Button("浏览…") {
                    showFolders = true
                    setup.browse(setup.directory.hasPrefix("/") ? setup.directory : setup.remoteHome)
                }.popover(isPresented: $showFolders) { folderBrowser }
                Button("使用主目录") { setup.directory = setup.remoteHome }
                Button("检查目录") { setup.verifyProject() }.disabled(setup.busy || setup.directory.isEmpty)
                if setup.projectVerified { Label("目录可访问", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
        }
        .disabled(setup.busy)
        Section {
            if !setup.models.isEmpty {
                LabeledContent("模型") { ModelPicker(models: setup.models, selection: $setup.modelID) }
            } else if setup.provider != .terminal {
                TextField("模型", text: $setup.modelID, prompt: Text("留空使用远端默认值"))
            }
        } footer: {
            Text("继续后即可填写首个任务；机器、Agent、目录与模型会自动带入。")
        }
    }
    private var folderBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择远端目录").font(.headline)
            Text(setup.browsingDirectory).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Button("主目录") { setup.browse(setup.remoteHome) }
                Button("上级目录") { setup.browse((setup.browsingDirectory as NSString).deletingLastPathComponent) }
                    .disabled(setup.browsingDirectory.isEmpty || setup.browsingDirectory == "/")
                Spacer()
                if setup.busy { ProgressView().controlSize(.small) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(setup.folders, id: \.self) { path in
                        Button { setup.browse(path) } label: {
                            Label((path as NSString).lastPathComponent, systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 220)
            if let error = setup.error { Text(error).font(.subheadline).foregroundStyle(.orange).textSelection(.enabled) }
            Button("使用此目录") {
                setup.directory = setup.browsingDirectory
                showFolders = false
                setup.verifyProject()
            }.buttonStyle(.borderedProminent).disabled(setup.busy || setup.browsingDirectory.isEmpty)
        }.padding(18).frame(width: 400)
    }
    @ViewBuilder private var feedback: some View {
        if let error = setup.error ?? saveError {
            Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        }
        if !setup.hint.isEmpty { Text(setup.hint).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        if setup.step == .machine && setup.error != nil {
            Button("在终端处理 SSH 登录") { setup.openTerminal() }.disabled(setup.busy)
        }
    }
    /// 上一步 stays leading; the alternative finish sits before 取消, which sits
    /// before the step's primary action.
    private var footer: some View {
        HStack {
            if setup.step != .machine { Button("上一步") { setup.back() }.disabled(setup.busy) }
            Spacer()
            if setup.busy { ProgressView().controlSize(.small) }
            if setup.step == .project && onReady == nil {
                Button("保存，稍后开始") { finish(start: false) }.disabled(!setup.canFinish)
            }
            Button("取消") { setup.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            switch setup.step {
            case .machine:
                Button("验证 SSH 并继续") { setup.verifySSH() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(setup.busy || setup.destination.isEmpty)
            case .agent:
                Button("继续") { setup.step = .project; setup.verifyProject() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!setup.canContinue)
            case .project:
                if onReady != nil {
                    Button("使用此环境") { finish(start: false) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!setup.canFinish)
                } else {
                    Button("开始首个会话") { finish(start: true) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!setup.canFinish)
                }
            }
        }
    }
    private func finish(start: Bool) {
        do {
            try model.finishSetup(setup.host, launch: setup.launch, startTask: start)
            onReady?(setup.launch)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
}
