import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

/// Codex-style new-task draft: an inline page covering the detail area instead of
/// a sheet. The underlying selection stays intact; sending or picking another
/// session clears `draftingNewTask`.
struct NewTaskView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var native: NativeAgentConnection
    @ObservedObject var kimi: KimiConnection
    @StateObject var projectFiles = ProjectFileSuggestions()
    @StateObject var referenceBrowser = RemoteFileBrowser()
    @AppStorage("new.task.prompt") private var prompt = ""
    @State private var provider: SessionKind = .kimi
    @State private var cwd = ""
    @State private var agentModel = ""
    @State private var thinking: ThinkingLevel?
    @State private var creating = false
    @State private var error: String?
    @State private var attachments: [URL] = []
    @State private var chooseFiles = false
    @State private var showSetup = false
    @State private var showConfiguration = false
    @State private var showReference = false
    @State private var permissionMode = PermissionDefaults.mode(for: .kimi) ?? "manual"
    @FocusState private var cwdFocused: Bool
    private var availableProviders: [SessionKind] { kimi.host.enabledAgents.filter { $0 != .terminal } }
    private var permissionCapability: PermissionCapability {
        PermissionCatalog.capability(for: provider, selected: permissionMode)
    }
    private var connectionError: String? { provider == .kimi ? kimi.error : native.error }
    private var defaultsKey: String { "new.task.defaults." + (model.selectedGroupID?.uuidString ?? "global") }
    private var recent: [String] { recentDirectories(for: kimi.host.id) }
    private var availableModels: [AgentModel] {
        provider == .kimi ? kimi.catalog : native.models(for: provider)
    }
    private var selectedAgentModel: AgentModel? {
        availableModels.first { $0.id == agentModel }
    }
    private var supportsModelCatalog: Bool {
        [.kimi, .omp, .dsh, .codex].contains(provider)
    }
    private var catalogID: String { provider.rawValue + "@" + native.host.id.uuidString + "@" + String(native.online) }
    private var modelCatalogID: String {
        availableModels.map { "\($0.provider):\($0.id):\($0.thinking.map(\.rawValue).joined(separator: ","))" }.joined(separator: "|")
    }
    private var hasInitialContent: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (provider == .kimi && !attachments.isEmpty)
    }
    private var canCreate: Bool {
        let modelIsValid = provider != .codex || selectedAgentModel != nil
        return !creating && modelIsValid && (provider == .kimi || attachments.isEmpty) && cwd.hasPrefix("/")
            && availableProviders.contains(provider) && (provider == .kimi ? kimi.online : native.online)
    }
    private var canStart: Bool { canCreate && hasInitialContent }
    private var canCreateEmpty: Bool { canCreate && !hasInitialContent && attachments.isEmpty }
    private var directoryWarning: String? {
        let path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = path.split(separator: "/")
        if path == "/" || (components.count == 2 && (components[0] == "Users" || components[0] == "home")) {
            return L("工作目录范围较大，Agent 可能访问多个项目。")
        }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let descendants = Set(recent.filter { $0 != path && $0.hasPrefix(prefix) })
        return descendants.count > 1 ? L("工作目录范围较大，Agent 可能访问多个项目。") : nil
    }
    /// Directory defaults stay scoped to their host: a path valid on one machine
    /// does not exist on another, so the selected session and the last-used
    /// directory must not leak across environments.
    private func recentDirectories(for hostID: UUID) -> [String] {
        Array(Set(model.allSessions.filter { $0.reference.hostID == hostID }.map(\.directory).filter { $0.hasPrefix("/") })).sorted()
    }
    private func savedDirectoryKey(for hostID: UUID) -> String { "new.cwd.\(hostID.uuidString)" }
    private func defaultDirectory(for hostID: UUID) -> String {
        if let selected = model.selectedItem, selected.reference.hostID == hostID { return selected.directory }
        if let saved = UserDefaults.standard.string(forKey: savedDirectoryKey(for: hostID)) { return saved }
        return recentDirectories(for: hostID).first ?? ""
    }
    /// Menu triggers on this page match the composer row: a 12pt value with a quiet chevron.
    private struct DraftMenuLabel<Content: View>: View {
        let content: Content
        init(@ViewBuilder content: () -> Content) { self.content = content() }
        var body: some View {
            HStack(spacing: 5) {
                content
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.vertical, 6).contentShape(Rectangle())
        }
    }

    private var agentMenu: some View {
        Menu {
            ForEach(availableProviders, id: \.self) { kind in
                Button { selectProvider(kind) } label: {
                    if kind == provider { Label(kind.label, systemImage: "checkmark") } else { Text(kind.label) }
                }
            }
        } label: {
            DraftMenuLabel { Text(provider.label) }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("选择 Agent")
    }

    @ViewBuilder private var modelControl: some View {
        if supportsModelCatalog {
            VStack(alignment: .leading, spacing: 6) {
                ComposerModelPicker(models: availableModels, modelID: agentModel, thinking: thinking,
                                    disabledReason: creating ? L("正在启动…") : nil,
                                    catalogError: provider == .kimi ? nil : native.modelsError,
                                    onRefreshCatalog: {
                                        if provider == .kimi { await kimi.refreshModels() }
                                        else { await native.loadModels() }
                                    }, layout: .combined, usesDefaultModel: agentModel.isEmpty,
                                    onUseDefaultModel: provider == .codex ? nil : {
                                        agentModel = ""; thinking = nil
                                    }, scope: L("首条消息生效"), onSelectModel: { option in
                                        agentModel = option.id
                                        thinking = option.resolve(thinking)
                                    }, onSelectThinking: { thinking = $0 })
                if availableModels.isEmpty && (provider == .omp || provider == .dsh) {
                    TextField(provider == .dsh ? L("模型（默认使用 dsh 目录的当前路由）") : L("模型（留空使用远端默认值）"),
                              text: $agentModel)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                }
            }
        } else {
            HStack(spacing: 8) {
                ModelControlWidth(maximum: 260) {
                    TextField(L("模型（留空使用远端默认值）"), text: $agentModel)
                        .textFieldStyle(.roundedBorder)
                }
                Text("思考不可调").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 6) {
                    Text("新建任务").font(.title2.weight(.semibold))
                    if let group = model.selectedGroup { Text(group.name).font(.callout).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Menu {
                            ForEach(model.connections) { connection in
                                Button {
                                    agentModel = ""; thinking = nil
                                    model.activateAgentEnvironment(connection.id)
                                    cwd = defaultDirectory(for: connection.id)
                                } label: {
                                    Label { Text(connection.host.name) } icon: { HostIdentityIcon.menuImage(for: connection.id) }
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                            Divider()
                            Button("配置其他 Agent…") { showSetup = true }
                        } label: {
                            DraftMenuLabel { Label { Text(kimi.host.name) } icon: { HostIdentityIcon.menuImage(for: kimi.host.id) } }
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel("运行环境")

                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            TextField("项目目录（绝对路径）", text: $cwd).textFieldStyle(.plain).focused($cwdFocused)
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(cwdFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
                                                  lineWidth: cwdFocused ? 2 : 1)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { cwdFocused = true }
                        Menu {
                            ForEach(recent, id: \.self) { path in Button(path) { cwd = path } }
                        } label: {
                            DraftMenuLabel { Text("最近使用") }
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    if let directoryWarning {
                        Label(directoryWarning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.disabled(creating)
                VStack(alignment: .leading, spacing: 8) {
                    if !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(attachments, id: \.self) { file in
                                    ComposerAttachment(file: file) { attachments.removeAll { $0 == file } }
                                }
                            }
                        }
                    }
                    ProjectMessageComposer(text: $prompt, host: kimi.host, cwd: cwd, placeholder: L("想做点什么？输入 @ 引用项目文件"),
                                    accessibilityLabel: L("任务描述"),
                                    canSend: canStart, onSend: start,
                                    onFiles: provider == .kimi ? addAttachments : nil,
                                    onError: { error = $0 }, onOpenReference: { path in
                                        referenceBrowser.configure(host: kimi.host, cwd: cwd)
                                        referenceBrowser.open(path)
                                        showReference = true
                                    }, files: projectFiles)
                    HStack(spacing: 12) {
                        ComposerAddButton(supportsFiles: provider == .kimi, disabled: creating) { chooseFiles = true }
                        Button { showConfiguration.toggle() } label: {
                            Label {
                                Text(agentModel.isEmpty ? provider.label : "\(provider.label) · \(agentModel)").lineLimit(1).truncationMode(.middle)
                            } icon: { Image(systemName: "slider.horizontal.3") }
                                .font(.system(size: 12))
                        }.buttonStyle(.plain).help("Agent、模型、思考与权限")
                            .popover(isPresented: $showConfiguration) { configuration }
                        Spacer(minLength: 0)
                        if !hasInitialContent && attachments.isEmpty {
                            Button(creating ? L("正在创建…") : L("仅创建空会话")) { create(sendInitialPrompt: false) }
                                .disabled(!canCreateEmpty).controlSize(.small)
                        }
                        ComposerActionButton(isRunning: false, isStopping: creating, canSend: canStart, canStop: false,
                                             onSend: start, onStop: {})
                    }
                }.padding(12).workbenchControlSurface().disabled(creating)
                if provider != .kimi {
                    Text("附件当前仅支持 Kimi；可在消息中提供运行环境中的文件路径。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if provider != .kimi && !attachments.isEmpty {
                    Text("Choose Kimi or remove the attachments to start this task.").font(.caption).foregroundStyle(.secondary)
                }
                if (provider == .omp || provider == .dsh || provider == .codex), let modelsError = native.modelsError {
                    Text(modelsError).font(.caption).foregroundStyle(.orange)
                }
                if !availableProviders.contains(provider) || !(provider == .kimi ? kimi.online : native.online) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let connectionError {
                            Text(connectionError).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        } else {
                            Text(LocalizedStringKey(!availableProviders.contains(provider) ? "此机器尚未配置原生 Agent。"
                                : (provider == .kimi ? kimi.connecting : native.wantsConnection)
                                    ? "正在连接所选 Agent…" : "尚未连接所选 Agent。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("检查与修复连接") { showSetup = true }
                            if availableProviders.contains(provider) {
                                Button("重新连接") { if provider == .kimi { kimi.connect() } else { native.connect() } }
                            }
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(.horizontal, 24).frame(maxWidth: 728)
            Spacer(minLength: 32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchTheme.contentBackground)
            .overlay(alignment: .topTrailing) {
                Button { model.draftingNewTask = false } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("取消").disabled(creating).padding(14)
            }
            .fileImporter(isPresented: $chooseFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do { addAttachments(try result.get()) } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $showSetup) {
                if kimi.host.isLocal { LocalAgentSetupSheet(model: model) }
                else {
                    AddHostSheet(model: model, host: kimi.host) { launch in
                        selectProvider(launch.provider); cwd = launch.directory; agentModel = launch.model
                        reconcileThinking()
                    }
                }
            }
            .sheet(isPresented: $showReference, onDismiss: {
                referenceBrowser.cancel()
                NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil)
            }) {
                RemoteFilePanel(browser: referenceBrowser, onClose: { showReference = false })
                    .frame(minWidth: 540, idealWidth: 680, minHeight: 400, idealHeight: 560)
            }
            .onChange(of: cwd) { _, _ in showReference = false; referenceBrowser.cancel() }
            .onChange(of: kimi.host.id) { _, _ in
                showReference = false; referenceBrowser.cancel()
                if !availableProviders.contains(provider) {
                    selectProvider(availableProviders.first ?? .kimi)
                }
            }
            .onChange(of: modelCatalogID) { _, _ in
                if provider == .codex { selectCodexModel() }
                reconcileThinking()
            }
            .onChange(of: agentModel) { _, _ in reconcileThinking() }
            .onDisappear {
                referenceBrowser.cancel()
                if let reference = model.selectedReference, reference.kind != .terminal { model.activateAgentEnvironment(reference.hostID) }
            }
            .task(id: catalogID) {
                // A native catalog is now needed before any session exists. Qoder
                // reports none and Kimi reads its own connection.
                guard native.online && (provider == .omp || provider == .dsh || provider == .codex) else { return }
                await native.loadModels()
                guard !Task.isCancelled else { return }
                if provider == .codex { selectCodexModel() }
                reconcileThinking()
            }
            .onAppear {
                if let launch = model.launchAfterSetup {
                    model.launchAfterSetup = nil
                    model.activateAgentEnvironment(launch.hostID)
                    provider = launch.provider; cwd = launch.directory; agentModel = launch.model
                    thinking = savedThinking(for: provider)
                } else if let data = UserDefaults.standard.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(TaskLaunchDefaults.self, from: data),
                          model.connections.contains(where: { $0.id == saved.hostID }) {
                    provider = saved.provider; cwd = saved.directory; agentModel = saved.model; thinking = saved.thinking
                    model.activateAgentEnvironment(saved.hostID)
                } else {
                    let groupItem = model.groupResumeSession ?? model.allSessions.first { model.selectedGroup?.sessions.contains($0.reference) == true }
                    provider = groupItem?.reference.kind ?? model.selectedReference?.kind ?? .kimi
                    if provider == .terminal { provider = .kimi }
                    if let host = groupItem?.reference.hostID { model.activateAgentEnvironment(host) }
                    cwd = groupItem?.directory ?? defaultDirectory(for: model.kimi.host.id)
                    agentModel = UserDefaults.standard.string(forKey: "new.model.\(provider.rawValue)") ?? ""
                    thinking = savedThinking(for: provider)
                }
                if !model.kimi.host.enabledAgents.contains(provider) {
                    selectProvider(model.kimi.host.enabledAgents.first(where: { $0 != .terminal }) ?? .kimi)
                } else {
                    permissionMode = PermissionDefaults.mode(for: provider) ?? PermissionCatalog.runtimeManaged
                    reconcileThinking()
                }
            }
    }
    private func selectProvider(_ value: SessionKind) {
        provider = value
        agentModel = UserDefaults.standard.string(forKey: "new.model.\(value.rawValue)") ?? ""
        thinking = savedThinking(for: value)
        permissionMode = PermissionDefaults.mode(for: value) ?? PermissionCatalog.runtimeManaged
        if value == .codex { selectCodexModel() }
        reconcileThinking()
    }
    private func selectCodexModel() {
        if selectedAgentModel != nil { return }
        let saved = UserDefaults.standard.string(forKey: "new.model.codex") ?? ""
        agentModel = availableModels.first { $0.id == saved }?.id ?? availableModels.first?.id ?? ""
        reconcileThinking()
    }
    private func savedThinking(for provider: SessionKind) -> ThinkingLevel? {
        ThinkingLevel.parse(UserDefaults.standard.string(forKey: "new.thinking.\(provider.rawValue)"))
    }
    private func reconcileThinking() {
        if let selectedAgentModel {
            thinking = selectedAgentModel.resolve(thinking)
        } else if agentModel.isEmpty || !availableModels.isEmpty {
            thinking = nil
        }
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("任务配置").font(.headline)
            Text("Agent").font(.caption).foregroundStyle(.secondary)
            agentMenu
            Divider()
            Text("模型与思考").font(.caption).foregroundStyle(.secondary)
            modelControl
            Divider()
            Text("权限").font(.caption).foregroundStyle(.secondary)
            PermissionPicker(provider: provider, capability: permissionCapability,
                             disabled: creating, allowsSelection: provider != .dsh, showsTitle: true) { mode in
                permissionMode = mode
            }
            Button("完成") { showConfiguration = false }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(18).frame(width: 360).disabled(creating)
    }
    private func addAttachments(_ files: [URL]) {
        for file in files where !attachments.contains(file) { attachments.append(file) }
    }
    private func start() { create(sendInitialPrompt: true) }
    private func create(sendInitialPrompt: Bool) {
        guard sendInitialPrompt ? canStart : canCreateEmpty else { return }
        creating = true
        let text = prompt, selectedModel = agentModel, selectedProvider = provider, directory = cwd, files = attachments
        let selectedPermission = permissionMode
        let selectedThinking = selectedAgentModel?.resolve(thinking)
        let selectedHost = kimi.host.id
        let defaults = TaskLaunchDefaults(hostID: selectedHost, provider: selectedProvider, directory: directory,
                                          model: selectedModel, thinking: selectedThinking)
        Task {
            do {
                if kimi.host.isLocal {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                        throw WorkbenchError(L("本机项目目录不存在"))
                    }
                }
                if selectedProvider == .kimi {
                    let session = try await kimi.createSession(title: "", cwd: directory,
                                                               initialPrompt: sendInitialPrompt ? text : nil,
                                                               model: selectedModel.isEmpty ? nil : selectedModel,
                                                               thinking: selectedThinking, permissionMode: selectedPermission)
                    if sendInitialPrompt {
                        if !files.isEmpty { kimi.attachments[session.id] = files }
                        model.newKimiCreated(session)
                        await kimi.sendPrompt(for: session.id)
                    } else {
                        model.newKimiCreated(session)
                    }
                } else {
                    let session = try await native.create(provider: selectedProvider, cwd: directory, model: selectedModel,
                                                          thinking: selectedThinking, permissionMode: selectedPermission)
                    if sendInitialPrompt { native.drafts[session.id] = text }
                    model.newNativeCreated(session)
                    if sendInitialPrompt { native.send() }
                }
                UserDefaults.standard.set(try JSONEncoder().encode(defaults), forKey: defaultsKey)
                UserDefaults.standard.set(selectedModel, forKey: "new.model.\(selectedProvider.rawValue)")
                let thinkingKey = "new.thinking.\(selectedProvider.rawValue)"
                if let selectedThinking { UserDefaults.standard.set(selectedThinking.rawValue, forKey: thinkingKey) }
                else { UserDefaults.standard.removeObject(forKey: thinkingKey) }
                UserDefaults.standard.set(directory, forKey: savedDirectoryKey(for: selectedHost))
                prompt = ""; attachments = []; model.draftingNewTask = false
            } catch { self.error = error.localizedDescription; creating = false }
        }
    }
}
