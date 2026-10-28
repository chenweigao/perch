import AppKit
import SwiftUI
import WorkbenchCore
import UniformTypeIdentifiers

private let kimiAccent = WorkbenchTheme.accent
private let kimiReadingWidth: CGFloat = ReplyStyle.readingWidth

struct KimiWorkspaceView: View {
    @UILocalization private var L
    let connection: KimiConnection
    let onNew: () -> Void
    let onInput: () -> Void
    let onResultDisplayed: (KimiSession) -> Void
    @State private var activityReview = 0
    @State private var transcriptSubject: KimiTask?
    @State private var editStats = SessionEditStatsCache()
    var body: some View {
        #if PERCH_ACCEPTANCE
        let _ = { NativeAcceptanceProbe.shared.kimiBodyEvaluations += 1 }()
        #endif
        VStack(spacing: 0) {
            if let conversation = connection.conversation {
                KimiGoalHeader(connection: connection, sessionID: conversation.snapshot.session.id)
                    .id(conversation.snapshot.session.id)
                KimiTimeline(connection: connection, activityReview: activityReview, onResultDisplayed: onResultDisplayed) {
                    bottomBar(conversation)
                }
            } else if let id = connection.selectedId {
                VStack(spacing: 14) {
                    if connection.loading { ProgressView("正在读取会话…") }
                    else {
                        Text(connection.actionError ?? L("无法读取此会话。")).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Retry") { connection.select(id) }.disabled(!connection.online)
                    }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 42, weight: .light)).foregroundStyle(kimiAccent)
                Text(connection.loading ? "正在读取会话…" : "继续你的 Kimi 对话").font(.system(size: 23, weight: .semibold)).padding(.top, 16)
                Text("选择已有会话，或从一个项目目录开始。") .foregroundStyle(.secondary).padding(.top, 3)
                Button("新建会话") { onNew() }.buttonStyle(.borderedProminent).padding(.top, 18).disabled(!connection.online)
                if let problem = connection.actionError { ConversationNotice(text: problem) }
                Spacer()
            }
            // An open conversation reports disconnection, its detail and the
            // reconnect action in the activity bar; do not repeat it below.
            if let problem = connection.error, connection.online || connection.conversation == nil {
                ConversationNotice(text: L("连接中断，显示的是最近同步的内容。") + "\n" + problem, symbol: "wifi.exclamationmark")
            }
            // An upgraded package with an older service still running. Informational: the
            // session keeps working. Perch restarts only the Kimi Web it started, once idle.
            if let notice = connection.staleRuntimeNotice {
                ConversationNotice(text: notice, symbol: "info.circle", tint: .secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(WorkbenchTheme.contentBackground)
            .tint(kimiAccent)
            .onChange(of: connection.selectedId) { _, _ in
                transcriptSubject = nil
            }
            .sheet(item: $transcriptSubject) { task in
                KimiSubagentTranscriptSheet(agentId: task.transcriptAgentId ?? task.id, subject: task,
                                            connection: connection)
            }

    }

    /// Activity, notices and the composer float over the transcript's bottom
    /// edge as its safe-area bar.
    @ViewBuilder private func bottomBar(_ conversation: KimiConversation) -> some View {
        VStack(spacing: 0) {
            if let problem = connection.actionError ?? connection.commandErrors[conversation.snapshot.session.id] ?? conversation.error {
                ConversationNotice(text: problem, action: connection.snapshotReady ? nil : reloadAction)
            }
            let pending = conversation.snapshot.pendingApprovals.count + conversation.snapshot.pendingQuestions.count
            let recapKey = conversation.taskRecapRevision.map {
                "\(connection.host.id):kimi:\(conversation.snapshot.session.id):\($0)"
            }
            let activityProbe = PerfDiagnostics.begin()
            let messages = conversation.displayMessages
            let activity = ConversationActivity(
                messages: messages, isRunning: conversation.snapshot.session.isTurnRunning,
                liveTools: conversation.live?.runningTools ?? [], online: connection.online,
                isThinking: conversation.live?.thinkingText.isEmpty == false && conversation.live?.assistantText.isEmpty != false,
                isResponding: conversation.live?.assistantText.isEmpty == false,
                pendingCount: pending, isStopping: connection.isStopping, editStats: editStats)
            let _ = PerfDiagnostics.end("activity_derive", activityProbe, detail: "messages=\(messages.count)")
            ConversationActivityBar(activity: activity,
                isRunning: conversation.snapshot.session.isTurnRunning,
                timing: connection.timings.turns[conversation.snapshot.session.id],
                online: connection.online, offlineDetail: connection.error, pendingCount: pending,
                narrativeSession: "\(connection.host.id):kimi:\(conversation.snapshot.session.id)",
                recapKey: recapKey,
                recapMessages: { try await connection.recapMessages(for: conversation.snapshot.session.id) },
                onReview: { activityReview += 1 }, onReconnect: { connection.connect() },
                board: conversation.tasks,
                loadingTaskOutput: connection.loadingTaskOutput,
                stoppingTasks: connection.stoppingTasks,
                taskListError: connection.taskListError,
                onTaskOutput: { connection.loadTaskOutput($0) },
                onTaskStop: { connection.cancelTask($0) },
                onTasksRefresh: { Task { await connection.refreshTasks() } },
                onOpenTranscript: { transcriptSubject = $0 })
                .id(conversation.snapshot.session.id)
                .frame(maxWidth: kimiReadingWidth).padding(.horizontal, ReplyStyle.horizontalPadding).frame(maxWidth: .infinity, alignment: .center).padding(.top, 4)
            KimiComposerView(connection: connection, sessionID: conversation.snapshot.session.id, onInput: onInput)
                .id(conversation.snapshot.session.id)
        }
    }

    /// Offered with an error while the selected session's snapshot is not ready.
    private var reloadAction: ConversationNotice.Action {
        ConversationNotice.Action(title: L("Retry"), isDisabled: !connection.online || connection.loading) {
            connection.reloadSelected()
        }
    }
}

private struct KimiComposerView: View {
    @UILocalization private var L
    let connection: KimiConnection
    let sessionID: String
    let onInput: () -> Void
    @State private var chooseFiles = false
    @State private var palette = CommandPaletteState()
    @State private var recall = ComposerRecall()
    var body: some View {
        VStack(spacing: 10) {
            if let feedback = connection.commandFeedback[sessionID] {
                Text(feedback).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(4).help(feedback)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let completion = palette.completion(for: connection.drafts[sessionID] ?? "", in: commands) {
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
                ProjectMessageComposer(text: Binding(get: { connection.drafts[sessionID] ?? "" },
                                              set: { onInput(); connection.drafts[sessionID] = $0; palette.draftChanged($0); recall.draftChanged($0) }),
                                host: connection.host, cwd: connection.conversation?.snapshot.session.cwd ?? "",
                                placeholder: placeholder,
                                accessibilityLabel: L("Message Kimi"), canSend: canSend,
                                onSend: { connection.sendPrompt() },
                                onQueue: nextTurnSend,
                                onFiles: { files in addAttachments(files, to: sessionID) },
                                onError: { connection.actionError = $0 },
                                onKey: { handle($0, for: sessionID) },
                                pastes: connection.pastes).id(sessionID)
                ComposerToolbarLayout {
                    ComposerAddButton(supportsFiles: true, disabled: connection.sending) { chooseFiles = true }
                    Group {
                        let sessionModel = connection.conversation?.snapshot.session.model ?? ""
                        let choice = connection.modelChoices[sessionID] ?? ""
                        ComposerModelPicker(models: connection.catalog,
                                            modelID: choice.isEmpty ? sessionModel : choice,
                                            thinking: connection.thinkingChoices[sessionID],
                                            disabledReason: !connection.online ? L("连接恢复后可修改设置。")
                                                : !connection.snapshotReady ? L("正在同步会话，请稍候。")
                                                : connection.sending ? L("消息发送中，请稍候。") : nil,
                                            catalogError: connection.modelsError,
                                            onRefreshCatalog: { await connection.refreshModels() },
                                            sessionModel: sessionModel, usesSessionModel: choice.isEmpty,
                                            onUseSessionModel: {
                                                connection.modelChoices[sessionID] = ""
                                                connection.thinkingChoices[sessionID] = connection.activeModel(for: sessionID)?.resolve(connection.thinkingChoices[sessionID])
                                            }, scope: L("下一条消息生效"), onSelectModel: { model in
                                                connection.modelChoices[sessionID] = model.id
                                                connection.thinkingChoices[sessionID] = model.resolve(connection.thinkingChoices[sessionID])
                                            }, onSelectThinking: { connection.thinkingChoices[sessionID] = $0 })
                    }
                    HStack(spacing: 6) {
                        ComposerEnvironmentMenu(host: connection.host, provider: "Kimi",
                                                directory: connection.conversation?.snapshot.session.cwd ?? "")
                        PermissionPicker(provider: .kimi, capability: connection.permissionCapability(for: sessionID),
                                         disabled: connection.sending) { mode in
                            connection.setPermission(mode, for: sessionID)
                        }
                        ComposerTemplatesMenu(draft: connection.drafts[sessionID] ?? "") { template in
                            onInput()
                            let existing = connection.drafts[sessionID] ?? ""
                            connection.drafts[sessionID] = existing.isEmpty ? template : existing + "\n\n" + template
                            NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil)
                        }
                        ContextMeter(budget: connection.conversation?.snapshot.session.budget,
                                     isStale: !connection.online || !connection.snapshotReady,
                                     autoCompactHost: connection.host.id, autoCompactSession: sessionID)
                    }.foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.primary.opacity(WorkbenchTheme.Stroke.hairline)).frame(width: 1, height: 16)
                        }
                    ComposerActionButton(isRunning: isRunning,
                                         isStopping: connection.isStopping, canSend: canSend, canStop: connection.canStop,
                                         queuedSendTitle: isCommandDraft ? "Run command" : "Steer",
                                         onSend: { connection.sendPrompt() }, onStop: { connection.abort() },
                                         onQueue: nextTurnSend)
                }
            }.padding(ReplyStyle.composerInset).workbenchComposerSurface()
            ComposerDeliveryHint(sending: connection.sending, saveError: connection.draftSaveError,
                                 draftLength: (connection.drafts[sessionID] ?? "").count)
        }.dropDestination(for: URL.self) { files, _ in
            addAttachments(files.filter(\.isFileURL), to: sessionID)
            return files.contains(where: \.isFileURL)
        }
        // Project commands appear once the session's working directory is known.
        .task(id: connection.conversation?.snapshot.session.cwd ?? "") {
            connection.loadProjectCommands(for: sessionID)
        }
        // Images dragged from browsers arrive as image data, not file URLs.
        .dropDestination(for: NSImage.self) { images, _ in
            var accepted = false
            for image in images {
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                do {
                    addAttachments([try ComposerAttachments.saveImageToTemp(png)], to: sessionID)
                    accepted = true
                } catch { connection.actionError = error.localizedDescription }
            }
            return accepted
        }.frame(maxWidth: ReplyStyle.composerWidth).padding(.horizontal, ReplyStyle.composerPadding).frame(maxWidth: .infinity, alignment: .center).padding(.bottom, 16).padding(.top, 8)
            .fileImporter(isPresented: $chooseFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do {
                    let urls = try result.get()
                    addAttachments(urls, to: sessionID)
                } catch { connection.actionError = error.localizedDescription }
            }

    }
    private func handle(_ key: ComposerKey, for id: String) -> Bool {
        let draft = connection.drafts[id] ?? ""
        if let completion = palette.completion(for: draft, in: commands) {
            switch key {
            case .up: palette.move(-1, count: completion.matches.count)
            case .down: palette.move(1, count: completion.matches.count)
            case .enter, .tab:
                guard let command = palette.choice(in: completion) else { return false }
                // Runtime commands fully typed run on Return; project commands
                // expand into the draft instead (the runtime does not know them).
                if command.prompt == nil, key == .enter && (completion.filter == command.name || (command.aliases ?? []).contains(completion.filter)) { return false }
                apply(command, completion, to: id)
            case .escape: palette.dismiss(draft)
            }
            return true
        }
        // With no palette open, an empty draft offers Up-arrow prompt recall.
        if let next = recall.handle(key, draft: draft, entries: connection.historyEntries(for: id)) {
            onInput(); connection.drafts[id] = next; palette.draftChanged(next)
            return true
        }
        return false
    }
    private func apply(_ command: AgentCommand, _ completion: CommandCompletion, to id: String) {
        onInput()
        let draft = command.prompt != nil ? ProjectCommandCatalog.expand(command, arguments: "")
            : SlashCommands.draft(applying: command, to: completion)
        connection.drafts[id] = draft
        palette.draftChanged(draft)
    }
    private func addAttachments(_ files: [URL], to sessionID: String) {
        for file in files where !(connection.attachments[sessionID] ?? []).contains(file) {
            if let refusal = ComposerAttachments.refusal(for: file).map({ L(key: $0) }) {
                connection.actionError = "\(file.lastPathComponent): \(refusal)"
                continue
            }
            onInput(); connection.attachments[sessionID, default: []].append(file)
        }
    }
    private var isCommandDraft: Bool {
        let draft = connection.drafts[connection.selectedId ?? ""] ?? ""
        return SlashCommands.invocation(in: draft, from: KimiCommand.catalog) != nil
    }
    /// The runtime's catalog plus the session's project commands (loaded lazily
    /// once the working directory is known).
    private var commands: [AgentCommand] {
        KimiCommand.catalog + (connection.projectCommands[sessionID] ?? [])
    }
    private var isRunning: Bool { connection.conversation?.snapshot.session.isTurnRunning == true }
    /// Return steers a running turn; ⌘Return and the send menu queue the prompt
    /// for the next turn without steering. Commands run at once: no next turn.
    private var nextTurnSend: (() -> Void)? {
        guard isRunning, !isCommandDraft else { return nil }
        return { connection.sendPrompt(mode: .nextTurn) }
    }
    /// Says what Return does. It shows only over an empty draft, never a command.
    private var placeholder: String {
        isRunning ? L("回车引导当前轮，⌘回车排到下一轮…") : L("Continue this task, or type / for commands…")
    }
    private var canSend: Bool {
        let id = connection.selectedId ?? ""
        let hasText = !(connection.drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Offline text queues locally; commands and attachments wait for the server.
        if !connection.online {
            return hasText && (connection.attachments[id] ?? []).isEmpty && !isCommandDraft
        }
        return connection.snapshotReady && !connection.sending && !connection.isStopping &&
        (isCommandDraft ||
        (!(connection.modelChoices[id] ?? "").isEmpty || connection.conversation?.snapshot.session.model.isEmpty == false) &&
        (hasText || !(connection.attachments[id] ?? []).isEmpty))
    }
}

/// Locally queued offline sends for this session. Editable until the server
/// accepts them; unknown receipts need an explicit retry, never auto-replay.
private struct KimiQueuedMessages: View {
    let connection: KimiConnection
    let sessionID: String
    @State private var editing: OutboundMessage?
    var body: some View {
        let reference = connection.reference(for: sessionID)
        let items = connection.queue.items(for: reference)
        // A queue paused at restart also holds messages queued while offline.
        if connection.queue.isPaused(reference), !items.isEmpty {
            Button("继续发送排队消息") { connection.resumeQueue(for: sessionID) }.font(.subheadline)
                .disabled(!connection.online)
        }
        ForEach(items) { message in
            PendingMessageContent(text: message.text, status: message.state.label,
                                  mode: message.mode == .steer ? "Steer" : "Queue") {
                if message.state.isEditable {
                    // Reorder like ccgui's queue rows: arrows stay visible
                    // at both ends and disable instead of disappearing.
                    let editable = items.filter { $0.state.isEditable }
                    if editable.count > 1, let position = editable.firstIndex(where: { $0.id == message.id }) {
                        Button { connection.moveQueued(message.id, up: true) } label: {
                            Image(systemName: "chevron.up").frame(width: 22, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(position == 0)
                            .help("上移，更早发送").accessibilityLabel("上移")
                        Button { connection.moveQueued(message.id, up: false) } label: {
                            Image(systemName: "chevron.down").frame(width: 22, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(position == editable.count - 1)
                            .help("下移，更晚发送").accessibilityLabel("下移")
                    }
                    Button("Edit") { editing = message }
                    Button("Remove") { connection.removeQueued(message.id) }
                }
                if case .unknown = message.state {
                    Button("核对并重试") { connection.retryQueued(message.id) }
                    Text("先核对原请求的接收状态，避免重复执行。")
                }
                if case .failed = message.state {
                    Button("Move to draft") { connection.restoreQueued(message) }
                }
            }
        }
        .sheet(item: $editing) { message in
            PendingMessageEditor(message: message) { connection.editQueued(message.id, text: $0) }
        }
    }
}

/// `bar` (activity, notices and the composer) floats over the transcript's
/// bottom edge; the reply scrolls beneath the composer glass.
private struct KimiTimeline<Bar: View>: View {
    let connection: KimiConnection
    var activityReview: Int
    let onResultDisplayed: (KimiSession) -> Void
    @ViewBuilder let bar: Bar
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
              !conversation.snapshot.session.isTurnRunning, conversation.snapshot.session.lastTurnReason == "completed",
              conversation.snapshot.pendingApprovals.isEmpty, conversation.snapshot.pendingQuestions.isEmpty else { return nil }
        return conversation.snapshot.session
    }
    var body: some View {
        ScrollViewReader { proxy in
            ConversationScrollView(showsScrollIndicator: !follow, onScroll: { if follow || $0 { ConversationReadingMemory.shared.seenRevision[readingKey] = readingRevision }; follow = $0; ConversationReadingMemory.shared.following[readingKey] = $0 }, onContentSizeChange: {
                if ConversationReadingMemory.shared.following[readingKey] ?? true { proxy.scrollTo("bottom", anchor: .bottom) }
            }, onNearTop: {
                if ConversationReadingMemory.shared.following[readingKey] == false { connection.loadOlder() }
            }, showsReturnToLatest: !follow, hasNewReply: hasNewReply, onReturnToLatest: {
                follow = true
                ConversationReadingMemory.shared.following[readingKey] = true
                ConversationReadingMemory.shared.seenRevision[readingKey] = readingRevision
                proxy.scrollTo("bottom", anchor: .bottom)
            }) {
                if let c = connection.conversation {
                    if c.hasOlder {
                        HStack(spacing: 6) {
                            if connection.loadingOlder {
                                ProgressView().controlSize(.small)
                                Text("正在加载更早消息…")
                            } else {
                                // Approaching the top already loads; this stays for keyboard and VoiceOver.
                                Button("加载更早消息") { follow = false; ConversationReadingMemory.shared.following[readingKey] = false; connection.loadOlder() }
                                    .buttonStyle(.borderless).disabled(!connection.online || !connection.snapshotReady)
                            }
                        }.font(.system(size: ReplyStyle.captionSize)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 2)
                    }
                    let running = Set((c.live?.runningTools ?? []).map(\.id))
                    ConversationTranscript(messages: c.displayMessages, api: connection.api, sessionId: c.snapshot.session.id,
                                           running: running, isRunning: c.snapshot.session.isTurnRunning,
                                           liveTools: c.live?.runningTools ?? [], online: connection.online && connection.snapshotReady, memoryKey: readingKey,
                                           allowsActivitySummaries: true, followsLatest: follow, historyEpoch: c.snapshot.epoch,
                                           foldsProcess: true, waitsForInitialPosition: true,
                                           timing: connection.timings.turns[c.snapshot.session.id])
                        .environment(\.conversationActionContext,
                                     ConversationActionContext(hostID: connection.host.id, kind: .kimi, sessionID: c.snapshot.session.id))
                    ForEach(connection.pendingPrompts[c.snapshot.session.id] ?? []) { prompt in
                        PendingMessageContent(text: prompt.text, status: prompt.label) {
                            if ["queued", "blocked"].contains(prompt.status) && c.snapshot.session.isTurnRunning {
                                Button("Steer") {
                                    Task { await connection.steerPrompt(prompt.id, for: c.snapshot.session.id) }
                                }.disabled(!connection.online || connection.isStopping)
                            }
                        }
                    }
                    KimiQueuedMessages(connection: connection, sessionID: c.snapshot.session.id)
                    if let notice = c.notice { Text(notice).font(.system(size: ReplyStyle.labelSize)).foregroundStyle(.orange).textSelection(.enabled) }
                    Color.clear.frame(height: 1).id("pending-interactions")
                    ForEach(c.snapshot.pendingApprovals) { approval in
                        VStack(alignment: .leading, spacing: 12) {
                            Label("需要你的确认", systemImage: "hand.raised").font(.headline).foregroundStyle(.orange)
                            Text(approval.action).font(.system(size: ReplyStyle.labelSize))
                            KimiToolCard(tool: VisibleTool(id: approval.id, name: approval.toolName, input: approval.toolInputDisplay, status: .awaitingApproval))
                            HStack {
                                Button("仅允许本次") { connection.resolve(approval, decision: "approved") }.buttonStyle(.borderedProminent)
                                Button("拒绝") { connection.resolve(approval, decision: "rejected") }
                            }.disabled(!connection.online || !connection.snapshotReady || connection.resolving.contains(approval.id))
                        }.padding(16).background(.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
                    }
                    ForEach(c.snapshot.pendingQuestions) { question in KimiQuestionView(question: question, connection: connection) }.id(c.snapshot.session.id)
                }
                Color.clear.frame(height: 1).id("bottom")
            } bar: {
                bar
            }
            .task(id: displayedResult.map { "\($0.id):\($0.updatedAt)" }) {
                // Reviewing changes the shared catalog and sidebar. Publish
                // after this view update, not recursively from onChange.
                if let session = displayedResult { onResultDisplayed(session) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in appActive = false }
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

struct KimiQuestionView: View {
    let question: KimiQuestion
    var sessionID: String? = nil
    let connection: KimiConnection
    @State private var choices: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    /// Multi-select questions confirmed mid-flow (ccgui 确认本题并继续); the last
    /// outstanding question goes straight to the final submit instead.
    @State private var confirmed: Set<String> = []
    @State private var editing: String?

    private func answered(_ q: KimiQuestion.Item) -> Bool {
        !(choices[q.id] ?? []).isEmpty
            || !(other[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func done(_ q: KimiQuestion.Item) -> Bool {
        editing != q.id && answered(q) && (confirmed.contains(q.id)
            || (q.multiSelect != true && (other[q.id] ?? "").isEmpty && !(choices[q.id] ?? []).isEmpty))
    }
    /// The first unfinished question drives the flow; single-select answers
    /// advance it automatically.
    private var currentID: String? { question.questions.first { !done($0) }?.id }
    /// The last unfinished question skips 确认并继续: the final submit covers it.
    private func isLastPending(_ q: KimiQuestion.Item) -> Bool {
        question.questions.filter { !done($0) }.count == 1 && !done(q)
    }
    private var submittable: Bool {
        question.questions.allSatisfy { q in
            answered(q) && (done(q) || isLastPending(q))
        }
    }

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
            ForEach(Array(question.questions.enumerated()), id: \.element.id) { index, q in
                let isCurrent = q.id == currentID
                let isDone = done(q)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(q.question).font(.system(size: ReplyStyle.secondarySize, weight: .medium))
                            .foregroundStyle(isDone ? .secondary : .primary)
                        if isDone {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: ReplyStyle.captionSize))
                            Spacer()
                            Button("修改回答") {
                                confirmed.remove(q.id)
                                // Keep the answer while returning to its editable form.
                                editing = q.id
                            }.font(.subheadline).buttonStyle(.plain)
                        }
                    }
                    if let body = q.body, !isDone { KimiMarkdown(text: body) }
                    if isDone {
                        // Answered questions fold to a summary so the current one owns the space.
                        Text(summary(of: q)).font(.system(size: ReplyStyle.captionSize)).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        ForEach(q.options) { option in
                            Button {
                                choose(option.id, in: q)
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    // Radio for single, checkbox for multi (ccgui marker parity).
                                    Image(systemName: markerImage(for: q, option: option.id))
                                        .font(.system(size: ReplyStyle.secondarySize))
                                        .foregroundStyle(selected(option.id, in: q) ? WorkbenchTheme.accent : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                        if let description = option.description { Text(description).font(.system(size: ReplyStyle.captionSize)).foregroundStyle(.secondary) }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if q.allowOther == true || q.options.isEmpty {
                            TextField("填写回答", text: Binding(get: { other[q.id] ?? "" }, set: { other[q.id] = $0; if q.multiSelect != true && !$0.isEmpty { choices[q.id] = [] } })).textFieldStyle(.roundedBorder)
                        }
                        if answered(q), !isDone, !isLastPending(q) {
                            Button("确认本题并继续") { confirmed.insert(q.id); editing = nil }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                .padding(10)
                .background(isCurrent ? WorkbenchTheme.accent.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row))
            }
            Button("提交回答") {
                guard sessionID == nil || sessionID == connection.selectedId else { return }
                connection.answer(question, answers: answers)
            }.buttonStyle(.borderedProminent)
                .disabled(!submittable || !connection.online || !connection.snapshotReady || connection.resolving.contains(question.id))
        }.padding(16).background(kimiAccent.opacity(0.05), in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
    }

    private func selected(_ option: String, in q: KimiQuestion.Item) -> Bool {
        choices[q.id]?.contains(option) == true
    }
    private func markerImage(for q: KimiQuestion.Item, option: String) -> String {
        let picked = selected(option, in: q)
        if q.multiSelect == true { return picked ? "checkmark.square.fill" : "square" }
        return picked ? "checkmark.circle.fill" : "circle"
    }
    private func choose(_ option: String, in q: KimiQuestion.Item) {
        if q.multiSelect == true {
            if selected(option, in: q) { choices[q.id]?.remove(option) } else { choices[q.id, default: []].insert(option) }
        } else {
            choices[q.id] = [option]
            other[q.id] = ""
            editing = nil
        }
    }
    private func summary(of q: KimiQuestion.Item) -> String {
        let labels = (choices[q.id] ?? []).sorted().compactMap { id in q.options.first { $0.id == id }?.label }
        let text = (other[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (labels + (text.isEmpty ? [] : [text])).joined(separator: "、")
    }
}

struct KimiNewSession: View {
    let connection: KimiConnection
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var cwd = ""
    @State private var creating = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建 Kimi 会话").font(.title2.bold())
            Label {
                Text("在 \(connection.host.name) 的项目目录中开始工作。")
            } icon: { HostIdentityIcon(hostID: connection.host.id) }
                .foregroundStyle(.secondary)
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
