import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

/// Codex-style new-task draft: an inline page covering the detail area instead of
/// a sheet. The underlying selection stays intact; sending or picking another
/// session clears `draftingNewTask`.
struct NewTaskView: View {
    @Bindable var model: WorkbenchModel
    let native: NativeAgentConnection
    let kimi: KimiConnection
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
    @State private var showCustomModel = false
    @State private var showDirectory = false
    @State private var showConnectionDetails = false
    @State private var showReference = false
    @State private var permissionMode = PermissionDefaults.mode(for: .kimi) ?? "manual"
    private var availableProviders: [SessionKind] { kimi.host.enabledAgents.filter { $0 != .terminal } }
    private var permissionCapability: PermissionCapability {
        PermissionCatalog.capability(for: provider, selected: permissionMode)
    }
    private var connectionError: String? { provider == .kimi ? kimi.error : native.error }
    private var defaultsKey: String { "new.task.defaults." + (model.selectedGroupID?.uuidString ?? "global") }
    private var recent: [String] { recentDirectories(for: kimi.host.id) }
    private var isConnected: Bool { provider == .kimi ? kimi.online : native.online }
    private var isConnecting: Bool { provider == .kimi ? kimi.connecting : native.wantsConnection }
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
    private var creationBlocker: String? {
        if creating { return L("正在启动…") }
        if !availableProviders.contains(provider) { return L("此机器尚未配置原生 Agent。") }
        if !isConnected { return L(isConnecting ? "正在连接所选 Agent…" : "尚未连接所选 Agent。") }
        if !cwd.hasPrefix("/") { return L("请选择项目目录后再开始。") }
        if provider == .codex && selectedAgentModel == nil { return L("请选择可用的 Codex 模型后再开始。") }
        if provider != .kimi && !attachments.isEmpty { return L("请切换到 Kimi 或移除附件后再开始。") }
        return nil
    }
    private var sendHint: String? {
        creationBlocker ?? (hasInitialContent ? nil : L("输入任务内容后发送，也可仅创建空会话。"))
    }
    private var canCreate: Bool { creationBlocker == nil }
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
        var seen = Set<String>()
        return model.allSessions.filter { $0.reference.hostID == hostID }
            .sorted { $0.updatedAt > $1.updatedAt }.map(\.directory)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
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
        if supportsModelCatalog && !(availableModels.isEmpty && (provider == .omp || provider == .dsh)) {
            ComposerModelPicker(models: availableModels, modelID: agentModel, thinking: thinking,
                disabledReason: creating ? L("正在启动…") : nil,
                catalogError: provider == .kimi ? nil : native.modelsError,
                onRefreshCatalog: {
                    if provider == .kimi { await kimi.refreshModels() }
                    else { await native.loadModels() }
                }, layout: .split, usesDefaultModel: agentModel.isEmpty,
                onUseDefaultModel: provider == .codex ? nil : { agentModel = ""; thinking = nil },
                scope: L("首条消息生效"), onSelectModel: { option in
                    agentModel = option.id; thinking = option.resolve(thinking)
                }, onSelectThinking: { thinking = $0 })
        } else {
            Button { showCustomModel.toggle() } label: {
                DraftMenuLabel { Text(agentModel.isEmpty ? L("默认模型") : agentModel).lineLimit(1).truncationMode(.middle) }
            }.buttonStyle(.plain).accessibilityLabel("选择模型")
                .popover(isPresented: $showCustomModel) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("模型与思考").font(.headline)
                        TextField(provider == .dsh ? L("模型（默认使用 dsh 目录的当前路由）") : L("模型（留空使用远端默认值）"), text: $agentModel)
                            .textFieldStyle(.roundedBorder)
                        Text("思考不可调").font(.caption).foregroundStyle(.secondary)
                        Button("完成") { showCustomModel = false }.frame(maxWidth: .infinity, alignment: .trailing)
                    }.padding(18).frame(width: 340).disabled(creating)
                }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 10) {
                    Text("想做点什么？").font(.system(size: 28, weight: .medium))
                    if let group = model.selectedGroup {
                        Text(group.name).font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity).padding(.bottom, 18)
                VStack(alignment: .leading, spacing: 8) {
                    ProjectMessageComposer(text: $prompt, host: kimi.host, cwd: cwd, placeholder: L("描述你的任务，输入 @ 引用项目文件"),
                                    accessibilityLabel: L("任务描述"),
                                    canSend: canStart, onSend: start,
                                    onFiles: provider == .kimi ? addAttachments : nil,
                                    onError: { error = $0 }, onOpenReference: { path in
                                        referenceBrowser.configure(host: kimi.host, cwd: cwd)
                                        referenceBrowser.open(path)
                                        showReference = true
                                    }, minimumEditorHeight: 96, referencesBelowEditor: true, files: projectFiles)
                    if !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(attachments, id: \.self) { file in
                                    ComposerAttachment(file: file) { attachments.removeAll { $0 == file } }
                                }
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        ComposerAddButton(supportsFiles: provider == .kimi, disabled: creating) { chooseFiles = true }
                        agentMenu
                        modelControl
                        Spacer(minLength: 0)
                        Button { showConfiguration.toggle() } label: {
                            Image(systemName: "slider.horizontal.3").frame(width: 24, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("权限").accessibilityLabel("权限")
                            .popover(isPresented: $showConfiguration) { configuration }
                        ComposerActionButton(isRunning: false, isStopping: creating, canSend: canStart, canStop: false,
                                             onSend: start, onStop: {})
                            .help(sendHint ?? L("Return 发送，Shift Return 换行"))
                    }
                }.padding(18)
                    .background {
                        Color.clear.contentShape(Rectangle()).onTapGesture {
                            NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil)
                        }
                    }
                    .workbenchControlSurface().disabled(creating)
                contextBar
                if let directoryWarning {
                    Label(directoryWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if provider != .kimi {
                    Text("附件当前仅支持 Kimi；可在消息中提供运行环境中的文件路径。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if (provider == .omp || provider == .dsh || provider == .codex), let modelsError = native.modelsError {
                    Text(modelsError).font(.caption).foregroundStyle(.orange)
                }
                connectionStatus
                if availableProviders.contains(provider) && isConnected, let sendHint {
                    Text(sendHint).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(.horizontal, 32).frame(maxWidth: 784)
                .frame(maxWidth: .infinity)
                .padding(.top, max(48, geometry.size.height * 0.25))
                .padding(.bottom, 32)
            }
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
                showDirectory = false; showConnectionDetails = false
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
    private var contextBar: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(model.connections) { connection in
                    Button {
                        agentModel = ""; thinking = nil
                        model.activateAgentEnvironment(connection.id)
                        cwd = defaultDirectory(for: connection.id)
                    } label: {
                        Label { Text(connection.host.name) } icon: { HostIdentityIcon.menuImage(for: connection.id) }
                    }
                }
                Divider()
                Button("配置其他 Agent…") { showSetup = true }
            } label: {
                DraftMenuLabel {
                    Label { Text(kimi.host.name).lineLimit(1).truncationMode(.middle) }
                        icon: { HostIdentityIcon.menuImage(for: kimi.host.id) }
                }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true).accessibilityLabel("运行环境")
            Rectangle().fill(.quaternary).frame(width: 1, height: 14)
            Button { showDirectory.toggle() } label: {
                DraftMenuLabel {
                    Label(cwd.isEmpty ? L("选择项目目录") : (cwd == "/" ? "/" : (cwd as NSString).lastPathComponent),
                          systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
            }.buttonStyle(.plain).help(cwd).accessibilityLabel("项目目录")
                .popover(isPresented: $showDirectory) {
                    NewTaskDirectoryPicker(host: kimi.host, cwd: $cwd, recent: recent) { showDirectory = false }
                }
            Spacer(minLength: 0)
            if !hasInitialContent && attachments.isEmpty {
                Button(creating ? L("正在创建…") : L("仅创建空会话")) { create(sendInitialPrompt: false) }
                    .buttonStyle(.plain).font(.system(size: 12)).disabled(!canCreateEmpty)
            }
        }.foregroundStyle(.secondary).padding(.horizontal, 6).disabled(creating)
    }

    @ViewBuilder private var connectionStatus: some View {
        if !availableProviders.contains(provider) || !isConnected {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if connectionError != nil {
                        Button { showConnectionDetails.toggle() } label: {
                            Label("连接失败", systemImage: showConnectionDetails ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain).foregroundStyle(.orange)
                        Spacer(minLength: 0)
                        Button("检查与修复连接") { showSetup = true }
                    } else if !availableProviders.contains(provider) {
                        Label("此机器尚未配置原生 Agent。", systemImage: "exclamationmark.circle")
                        Spacer(minLength: 0)
                        Button("配置其他 Agent…") { showSetup = true }
                    } else if isConnecting {
                        ProgressView().controlSize(.mini)
                        Text("正在连接所选 Agent…")
                    } else {
                        Label("尚未连接所选 Agent。", systemImage: "network")
                        Spacer(minLength: 0)
                        Button("连接") { if provider == .kimi { kimi.connect() } else { native.connect() } }
                    }
                }.font(.system(size: 12)).foregroundStyle(.secondary).buttonStyle(.plain)
                if showConnectionDetails, let connectionError {
                    Text(connectionError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.horizontal, 6).disabled(creating)
        }
    }

    private func selectProvider(_ value: SessionKind) {
        showConnectionDetails = false
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
            Text("权限").font(.headline)
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
