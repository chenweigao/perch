import AppKit
import SwiftUI
import WorkbenchCore
import UniformTypeIdentifiers

private let kimiAccent = Color(red: 0.16, green: 0.16, blue: 0.17)
private let kimiPaper = Color(red: 0.965, green: 0.965, blue: 0.96)
private let kimiReadingWidth: CGFloat = ReplyStyle.readingWidth

struct KimiWorkspaceView: View {
    @UILocalization private var L
    @ObservedObject var connection: KimiConnection
    let onNew: () -> Void
    let onInput: () -> Void
    let onResultDisplayed: (KimiSession) -> Void
    @State private var chooseFiles = false
    @State private var activityReview = 0
    @State private var palette = CommandPaletteState()
    var body: some View {
        VStack(spacing: 0) {
            if let conversation = connection.conversation {
                KimiTimeline(connection: connection, activityReview: activityReview, onResultDisplayed: onResultDisplayed)
                if let problem = connection.actionError ?? connection.commandErrors[conversation.snapshot.session.id] ?? conversation.error { errorBanner(problem, canRetry: !connection.snapshotReady) }
                let pending = conversation.snapshot.pendingApprovals.count + conversation.snapshot.pendingQuestions.count
                ConversationActivityBar(activity: ConversationActivity(
                    messages: conversation.displayMessages, isRunning: conversation.snapshot.session.busy,
                    liveTools: conversation.live?.runningTools ?? [], online: connection.online,
                    isThinking: conversation.live?.thinkingText.isEmpty == false && conversation.live?.assistantText.isEmpty != false,
                    isResponding: conversation.live?.assistantText.isEmpty == false,
                    pendingCount: pending, isStopping: connection.isStopping),
                    isRunning: conversation.snapshot.session.busy,
                    timing: connection.timings.turns[conversation.snapshot.session.id],
                    online: connection.online, pendingCount: pending,
                    narrativeSession: "\(connection.host.id):kimi:\(conversation.snapshot.session.id)",
                    onReview: { activityReview += 1 }, onReconnect: { connection.connect() })
                    .id(conversation.snapshot.session.id)
                    .frame(maxWidth: kimiReadingWidth).padding(.horizontal, 36).frame(maxWidth: .infinity).padding(.top, 4)
                composer(sessionID: conversation.snapshot.session.id).id(conversation.snapshot.session.id)
            } else if let id = connection.selectedId {
                VStack(spacing: 14) {
                    if connection.loading { ProgressView("正在读取会话…") }
                    else {
                        Text(connection.actionError ?? L("Unable to load this conversation.")).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Retry") { connection.select(id) }.disabled(!connection.online)
                    }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 42, weight: .light)).foregroundStyle(kimiAccent)
                Text(connection.loading ? "正在读取会话…" : "继续你的 Kimi 对话").font(.system(size: 23, weight: .semibold)).padding(.top, 16)
                Text("选择已有会话，或从一个项目目录开始。") .foregroundStyle(.secondary).padding(.top, 3)
                Button("新建会话") { onNew() }.buttonStyle(.borderedProminent).padding(.top, 18).disabled(!connection.online)
                if let problem = connection.actionError { errorBanner(problem) }
                Spacer()
            }
            if let problem = connection.error { errorBanner("连接中断，显示的是最近同步的内容。\n" + problem) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            .onChange(of: connection.selectedId) { _, _ in palette = CommandPaletteState() }
            .tint(kimiAccent)
            .fileImporter(isPresented: $chooseFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do {
                    let urls = try result.get()
                    if let id = connection.selectedId {
                        addAttachments(urls, to: id)
                    }
                } catch { connection.actionError = error.localizedDescription }
            }

    }

    private func composer(sessionID: String) -> some View {
        VStack(spacing: 10) {
            if let feedback = connection.commandFeedback[sessionID] {
                Text(feedback).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(4).help(feedback)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let completion = palette.completion(for: connection.drafts[sessionID] ?? "", in: KimiCommand.catalog) {
                CommandPalette(completion: completion, selection: palette.selection) { command in
                    apply(command, completion, to: sessionID)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let files = connection.attachments[sessionID], !files.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(files, id: \.self) { file in
                                ComposerAttachment(file: file) { connection.attachments[sessionID]?.removeAll { $0 == file } }
                            }
                        }
                    }
                }
                MessageComposer(text: Binding(get: { connection.drafts[sessionID] ?? "" },
                                              set: { onInput(); connection.drafts[sessionID] = $0; palette.draftChanged($0) }),
                                placeholder: L("继续此任务…"),
                                accessibilityLabel: "Message Kimi", canSend: canSend,
                                onSend: { connection.sendPrompt() },
                                onFiles: { files in addAttachments(files, to: sessionID) },
                                onError: { connection.actionError = $0 },
                                onKey: { handle($0, for: sessionID) })
                HStack(spacing: 10) {
                    ComposerAddButton(supportsFiles: true, disabled: connection.sending) { chooseFiles = true }
                    ModelPicker(models: ModelCatalog.options(connection.models),
                                selection: Binding(get: { connection.modelChoices[sessionID] ?? "" },
                                                   set: { connection.modelChoices[sessionID] = $0 }),
                                current: connection.conversation?.snapshot.session.model ?? "",
                                effortUnavailable: connection.activeModel(for: sessionID)?.supportsThinking == false,
                                compact: true, thinkingModel: connection.activeModel(for: sessionID),
                                thinking: connection.thinkingChoices[sessionID], thinkingDisabled: connection.sending,
                                onThinking: { connection.thinkingChoices[sessionID] = $0 })
                    PermissionPicker(provider: .kimi, capability: connection.permissionCapability(for: sessionID),
                                     disabled: connection.sending) { mode in
                        connection.setPermission(mode, for: sessionID)
                    }
                    Spacer(minLength: 8)
                    ContextMeter(budget: connection.conversation?.snapshot.session.budget,
                                 isStale: !connection.online || !connection.snapshotReady)
                    ComposerActionButton(isRunning: connection.conversation?.snapshot.session.busy == true,
                                         isStopping: connection.isStopping, canSend: canSend, canStop: connection.canStop,
                                         queuedSendTitle: isCommandDraft ? "Run command" : "Steer",
                                         onSend: { connection.sendPrompt() }, onStop: { connection.abort() },
                                         onQueue: isCommandDraft ? nil : { connection.sendPrompt(mode: .nextTurn) })
                }
            }.padding(12).workbenchControlSurface()
            ComposerDeliveryHint(sending: connection.sending, saveError: connection.draftSaveError)
        }.dropDestination(for: URL.self) { files, _ in
            addAttachments(files.filter(\.isFileURL), to: sessionID)
            return files.contains(where: \.isFileURL)
        }.frame(maxWidth: kimiReadingWidth).padding(.horizontal, 36).frame(maxWidth: .infinity).padding(.bottom, 16).padding(.top, 8)
    }
    private func handle(_ key: ComposerKey, for id: String) -> Bool {
        let draft = connection.drafts[id] ?? ""
        guard let completion = palette.completion(for: draft, in: KimiCommand.catalog) else { return false }
        switch key {
        case .up: palette.move(-1, count: completion.matches.count)
        case .down: palette.move(1, count: completion.matches.count)
        case .enter, .tab:
            guard let command = palette.choice(in: completion) else { return false }
            if key == .enter && (completion.filter == command.name || (command.aliases ?? []).contains(completion.filter)) { return false }
            apply(command, completion, to: id)
        case .escape: palette.dismiss(draft)
        }
        return true
    }
    private func apply(_ command: AgentCommand, _ completion: CommandCompletion, to id: String) {
        onInput()
        let draft = SlashCommands.draft(applying: command, to: completion)
        connection.drafts[id] = draft
        palette.draftChanged(draft)
    }
    private func addAttachments(_ files: [URL], to sessionID: String) {
        for file in files where !(connection.attachments[sessionID] ?? []).contains(file) {
            onInput(); connection.attachments[sessionID, default: []].append(file)
        }
    }
    private var isCommandDraft: Bool {
        let draft = connection.drafts[connection.selectedId ?? ""] ?? ""
        return SlashCommands.invocation(in: draft, from: KimiCommand.catalog) != nil
    }
    private var canSend: Bool {
        return connection.online && connection.snapshotReady && !connection.sending && !connection.isStopping &&
        (isCommandDraft ||
        (!(connection.modelChoices[connection.selectedId ?? ""] ?? "").isEmpty || connection.conversation?.snapshot.session.model.isEmpty == false) &&
        (!(connection.drafts[connection.selectedId ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
         !(connection.attachments[connection.selectedId ?? ""] ?? []).isEmpty))
    }
    private func errorBanner(_ text: String, canRetry: Bool = false) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.circle")
            Text(text).textSelection(.enabled)
            Spacer()
            if canRetry {
                Button("Retry") { connection.reloadSelected() }.disabled(!connection.online || connection.loading)
            }
        }.font(.system(size: 12)).foregroundStyle(.orange).padding(12).background(.orange.opacity(0.06)).padding(.horizontal, 28)
    }
}

private struct KimiTimeline: View {
    @ObservedObject var connection: KimiConnection
    var activityReview: Int
    let onResultDisplayed: (KimiSession) -> Void
    @State private var appActive = NSApp.isActive
    @State private var follow = true
    private var readingKey: String { "\(connection.host.id):kimi:\(connection.conversation?.snapshot.session.id ?? "")" }
    private var readingRevision: String { "\(connection.conversation?.lastSeq ?? 0):\(connection.conversation?.live?.assistantText.utf16.count ?? 0)" }
    private var hasNewReply: Bool { ConversationReadingMemory.shared.seenRevision[readingKey] != readingRevision }
    private var displayedResult: KimiSession? {
        guard appActive, follow, ConversationReadingMemory.shared.following[readingKey] != false,
              connection.online, connection.snapshotReady,
              let conversation = connection.conversation, conversation.error == nil,
              conversation.snapshot.session.id == connection.selectedId,
              !conversation.snapshot.session.busy, conversation.snapshot.session.lastTurnReason == "completed",
              conversation.snapshot.pendingApprovals.isEmpty, conversation.snapshot.pendingQuestions.isEmpty else { return nil }
        return conversation.snapshot.session
    }
    var body: some View {
        ScrollViewReader { proxy in
            ConversationScrollView(showsScrollIndicator: !follow, onScroll: { if follow || $0 { ConversationReadingMemory.shared.seenRevision[readingKey] = readingRevision }; follow = $0; ConversationReadingMemory.shared.following[readingKey] = $0 }, onContentSizeChange: {
                if ConversationReadingMemory.shared.following[readingKey] ?? true { proxy.scrollTo("bottom", anchor: .bottom) }
            }) {
                if let c = connection.conversation {
                    if c.hasOlder {
                        Button(connection.loadingOlder ? "加载中…" : "加载更早消息") { follow = false; ConversationReadingMemory.shared.following[readingKey] = false; connection.loadOlder() }
                            .disabled(connection.loadingOlder || !connection.online || !connection.snapshotReady).frame(maxWidth: .infinity)
                    }
                    let running = Set((c.live?.runningTools ?? []).map(\.id))
                    ConversationTranscript(messages: c.displayMessages, api: connection.api, sessionId: c.snapshot.session.id,
                                           running: running, isRunning: c.snapshot.session.busy,
                                           liveTools: c.live?.runningTools ?? [], online: connection.online && connection.snapshotReady, memoryKey: readingKey,
                                           allowsActivitySummaries: true, followsLatest: follow)
                    ForEach(connection.pendingPrompts[c.snapshot.session.id] ?? []) { prompt in
                        VStack(alignment: .leading, spacing: 8) {
                            PendingMessageContent(text: prompt.text, status: prompt.label)
                            if ["queued", "blocked"].contains(prompt.status) && c.snapshot.session.busy {
                                Button("Steer") {
                                    Task { await connection.steerPrompt(prompt.id, for: c.snapshot.session.id) }
                                }.font(.caption).disabled(!connection.online || connection.isStopping)
                            }
                        }.padding(.vertical, 8)
                    }
                    if let notice = c.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
                    Color.clear.frame(height: 1).id("pending-interactions")
                    ForEach(c.snapshot.pendingApprovals) { approval in
                        VStack(alignment: .leading, spacing: 12) {
                            Label("需要你的确认", systemImage: "hand.raised").font(.headline).foregroundStyle(.orange)
                            Text(approval.action).font(.system(size: 13))
                            KimiToolCard(tool: VisibleTool(id: approval.id, name: approval.toolName, input: approval.toolInputDisplay, status: .awaitingApproval))
                            HStack {
                                Button("仅允许本次") { connection.resolve(approval, decision: "approved") }.buttonStyle(.borderedProminent)
                                Button("拒绝") { connection.resolve(approval, decision: "rejected") }
                            }.disabled(!connection.online || !connection.snapshotReady || connection.resolving.contains(approval.id))
                        }.padding(16).background(.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(c.snapshot.pendingQuestions) { question in KimiQuestionView(question: question, connection: connection) }
                }
                Color.clear.frame(height: 1).id("bottom")
            }
            .overlay(alignment: .bottom) {
                ReturnToLatestButton(isVisible: !follow, hasNewReply: hasNewReply) { follow = true; ConversationReadingMemory.shared.following[readingKey] = true; ConversationReadingMemory.shared.seenRevision[readingKey] = readingRevision; proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .task(id: displayedResult.map { "\($0.id):\($0.updatedAt)" }) {
                // Reviewing changes the shared catalog and sidebar. Publish
                // after this view update, not recursively from onChange.
                if let session = displayedResult { onResultDisplayed(session) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in appActive = false }
            .onChange(of: [String(connection.conversation?.snapshot.asOfSeq ?? 0), connection.conversation?.live?.assistantText ?? "", String(connection.conversation?.live?.thinkingText.isEmpty ?? true)]) { _, _ in
                if #unavailable(macOS 15) {
                    if ConversationReadingMemory.shared.following[readingKey] ?? true { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: connection.pendingPrompts[connection.selectedId ?? ""] ?? []) { _, _ in
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
            .task(id: connection.conversation?.snapshot.session.id) {
                // Keep the scroll host across session changes; reset the user
                // follow preference when the newly selected conversation arrives.
                follow = ConversationReadingMemory.shared.following[readingKey] ?? true
                await Task.yield()
                if !Task.isCancelled && follow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

}

private struct KimiQuestionView: View {
    let question: KimiQuestion
    @ObservedObject var connection: KimiConnection
    @State private var choices: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    private var answers: [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for q in question.questions {
            let ids = (choices[q.id] ?? []).sorted()
            let text = (other[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                values[q.id] = q.multiSelect == true && !ids.isEmpty
                    ? .object(["kind": .string("multi_with_other"), "option_ids": .array(ids.map(JSONValue.string)), "other_text": .string(text)])
                    : .object(["kind": .string("other"), "text": .string(text)])
            } else if !ids.isEmpty {
                values[q.id] = q.multiSelect == true ? .object(["kind": .string("multi"), "option_ids": .array(ids.map(JSONValue.string))]) : .object(["kind": .string("single"), "option_id": .string(ids[0])])
            }
        }
        return values
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("等你回答", systemImage: "bubble.left.and.exclamationmark.bubble.right").font(.headline)
            ForEach(question.questions) { q in
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.question).font(.system(size: 14, weight: .medium))
                    if let body = q.body { KimiMarkdown(text: body) }
                    ForEach(q.options) { option in
                        Toggle(isOn: Binding(get: { choices[q.id]?.contains(option.id) == true }, set: { value in
                            if q.multiSelect == true {
                                if value { choices[q.id, default: []].insert(option.id) } else { choices[q.id]?.remove(option.id) }
                            } else { choices[q.id] = value ? [option.id] : []; if value { other[q.id] = "" } }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                if let description = option.description { Text(description).font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                        }.toggleStyle(.checkbox)
                    }
                    if q.allowOther == true || q.options.isEmpty {
                        TextField("填写回答", text: Binding(get: { other[q.id] ?? "" }, set: { other[q.id] = $0; if q.multiSelect != true && !$0.isEmpty { choices[q.id] = [] } })).textFieldStyle(.roundedBorder)
                    }
                }
            }
            Button("提交回答") { connection.answer(question, answers: answers) }.buttonStyle(.borderedProminent)
                .disabled(answers.count != question.questions.count || !connection.online || !connection.snapshotReady || connection.resolving.contains(question.id))
        }.padding(16).background(kimiAccent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct KimiNewSession: View {
    @ObservedObject var connection: KimiConnection
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var cwd = ""
    @State private var creating = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建 Kimi 会话").font(.title2.bold())
            Text("在 \(connection.host.name) 的项目目录中开始工作。").foregroundStyle(.secondary)
            TextField("会话名称（可选）", text: $title).textFieldStyle(.roundedBorder)
            TextField("远端项目绝对路径", text: $cwd).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(creating ? "创建中…" : "创建会话") {
                    creating = true
                    Task {
                        do { try await connection.createSession(title: title, cwd: cwd); onCreated(); dismiss() }
                        catch { self.error = error.localizedDescription; creating = false }
                    }
                }.buttonStyle(.borderedProminent).disabled(creating || !cwd.hasPrefix("/")).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 470)
            .onAppear { cwd = connection.conversation?.snapshot.session.cwd ?? "" }
    }
}
