import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

struct NativeAgentView: View {
    @ObservedObject var connection: NativeAgentConnection
    let onResultDisplayed: (NativeAgentSnapshot) -> Void
    @State private var appActive = NSApp.isActive
    @State private var follow = true
    @State private var activityReview = 0
    @State private var palette = CommandPaletteState()
    private var displayedResultKey: String? {
        guard appActive, follow, connection.online,
              let snapshot = connection.snapshot, snapshot.id == connection.selectedID,
              !snapshot.busy, snapshot.interactions.isEmpty, snapshot.error == nil, snapshot.completed > 0 else { return nil }
        let key = "\(connection.host.id):native:\(snapshot.id)"
        guard ConversationReadingMemory.shared.following[key] != false else { return nil }
        return "\(key):\(snapshot.completed)"
    }
    var body: some View {
        VStack(spacing: 0) {
            if let s = connection.snapshot {
                let readingKey = "\(connection.host.id):native:\(s.id)"
                ScrollViewReader { proxy in
                    ConversationScrollView(showsScrollIndicator: !follow, onScroll: { if follow || $0 { ConversationReadingMemory.shared.seenRevision[readingKey] = String(s.revision) }; follow = $0; ConversationReadingMemory.shared.following[readingKey] = $0 }, onContentSizeChange: {
                        if ConversationReadingMemory.shared.following[readingKey] ?? true { proxy.scrollTo("bottom", anchor: .bottom) }
                    }) {
                        ConversationTranscript(messages: s.messages, sessionId: s.id,
                                               running: ToolVisibilityProjection.runningIDs(in: s.messages, busy: s.busy),
                                               isRunning: s.busy, online: connection.online, memoryKey: readingKey,
                                               allowsActivitySummaries: true, followsLatest: follow)
                        NativeRunControls(connection: connection, sessionID: s.id)
                        Color.clear.frame(height: 1).id("pending-interactions")
                        ForEach(s.interactions, id: \.display) { request in NativeInteractionView(connection: connection, request: request) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                        .overlay(alignment: .bottom) {
                            ReturnToLatestButton(isVisible: !follow, hasNewReply: ConversationReadingMemory.shared.seenRevision[readingKey] != String(s.revision)) { follow = true; ConversationReadingMemory.shared.following[readingKey] = true; ConversationReadingMemory.shared.seenRevision[readingKey] = String(s.revision); proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .onChange(of: s.revision) { _, _ in
                            if #unavailable(macOS 15) {
                                if ConversationReadingMemory.shared.following[readingKey] ?? true { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                        .onChange(of: connection.queue.allItems.filter { $0.session.terminalID == s.id }) { _, _ in
                            if #unavailable(macOS 15) {
                                if ConversationReadingMemory.shared.following[readingKey] ?? true { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .init("PerchRevealConversationHit"))) { notice in
                            if (notice.object as? ConversationFindTarget)?.session == readingKey { follow = false }
                        }
                        .onChange(of: activityReview) { _, _ in
                            follow = false; ConversationReadingMemory.shared.following[readingKey] = false; proxy.scrollTo("pending-interactions", anchor: .top)
                        }
                        .task(id: s.id) {
                            follow = ConversationReadingMemory.shared.following[readingKey] ?? true
                            await Task.yield()
                            if !Task.isCancelled && follow { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                }
                .onChange(of: displayedResultKey, initial: true) { _, key in
                    if key != nil { onResultDisplayed(s) }
                }
                ConversationActivityBar(activity: ConversationActivity(
                    messages: s.messages, isRunning: s.busy,
                    running: ToolVisibilityProjection.runningIDs(in: s.messages, busy: s.busy),
                    online: connection.online,
                    isThinking: s.messages.last?.role == "assistant" && s.messages.last?.content.last?.type == "thinking",
                    isResponding: s.messages.last?.role == "assistant" && s.messages.last?.content.last?.type == "text",
                    pendingCount: s.interactions.count, isStopping: connection.isStopping),
                    isRunning: s.busy,
                    timing: connection.timings.turns[s.id],
                    online: connection.online, pendingCount: s.interactions.count,
                    onReview: { activityReview += 1 }, onReconnect: { connection.connect() })
                    .id(s.id).frame(maxWidth: ReplyStyle.readingWidth).padding(.horizontal, 36)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                if let error = connection.actionError ?? s.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10) }
                if let command = s.commandResult {
                    HStack(spacing: 6) {
                        if command.status == "running" { ProgressView().controlSize(.small) }
                        Text(command.status == "running" ? "正在压缩上下文…" : command.error ?? "上下文压缩完成")
                            .font(.caption).foregroundStyle(command.error == nil ? Color.secondary : Color.orange).textSelection(.enabled)
                    }.padding(6)
                }
                VStack(spacing: 8) {
                    if let completion = palette.completion(for: connection.drafts[s.id] ?? "", in: s.commands) {
                        CommandPalette(completion: completion, selection: palette.selection) { command in
                            apply(command, completion, to: s.id)
                        }
                    }
                    VStack(spacing: 8) {
                        MessageComposer(text: Binding(get: { connection.drafts[s.id] ?? "" },
                                                      set: { connection.drafts[s.id] = $0; palette.draftChanged($0) }),
                                        placeholder: L("Continue this task, or type / for commands…"),
                                        accessibilityLabel: "Message \(s.provider.label)",
                                        canSend: canSend(s),
                                        onSend: { connection.send(mode: defaultMode(s)) },
                                        onKey: { key in handle(key, for: s) }).id(s.id)
                        HStack(spacing: 10) {
                            ComposerAddButton(supportsFiles: false)
                            NativeModelControls(connection: connection, snapshot: s)
                            Spacer(minLength: 8)
                            ContextMeter(budget: connection.sessions.first { $0.id == s.id }?.budget)
                            ComposerActionButton(isRunning: s.busy, isStopping: connection.isStopping,
                                                 canSend: canSend(s), canStop: connection.canStop,
                                                 queuedSendTitle: defaultMode(s) == .steer ? "Steer" : "Queue",
                                                 onSend: { connection.send(mode: defaultMode(s)) },
                                                 onStop: { connection.stop() },
                                                 onQueue: defaultMode(s) == .steer ? { connection.send(mode: .nextTurn) } : nil)
                        }
                    }.padding(12).workbenchControlSurface()
                    ComposerDeliveryHint(sending: connection.sending, saveError: connection.draftSaveError)
                }.frame(maxWidth: ReplyStyle.readingWidth).padding(.horizontal, 36).frame(maxWidth: .infinity).padding(.bottom, 16)
            } else if connection.online && connection.selectedID == nil {
                Text("此会话已移除，请从侧栏选择其他会话。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = connection.actionError, let id = connection.selectedID {
                VStack(spacing: 14) {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Retry") { connection.select(id) }.disabled(!connection.online)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView("正在读取对话…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            if !connection.online { HStack { Text(connection.error ?? "正在连接远端服务"); Button("重新连接") { connection.connect() } }.font(.caption).foregroundStyle(.orange).padding(10) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in appActive = false }
        .onChange(of: connection.selectedID) { _, _ in palette = CommandPaletteState() }

    }
    /// A running session may still accept text when the adapter can queue it, so the
    /// composer is not disabled just because a turn is in progress.
    private func canSend(_ s: NativeAgentSnapshot) -> Bool {
        guard connection.online, !connection.sending, !connection.isStopping else { return false }
        guard !(connection.drafts[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !connection.modes(for: s.id).isEmpty
    }
    private func defaultMode(_ s: NativeAgentSnapshot) -> DeliveryMode {
        connection.modes(for: s.id).first ?? .now
    }
    /// The palette claims navigation keys only while it is showing suggestions;
    /// otherwise every key falls through to normal editing and Return still sends.
    private func handle(_ key: ComposerKey, for s: NativeAgentSnapshot) -> Bool {
        let draft = connection.drafts[s.id] ?? ""
        guard let completion = palette.completion(for: draft, in: s.commands) else { return false }
        switch key {
        case .up: palette.move(-1, count: completion.matches.count); return true
        case .down: palette.move(1, count: completion.matches.count); return true
        case .enter, .tab:
            guard let command = palette.choice(in: completion) else { return false }
            if key == .enter && (completion.filter == command.name || (command.aliases ?? []).contains(completion.filter)) { return false }
            apply(command, completion, to: s.id)
            return true
        case .escape: palette.dismiss(draft); return true
        }
    }
    /// Completing only fills the composer. Running the command stays an explicit
    /// send, so a keystroke cannot start work the user has not read back.
    private func apply(_ command: AgentCommand, _ completion: CommandCompletion, to id: String) {
        let draft = SlashCommands.draft(applying: command, to: completion)
        connection.drafts[id] = draft
        palette.draftChanged(draft)
    }
}

/// Model, reasoning effort and remaining context for runtimes that accept route
/// changes — OMP via set_model/set_thinking_level, dsh via ACP config options. A
/// Qoder session keeps the plain label.
struct NativeModelControls: View {
    @ObservedObject var connection: NativeAgentConnection
    let snapshot: NativeAgentSnapshot
    private var session: NativeAgentSession? { connection.sessions.first { $0.id == snapshot.id } }

    var body: some View {
        if snapshot.provider == .omp || snapshot.provider == .dsh {
            let current = connection.model(for: snapshot)
            HStack(spacing: 10) {
                ModelControlWidth {
                Menu {
                    ForEach(Dictionary(grouping: connection.models, by: \.provider).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }, id: \.key) { group in
                        Menu(group.key) {
                            ForEach(group.value) { model in
                                Button {
                                    connection.setModel(model, for: snapshot.id)
                                } label: {
                                    if model.id == snapshot.model { Label(model.name, systemImage: "checkmark") }
                                    else { Text(model.name) }
                                }
                            }
                        }
                    }
                    if connection.models.isEmpty { Text("Loading models…") }
                    if current?.supportsThinking == false {
                        Divider()
                        Text("此模型未提供思考档位设置。")
                    }
                } label: {
                    Text(current?.name ?? (snapshot.model.isEmpty ? "Choose model" : snapshot.model))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.menuStyle(.borderlessButton)
                    // Switching mid-turn would attribute the running transcript to the
                    // wrong model, so the runtime rejects it and so does the UI.
                    .disabled(!connection.online || snapshot.busy)
                    .help(snapshot.busy ? "Models cannot be changed while running" : "Change the model for the next turn")
                }
                ThinkingPicker(model: current, current: ThinkingLevel.parse(session?.thinking),
                               disabled: !connection.online) { level in
                    connection.setThinking(level, for: snapshot.id)
                }
            }.task(id: snapshot.id) { await connection.loadModels() }
        } else {
            Text(snapshot.model.isEmpty ? "Agent model" : snapshot.model)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 240, alignment: .leading)
        }
    }
}

/// Stop state and pending messages for the selected session. Both read from the
/// connection's controllers, so the label always reflects protocol evidence rather
/// than the fact that a request was sent.
struct NativeRunControls: View {
    @ObservedObject var connection: NativeAgentConnection
    let sessionID: String
    @State private var editingMessage: OutboundMessage?

    private var reference: SessionReference? { connection.reference(sessionID) }
    var body: some View {
        if let reference {
            let phase = connection.stops.phase(for: reference)
            let visible = Set(connection.snapshot?.messages.map(\.id) ?? [])
            let pending = connection.queue.items(for: reference).filter { !visible.contains($0.id) }
            VStack(alignment: .leading, spacing: 8) {
                if phase != .idle {
                    HStack(spacing: 10) {
                        if !phase.isSettled { ProgressView().controlSize(.small) }
                        Text(phase.label).font(.caption)
                            .foregroundStyle(phase.canRetry ? .orange : .secondary).textSelection(.enabled)
                        if phase.canRetry { Button("Retry stop") { connection.stop() }.font(.caption) }
                    }
                }
                if connection.queue.isPaused(reference) {
                    Button("Resume queued messages") { connection.resumeQueue(reference) }.font(.caption)
                        .disabled(!connection.online || connection.sessions.first(where: { $0.id == sessionID })?.busy != false || !phase.isSettled)
                }
                ForEach(pending) { message in
                    VStack(alignment: .leading, spacing: 8) {
                        PendingMessageContent(text: message.text,
                                              status: message.mode == .steer && message.state == .accepted
                                                ? "Accepted · waiting for context" : message.state.label,
                                              mode: message.mode == .steer ? "Steer" : "Queue")
                        HStack(spacing: 10) {
                            if message.state.isEditable {
                                Button("Edit") { editingMessage = message }.font(.caption2)
                                Button("Remove") { _ = connection.queue.remove(message.id) }.font(.caption2)
                            }
                            switch message.state {
                            case .unknown: Button("Sync and retry") { connection.retry(message.id) }.font(.caption2)
                            case .failed:
                                Button("Move to draft") { connection.restoreFailed(message) }.font(.caption2)
                            default: EmptyView()
                            }
                        }
                    }.padding(.vertical, 8)
                }
                if let warning = connection.queue.unsentWarning(for: reference) {
                    Text(warning).font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .sheet(item: $editingMessage) { message in
                    PendingMessageEditor(message: message) { text in
                        connection.queue.edit(message.id, text: text)
                    }
                }
        }
    }
}

private struct PendingMessageEditor: View {
    let message: OutboundMessage
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var messageError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑待发消息").font(.headline)
            TextEditor(text: $text).frame(minHeight: 140)
            if let messageError { Text(messageError).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    if save(text) { dismiss() }
                    else { messageError = "消息已经提交，修改未保存。可复制这里的文字作为新的补充。" }
                }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 460).onAppear { text = message.text }
    }
}

struct NativeInteractionView: View {
    @ObservedObject var connection: NativeAgentConnection
    let request: JSONValue
    @State private var text = ""
    @State private var answers: [String: String] = [:]
    @State private var submitting = false
    private var id: String { request["id"].string ?? "" }
    private func submit(_ fields: [String: JSONValue]) {
        guard !submitting, let session = connection.selectedID else { return }
        submitting = true
        Task {
            do { try await connection.action(session, "answer", fields.merging(["id": .string(id)]) { _, new in new }) }
            catch { connection.actionError = error.localizedDescription; submitting = false }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("等你处理", systemImage: "hand.raised").font(.headline)
            Text(request["title"].string ?? request["name"].string ?? "回答问题").textSelection(.enabled)
            if let message = request["message"].string { Text(message).font(.callout).textSelection(.enabled) }
            if request["name"].string == "AskUserQuestion" {
                ForEach(request["input"]["questions"].array, id: \.display) { q in
                    let question = q["question"].string ?? ""
                    Text(question)
                    ForEach(q["options"].array, id: \.display) { option in
                        Button(option["label"].string ?? option.display) { answers[question] = option["label"].string ?? option.display }.buttonStyle(.bordered)
                    }
                    TextField("回答", text: Binding(get: { answers[question] ?? "" }, set: { answers[question] = $0 })).textFieldStyle(.roundedBorder)
                }
                Button("提交回答") { submit(["allow": .bool(true), "answers": .object(answers.mapValues(JSONValue.string))]) }
                    .disabled(request["input"]["questions"].array.contains { (answers[$0["question"].string ?? ""] ?? "").isEmpty })
            } else if request["type"].string == "interaction" {
                KimiToolCard(tool: VisibleTool(id: request["id"].string ?? "approval", name: request["name"].string ?? "工具", input: request["input"], status: .awaitingApproval))
                HStack { Button("仅允许本次") { submit(["allow": .bool(true)]) }; Button("拒绝") { submit(["allow": .bool(false)]) } }
            } else if request["method"].string == "select" {
                ForEach(request["options"].array, id: \.display) { option in Button(option.string ?? option.display) { submit(["value": option]) } }
                Button("取消") { submit(["cancelled": .bool(true)]) }
            } else if request["method"].string == "confirm" {
                HStack { Button("确认") { submit(["allow": .bool(true)]) }; Button("拒绝") { submit(["allow": .bool(false)]) } }
            } else {
                TextField("填写回答", text: $text).textFieldStyle(.roundedBorder)
                HStack { Button("提交") { submit(["value": .string(text)]) }; Button("取消") { submit(["cancelled": .bool(true)]) } }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10)).disabled(!connection.online || submitting)
    }
}

struct NewConversationSheet: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var native: NativeAgentConnection
    @ObservedObject var kimi: KimiConnection
    @Environment(\.dismiss) private var dismiss
    @AppStorage("new.task.prompt") private var prompt = ""
    @State private var provider: SessionKind = .kimi
    @State private var cwd = ""
    @State private var agentModel = ""
    @State private var creating = false
    @State private var error: String?
    @State private var attachments: [URL] = []
    @State private var chooseFiles = false
    @State private var showSetup = false
    private var availableProviders: [SessionKind] { kimi.host.enabledAgents.filter { $0 != .terminal } }
    private var connectionError: String? { provider == .kimi ? kimi.error : native.error }
    private var defaultsKey: String { "new.task.defaults." + (model.selectedGroupID?.uuidString ?? "global") }
    private var recent: [String] { Array(Set(model.allSessions.filter { $0.reference.hostID == kimi.host.id }.map(\.directory).filter { $0.hasPrefix("/") })).sorted() }
    /// Attachments ride the Kimi session channel; native adapters have none, so an
    /// attachment-only draft can start a Kimi task but never a native one.
    private var canStart: Bool {
        let hasContent = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (provider == .kimi && !attachments.isEmpty)
        return !creating && hasContent && (provider == .kimi || attachments.isEmpty) && cwd.hasPrefix("/") && (availableProviders.contains(provider) && (provider == .kimi ? kimi.online : native.online))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Start a task").font(.title2.weight(.semibold))
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
                MessageComposer(text: $prompt, placeholder: "What would you like to work on?", canSend: canStart, onSend: start,
                                onFiles: provider == .kimi ? addAttachments : nil,
                                onError: { error = $0 })
            }.frame(minHeight: 100).padding(14).workbenchControlSurface().disabled(creating)
            if provider != .kimi && !attachments.isEmpty {
                Text("Choose Kimi or remove the attachments to start this task.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ComposerAddButton(supportsFiles: provider == .kimi, disabled: creating) { chooseFiles = true }
                Menu {
                    ForEach(model.connections) { connection in
                        Button(connection.host.name) { agentModel = ""; model.activateAgentEnvironment(connection.id) }
                    }
                } label: { Label(kimi.host.name, systemImage: "server.rack") }
                Picker("Agent", selection: Binding(get: { provider }, set: { provider = $0; agentModel = UserDefaults.standard.string(forKey: "new.model.\($0.rawValue)") ?? "" })) { ForEach(availableProviders, id: \.self) { Text($0.label).tag($0) } }.frame(width: 200)
                Spacer()
                if provider == .kimi { ModelPicker(models: ModelCatalog.options(kimi.models), selection: $agentModel) }
            }.disabled(creating)
            HStack {
                Image(systemName: "folder")
                TextField("Project directory (absolute path)", text: $cwd).textFieldStyle(.roundedBorder)
                Menu("Recent") { ForEach(recent, id: \.self) { path in Button(path) { cwd = path } } }
            }.disabled(creating)
            if provider != .kimi {
                TextField(provider == .dsh ? "Model (default: the dsh catalog's current route)" : "Model (empty uses the agent default)", text: $agentModel).textFieldStyle(.roundedBorder).disabled(creating)
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
            Button("配置其他 Agent…") { showSetup = true }.font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Spacer()
                Button(creating ? "Starting…" : "Start task", action: start).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(!canStart)
            }
        }.padding(24).frame(width: 650)
            .fileImporter(isPresented: $chooseFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do { addAttachments(try result.get()) } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $showSetup) {
                AddHostSheet(model: model, host: kimi.host) { launch in
                    provider = launch.provider; cwd = launch.directory; agentModel = launch.model
                }
            }
            .onChange(of: kimi.host.id) { _, _ in
                if !availableProviders.contains(provider) { provider = availableProviders.first ?? .kimi }
            }
            .onDisappear { if let reference = model.selectedReference, reference.kind != .terminal { model.activateAgentEnvironment(reference.hostID) } }
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
                    cwd = groupItem?.directory ?? model.selectedItem?.directory ?? UserDefaults.standard.string(forKey: "new.cwd") ?? recent.first ?? ""
                    agentModel = UserDefaults.standard.string(forKey: "new.model.\(provider.rawValue)") ?? ""
                }
                if !model.kimi.host.enabledAgents.contains(provider) { provider = model.kimi.host.enabledAgents.first(where: { $0 != .terminal }) ?? .kimi }
            }
    }
    private func addAttachments(_ files: [URL]) {
        for file in files where !attachments.contains(file) { attachments.append(file) }
    }
    private func start() {
        guard canStart else { return }; creating = true
        let text = prompt, selectedModel = agentModel, selectedProvider = provider, directory = cwd, files = attachments
        let defaults = TaskLaunchDefaults(hostID: kimi.host.id, provider: selectedProvider, directory: directory, model: selectedModel)
        Task {
            do {
                if selectedProvider == .kimi {
                    let session = try await kimi.createSession(title: "", cwd: directory, initialPrompt: text, model: selectedModel)
                    if !files.isEmpty { kimi.attachments[session.id] = files }
                    model.newKimiCreated(session)
                    await kimi.sendPrompt(for: session.id)
                } else {
                    let session = try await native.create(provider: selectedProvider, cwd: directory, model: selectedModel)
                    native.drafts[session.id] = text
                    model.newNativeCreated(session)
                    native.send()
                }
                UserDefaults.standard.set(try JSONEncoder().encode(defaults), forKey: defaultsKey)
                UserDefaults.standard.set(selectedModel, forKey: "new.model.\(selectedProvider.rawValue)")
                UserDefaults.standard.set(directory, forKey: "new.cwd")
                prompt = ""; attachments = []; dismiss()
            } catch { self.error = error.localizedDescription; creating = false }
        }
    }
}
