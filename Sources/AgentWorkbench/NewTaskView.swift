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
    @AppStorage("new.task.prompt") private var prompt = ""
    @State private var provider: SessionKind = .kimi
    @State private var cwd = ""
    @State private var agentModel = ""
    @State private var creating = false
    @State private var error: String?
    @State private var attachments: [URL] = []
    @State private var chooseFiles = false
    @State private var showSetup = false
    @State private var permissionMode = PermissionDefaults.mode(for: .kimi) ?? "manual"
    @FocusState private var cwdFocused: Bool
    private var availableProviders: [SessionKind] { kimi.host.enabledAgents.filter { $0 != .terminal } }
    private var permissionCapability: PermissionCapability {
        PermissionCatalog.capability(for: provider, selected: permissionMode)
    }
    private var connectionError: String? { provider == .kimi ? kimi.error : native.error }
    private var defaultsKey: String { "new.task.defaults." + (model.selectedGroupID?.uuidString ?? "global") }
    private var recent: [String] { recentDirectories(for: kimi.host.id) }
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
    private var codexModels: [AgentModel] { native.models(for: .codex) }
    private var nativeModelOptions: [ModelOption] { ModelCatalog.options(native.models(for: provider)) }
    private var showsNativePicker: Bool { (provider == .omp || provider == .dsh) && !nativeModelOptions.isEmpty }
    private var catalogID: String { provider.rawValue + "@" + native.host.id.uuidString + "@" + String(native.online) }
    private var selectedCodexModel: AgentModel? { codexModels.first { $0.id == agentModel } }
    /// Attachments ride the Kimi session channel; native adapters have none, so an
    /// attachment-only draft can start a Kimi task but never a native one.
    private var canStart: Bool {
        let hasContent = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (provider == .kimi && !attachments.isEmpty)
        let modelIsValid = provider != .codex || selectedCodexModel != nil
        return !creating && hasContent && modelIsValid && (provider == .kimi || attachments.isEmpty) && cwd.hasPrefix("/")
            && availableProviders.contains(provider) && (provider == .kimi ? kimi.online : native.online)
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
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            VStack(alignment: .leading, spacing: 16) {
                Text("新建任务").font(.title2.weight(.semibold))
                if let group = model.selectedGroup { Text(group.name).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 10) {
                    if !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(attachments, id: \.self) { file in
                                    ComposerAttachment(file: file) { attachments.removeAll { $0 == file } }
                                }
                            }
                        }
                    }
                    MessageComposer(text: $prompt, placeholder: L("想做点什么？"),
                                    accessibilityLabel: L("任务描述"),
                                    canSend: canStart, onSend: start,
                                    onFiles: provider == .kimi ? addAttachments : nil,
                                    onError: { error = $0 })
                }.frame(minHeight: 80, alignment: .top).padding(14).workbenchControlSurface().disabled(creating)
                if provider != .kimi && !attachments.isEmpty {
                    Text("Choose Kimi or remove the attachments to start this task.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    ComposerAddButton(supportsFiles: provider == .kimi, disabled: creating) { chooseFiles = true }
                    Menu {
                        ForEach(model.connections) { connection in
                            Button {
                                agentModel = ""
                                model.activateAgentEnvironment(connection.id)
                                cwd = defaultDirectory(for: connection.id)
                            } label: {
                                Label { Text(connection.host.name) } icon: { HostIdentityIcon.menuImage(for: connection.id) }
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    } label: {
                        DraftMenuLabel { Label { Text(kimi.host.name) } icon: { HostIdentityIcon.menuImage(for: kimi.host.id) } }
                    }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("运行环境")
                    Menu {
                        ForEach(availableProviders, id: \.self) { kind in
                            Button {
                                selectProvider(kind)
                            } label: {
                                if kind == provider { Label(kind.label, systemImage: "checkmark") } else { Text(kind.label) }
                            }
                        }
                    } label: {
                        DraftMenuLabel { Text(provider.label) }
                    }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("选择 Agent")
                    Spacer()
                    if provider == .kimi {
                        ModelPicker(models: ModelCatalog.options(kimi.models), selection: $agentModel, emphasizesSelection: true)
                    } else if showsNativePicker {
                        ModelPicker(models: nativeModelOptions, selection: $agentModel, emphasizesSelection: true)
                    } else if provider == .codex {
                        ModelControlWidth {
                            Menu {
                                ForEach(codexModels) { option in
                                    Button {
                                        agentModel = option.id
                                    } label: {
                                        if option.id == agentModel { Label(option.name, systemImage: "checkmark") }
                                        else { Text(option.name) }
                                    }
                                }
                                if codexModels.isEmpty { Text("正在读取模型…") }
                            } label: {
                                DraftMenuLabel {
                                    Text(selectedCodexModel?.name ?? "选择 Codex 模型")
                                        .foregroundStyle(selectedCodexModel != nil ? .primary : .secondary)
                                }
                            }.menuStyle(.borderlessButton).fixedSize().disabled(codexModels.isEmpty)
                        }
                    }
                }.disabled(creating)
                HStack(spacing: 12) {
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
                    }.menuStyle(.borderlessButton).fixedSize()
                }.disabled(creating)
                if provider != .kimi && provider != .codex {
                    TextField(provider == .dsh ? L("模型（默认使用 dsh 目录的当前路由）") : L("模型（留空使用远端默认值）"), text: $agentModel).textFieldStyle(.roundedBorder).disabled(creating)
                }
                PermissionPicker(provider: provider, capability: permissionCapability, layout: .form,
                                 disabled: creating, allowsSelection: provider != .dsh) { mode in
                    permissionMode = mode
                }
                if (provider == .omp || provider == .dsh || provider == .codex), let modelsError = native.modelsError {
                    Text(modelsError).font(.caption).foregroundStyle(.orange)
                }
                if !availableProviders.contains(provider) || !(provider == .kimi ? kimi.online : native.online) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let connectionError {
                            Text(connectionError).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        } else {
                            Text(LocalizedStringKey(availableProviders.isEmpty ? "此机器尚未配置原生 Agent。" : "正在连接所选 Agent…"))
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
                HStack {
                    Button("配置其他 Agent…") { showSetup = true }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).disabled(creating)
                    Spacer()
                    Button("取消") { model.draftingNewTask = false }.keyboardShortcut(.cancelAction).disabled(creating)
                        .controlSize(.large)
                    Button(creating ? L("正在启动…") : L("开始任务"), action: start).keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).disabled(!canStart)
                        .controlSize(.large)
                }
            }.padding(24).frame(maxWidth: 650)
            Spacer(minLength: 32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
            .fileImporter(isPresented: $chooseFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do { addAttachments(try result.get()) } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $showSetup) {
                AddHostSheet(model: model, host: kimi.host) { launch in
                    selectProvider(launch.provider); cwd = launch.directory; agentModel = launch.model
                }
            }
            .onChange(of: kimi.host.id) { _, _ in
                if !availableProviders.contains(provider) {
                    selectProvider(availableProviders.first ?? .kimi)
                }
            }
            .onDisappear { if let reference = model.selectedReference, reference.kind != .terminal { model.activateAgentEnvironment(reference.hostID) } }
            .task(id: catalogID) {
                // A native catalog is now needed before any session exists. Qoder
                // reports none and Kimi reads its own connection.
                guard native.online && (provider == .omp || provider == .dsh || provider == .codex) else { return }
                await native.loadModels()
                guard !Task.isCancelled else { return }
                if provider == .codex { selectCodexModel() }
            }
            .onAppear {
                if let launch = model.launchAfterSetup {
                    model.launchAfterSetup = nil
                    model.activateAgentEnvironment(launch.hostID)
                    provider = launch.provider; cwd = launch.directory; agentModel = launch.model
                } else if let data = UserDefaults.standard.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(TaskLaunchDefaults.self, from: data),
                          model.connections.contains(where: { $0.id == saved.hostID }) {
                    provider = saved.provider; cwd = saved.directory; agentModel = saved.model
                    model.activateAgentEnvironment(saved.hostID)
                } else {
                    let groupItem = model.groupResumeSession ?? model.allSessions.first { model.selectedGroup?.sessions.contains($0.reference) == true }
                    provider = groupItem?.reference.kind ?? model.selectedReference?.kind ?? .kimi
                    if provider == .terminal { provider = .kimi }
                    if let host = groupItem?.reference.hostID { model.activateAgentEnvironment(host) }
                    cwd = groupItem?.directory ?? defaultDirectory(for: model.kimi.host.id)
                    agentModel = UserDefaults.standard.string(forKey: "new.model.\(provider.rawValue)") ?? ""
                }
                if !model.kimi.host.enabledAgents.contains(provider) { provider = model.kimi.host.enabledAgents.first(where: { $0 != .terminal }) ?? .kimi }
                permissionMode = PermissionDefaults.mode(for: provider) ?? PermissionCatalog.runtimeManaged
            }
    }
    private func selectProvider(_ value: SessionKind) {
        provider = value
        agentModel = UserDefaults.standard.string(forKey: "new.model.\(value.rawValue)") ?? ""
        permissionMode = PermissionDefaults.mode(for: value) ?? PermissionCatalog.runtimeManaged
    }
    private func selectCodexModel() {
        if selectedCodexModel != nil { return }
        let saved = UserDefaults.standard.string(forKey: "new.model.codex") ?? ""
        agentModel = codexModels.first { $0.id == saved }?.id ?? codexModels.first?.id ?? ""
    }
    private func addAttachments(_ files: [URL]) {
        for file in files where !attachments.contains(file) { attachments.append(file) }
    }
    private func start() {
        guard canStart else { return }; creating = true
        let text = prompt, selectedModel = agentModel, selectedProvider = provider, directory = cwd, files = attachments
        let selectedPermission = permissionMode
        let defaults = TaskLaunchDefaults(hostID: kimi.host.id, provider: selectedProvider, directory: directory, model: selectedModel)
        Task {
            do {
                if selectedProvider == .kimi {
                    let session = try await kimi.createSession(title: "", cwd: directory, initialPrompt: text,
                                                               model: selectedModel, permissionMode: selectedPermission)
                    if !files.isEmpty { kimi.attachments[session.id] = files }
                    model.newKimiCreated(session)
                    await kimi.sendPrompt(for: session.id)
                } else {
                    let session = try await native.create(provider: selectedProvider, cwd: directory, model: selectedModel,
                                                          permissionMode: selectedPermission)
                    native.drafts[session.id] = text
                    model.newNativeCreated(session)
                    native.send()
                }
                UserDefaults.standard.set(try JSONEncoder().encode(defaults), forKey: defaultsKey)
                UserDefaults.standard.set(selectedModel, forKey: "new.model.\(selectedProvider.rawValue)")
                UserDefaults.standard.set(directory, forKey: savedDirectoryKey(for: kimi.host.id))
                prompt = ""; attachments = []; model.draftingNewTask = false
            } catch { self.error = error.localizedDescription; creating = false }
        }
    }
}
