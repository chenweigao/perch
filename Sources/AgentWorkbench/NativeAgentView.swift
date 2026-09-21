import SwiftUI
import WorkbenchCore

struct NativeAgentView: View {
    @ObservedObject var connection: NativeAgentConnection
    @State private var follow = true
    @State private var palette = CommandPaletteState()
    var body: some View {
        VStack(spacing: 0) {
            if let s = connection.snapshot {
                ScrollViewReader { proxy in
                    ConversationScrollView(showsScrollIndicator: !follow, onScroll: { follow = $0 }, onContentSizeChange: {
                        if follow { proxy.scrollTo("bottom", anchor: .bottom) }
                    }) {
                        ConversationTranscript(messages: s.messages, sessionId: s.id,
                                               running: ToolVisibilityProjection.runningIDs(in: s.messages, busy: s.busy),
                                               isRunning: s.busy, online: connection.online)
                        ForEach(s.interactions, id: \.display) { request in NativeInteractionView(connection: connection, request: request) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                        .overlay(alignment: .bottom) {
                            if !follow { ReturnToLatestButton { follow = true; proxy.scrollTo("bottom", anchor: .bottom) } }
                        }
                        .onChange(of: s.revision) { _, _ in
                            if #unavailable(macOS 15) {
                                if follow { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                        .task(id: s.id) {
                            await Task.yield()
                            if !Task.isCancelled && follow { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                }
                ConversationActivityBar(messages: s.messages, isRunning: s.busy && s.interactions.isEmpty,
                                        isThinking: s.messages.last?.content.last?.type == "thinking")
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
                    NativeRunControls(connection: connection, sessionID: s.id)
                    if let completion = palette.completion(for: connection.drafts[s.id] ?? "", in: s.commands) {
                        CommandPalette(completion: completion, selection: palette.selection) { command in
                            apply(command, completion, to: s.id)
                        }
                    }
                    VStack(spacing: 12) {
                        MessageComposer(text: Binding(get: { connection.drafts[s.id] ?? "" },
                                                      set: { connection.drafts[s.id] = $0; palette.draftChanged($0) }),
                                        accessibilityLabel: "发送给 \(s.provider.label) 的消息",
                                        canSend: canSend(s),
                                        onSend: { connection.send(mode: defaultMode(s)) },
                                        onKey: { key in handle(key, for: s) }).id(s.id)
                        HStack(spacing: 10) {
                            NativeModelControls(connection: connection, snapshot: s)
                            Spacer(minLength: 6)
                            // While a turn runs the label must state what will actually
                            // happen, so a queued message is never shown as steering.
                            if s.busy, let mode = connection.modes(for: s.id).first {
                                Text(mode == .steer ? connection.capabilities.steer.label : "下一轮发送")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button { connection.send(mode: defaultMode(s)) } label: {
                                Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 30, height: 30)
                            }
                                .buttonStyle(.borderedProminent).clipShape(Circle()).accessibilityLabel("发送")
                                .disabled(!canSend(s))
                        }
                    }.padding(16).workbenchControlSurface()
                }.frame(maxWidth: ReplyStyle.readingWidth).padding(.horizontal, 36).frame(maxWidth: .infinity).padding(.bottom, 16)
            } else if connection.online && connection.selectedID == nil {
                Text("此会话已移除，请从侧栏选择其他会话。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView("正在读取对话…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            if !connection.online { HStack { Text(connection.error ?? "正在连接远端服务"); Button("重新连接") { connection.connect() } }.font(.caption).foregroundStyle(.orange).padding(10) }
        }
        .onChange(of: connection.selectedID) { _, _ in follow = true }
    }
    /// A running session may still accept text when the adapter can queue it, so the
    /// composer is not disabled just because a turn is in progress.
    private func canSend(_ s: NativeAgentSnapshot) -> Bool {
        guard connection.online, !connection.sending else { return false }
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

/// Model, reasoning effort and remaining context for an OMP session. Only OMP
/// answers set_model/set_thinking_level, so a Qoder session keeps the plain label.
struct NativeModelControls: View {
    @ObservedObject var connection: NativeAgentConnection
    let snapshot: NativeAgentSnapshot
    private var session: NativeAgentSession? { connection.sessions.first { $0.id == snapshot.id } }

    var body: some View {
        if snapshot.provider == .omp {
            let current = connection.model(for: snapshot)
            HStack(spacing: 10) {
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
                    if connection.models.isEmpty { Text("正在读取模型列表…") }
                } label: {
                    Text(current?.name ?? (snapshot.model.isEmpty ? "选择模型" : snapshot.model))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    // Switching mid-turn would attribute the running transcript to the
                    // wrong model, so the runtime rejects it and so does the UI.
                    .disabled(!connection.online || snapshot.busy)
                    .help(snapshot.busy ? "运行中不能切换模型" : "切换模型，下一轮生效")
                ThinkingPicker(model: current, current: ThinkingLevel.parse(session?.thinking),
                               disabled: !connection.online) { level in
                    connection.setThinking(level, for: snapshot.id)
                }
                ContextMeter(budget: session?.budget)
            }.task(id: snapshot.id) { await connection.loadModels() }
        } else {
            Text(snapshot.model.isEmpty ? "沿用 Agent 模型" : snapshot.model)
                .font(.caption).foregroundStyle(.secondary)
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
            let pending = connection.queue.items(for: reference)
            VStack(alignment: .leading, spacing: 8) {
                if phase != .idle {
                    HStack(spacing: 10) {
                        if !phase.isSettled { ProgressView().controlSize(.small) }
                        Text(phase.label).font(.caption)
                            .foregroundStyle(phase.canRetry ? .orange : .secondary).textSelection(.enabled)
                        if phase.canRetry { Button("重试停止") { connection.stop() }.font(.caption) }
                    }
                }
                if connection.queue.isPaused(reference) {
                    Button("恢复待发消息") { connection.resumeQueue(reference) }.font(.caption)
                        .disabled(!connection.online || connection.sessions.first(where: { $0.id == sessionID })?.busy != false || !phase.isSettled)
                }
                ForEach(pending) { message in
                    HStack(spacing: 10) {
                        Text(message.mode == .steer ? "引导" : "下一轮").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.06), in: Capsule())
                        Text(message.text).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(message.state.label).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        if message.state.isEditable {
                            Button("编辑") { editingMessage = message }.font(.caption2)
                            Button("移除") { _ = connection.queue.remove(message.id) }.font(.caption2)
                        }
                        switch message.state {
                        case .unknown: Button("核对并重试") { connection.retry(message.id) }.font(.caption2)
                        case .failed:
                            Button("移回草稿") { connection.restoreFailed(message) }.font(.caption2)
                        default: EmptyView()
                        }
                    }
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
        submitting = true
        guard let session = connection.selectedID else { return }
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
    private var recent: [String] { Array(Set(model.allSessions.filter { $0.reference.hostID == kimi.host.id }.map(\.directory).filter { $0.hasPrefix("/") })).sorted() }
    private var canStart: Bool { !creating && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cwd.hasPrefix("/") && (provider == .kimi ? kimi.online : native.online) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("开始新任务").font(.title2.weight(.semibold))
            MessageComposer(text: $prompt, placeholder: "你想完成什么任务？", canSend: canStart, onSend: start)
                .frame(minHeight: 100).padding(14).workbenchControlSurface().disabled(creating)
            Picker("Agent", selection: $provider) { ForEach([SessionKind.kimi, .omp, .qoder], id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented).disabled(creating)
            Text("\(kimi.host.name) · \(model.selectedGroup?.name ?? "工作台")").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("远端项目绝对路径", text: $cwd).textFieldStyle(.roundedBorder).disabled(creating)
                Menu("最近目录") { ForEach(recent, id: \.self) { path in Button(path) { cwd = path } } }.fixedSize().disabled(creating)
            }
            if provider == .kimi {
                ModelPicker(models: ModelCatalog.options(kimi.models), selection: $agentModel).disabled(creating)
            } else {
                TextField(provider == .qoder ? "模型名称（默认 Qwen3.8-Flash）" : "模型（留空沿用远端配置）", text: $agentModel).textFieldStyle(.roundedBorder).disabled(creating)
                Text("创建独立对话，工具在远端执行；待确认操作会留在这里等你处理。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Spacer()
                Button(creating ? "创建中…" : "开始任务", action: start)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canStart)
            }
        }.padding(28).frame(width: 650).onChange(of: provider) { _, value in agentModel = UserDefaults.standard.string(forKey: "new.model.\(value.rawValue)") ?? "" }.onAppear {
            provider = model.selectedReference?.kind == .terminal ? .kimi : model.selectedReference?.kind ?? SessionKind(rawValue: UserDefaults.standard.string(forKey: "new.provider") ?? "kimi") ?? .kimi
            agentModel = UserDefaults.standard.string(forKey: "new.model.\(provider.rawValue)") ?? ""
            cwd = model.selectedItem?.directory ?? UserDefaults.standard.string(forKey: "new.cwd") ?? recent.first ?? ""
        }
    }
    private func start() {
        guard canStart else { return }
        creating = true
        let text = prompt, selectedModel = agentModel, selectedProvider = provider, directory = cwd
        Task {
            do {
                if selectedProvider == .kimi {
                    let session = try await kimi.createSession(title: "", cwd: directory, initialPrompt: text, model: selectedModel)
                    model.newKimiCreated(session)
                    await kimi.sendPrompt(for: session.id)
                } else {
                    let session = try await native.create(provider: selectedProvider, cwd: directory, model: selectedModel.isEmpty && selectedProvider == .qoder ? "Qwen3.8-Flash" : selectedModel)
                    native.drafts[session.id] = text
                    model.newNativeCreated(session)
                    native.send()
                }
                UserDefaults.standard.set(selectedModel, forKey: "new.model.\(selectedProvider.rawValue)")
                UserDefaults.standard.set(selectedProvider.rawValue, forKey: "new.provider")
                UserDefaults.standard.set(directory, forKey: "new.cwd")
                prompt = ""; dismiss()
            } catch { self.error = error.localizedDescription; creating = false }
        }
    }
}
