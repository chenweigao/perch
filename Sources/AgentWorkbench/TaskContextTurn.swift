import SwiftUI
import WorkbenchCore

/// What the client itself knows about a session's latest turn, beside the task
/// panel's snapshot: the narrative's key, the client clock and Recap.
struct TaskTurnContext {
    let narrativeKey: String
    let timing: ConversationTiming?
    let recapKey: String?
    let recapMessages: @MainActor () async throws -> [KimiMessage]
}

extension WorkbenchModel {
    /// Read from the connection that owns the session, under the keys the
    /// conversation's status line uses. A running turn never reads the live
    /// conversation here, so streamed tokens do not redraw the panel.
    func turnContext(_ source: SessionReference, busy: Bool) -> TaskTurnContext? {
        guard source.kind != .terminal, let agents = agentConnections(for: source.hostID) else { return nil }
        let id = source.terminalID
        if source.kind == .kimi {
            let kimi = agents.kimi, key = "\(kimi.host.id):kimi:\(id)"
            var recap: String?
            if !busy, let conversation = kimi.conversation, conversation.snapshot.session.id == id {
                recap = conversation.taskRecapRevision.map { "\(key):\($0)" }
            }
            return TaskTurnContext(narrativeKey: key, timing: kimi.timings.turns[id], recapKey: recap,
                                   recapMessages: { try await kimi.recapMessages(for: id) })
        }
        let native = agents.native, key = "\(native.host.id):native:\(id)"
        var recap: String?
        if !busy, native.selectedID == id, let snapshot = native.snapshot, snapshot.id == id {
            recap = snapshot.taskRecapRevision.map { "\(key):\($0)" }
        }
        return TaskTurnContext(narrativeKey: key, timing: native.timings.turns[id], recapKey: recap, recapMessages: {
            guard native.selectedID == id, native.snapshot?.id == id else { throw CancellationError() }
            return try await native.recapMessages(for: id)
        })
    }
}

extension WorkbenchModel {
    /// The files the latest turn edited, as its tools named them, and the
    /// directory relative names resolve against. Only for the conversation the
    /// connection has loaded; read on demand, never observed per token.
    func latestTurnEdits(_ source: SessionReference) -> (paths: [String], directory: String)? {
        guard source.kind != .terminal, let agents = agentConnections(for: source.hostID) else { return nil }
        let messages: [KimiMessage], directory: String
        if source.kind == .kimi {
            guard let conversation = agents.kimi.conversation, conversation.snapshot.session.id == source.terminalID else { return nil }
            messages = conversation.displayMessages; directory = conversation.snapshot.session.cwd
        } else {
            guard let snapshot = agents.native.snapshot, snapshot.id == source.terminalID else { return nil }
            messages = snapshot.messages; directory = snapshot.cwd
        }
        let start = messages.lastIndex(where: \.isUserPrompt) ?? 0
        guard let edits = SessionEditStats.derive(from: Array(messages[start...])) else { return nil }
        return (Array(edits.perFile.keys), directory)
    }
}

/// The task page's turn inventory: plan steps and per-file edits, without
/// repeating the transcript's stage narrative or elapsed clock.
struct TaskTurnSection: View {
    let model: WorkbenchModel
    let item: WorkspaceSession
    let snapshot: TaskContextSnapshot
    @ObservedObject private var narratives = ActivityNarrativeStore.shared
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @State private var allEdits = false
    @UILocalization private var L

    var body: some View {
        let context = model.turnContext(item.reference, busy: snapshot.busy)
        let failure = context.flatMap { narratives.failure(session: $0.narrativeKey)?.message }
        if failure != nil || !snapshot.todos.isEmpty || snapshot.edits != nil {
            VStack(alignment: .leading, spacing: 14) {
                if let failure, let context { externalFailure(failure, key: context.narrativeKey) }
                if !snapshot.todos.isEmpty { plan }
                if let edits = snapshot.edits { self.edits(edits) }
            }.font(.system(size: WorkbenchTheme.Typography.body))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-context-turn")
        }
    }

    private func externalFailure(_ message: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("外部摘要更新失败：\(message)").font(.system(size: WorkbenchTheme.Typography.caption))
                .foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if narratives.canRetry(session: key) {
                Button("重试外部摘要") { narratives.retry(session: key, settings: summarySettings) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var plan: some View {
        let done = snapshot.todos.filter { $0.status == .done }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("计划").fontWeight(.medium)
                Spacer()
                Text(verbatim: "\(done) / \(snapshot.todos.count)").monospacedDigit().foregroundStyle(WorkbenchTheme.quiet)
            }
            ForEach(snapshot.todos) { todo in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: todo.status == .done ? "checkmark.circle.fill"
                          : todo.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                        .foregroundStyle(todo.status == .inProgress ? WorkbenchTheme.accent : WorkbenchTheme.quiet)
                        .accessibilityHidden(true)
                    Text(todo.title).fontWeight(todo.status == .inProgress ? .medium : .regular)
                        .foregroundStyle(todo.status == .done ? WorkbenchTheme.quiet : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: "\(state(todo.status)): \(todo.title)"))
            }
        }
    }
    private func state(_ status: ConversationTodo.Status) -> String {
        switch status {
        case .done: return L("Completed")
        case .inProgress: return L("In progress")
        case .pending: return L("Pending")
        }
    }

    private func edits(_ edits: (perFile: [String: SessionEditStat], total: SessionEditStat)) -> some View {
        let paths = edits.perFile.keys.sorted()
        let shown = allEdits ? paths : Array(paths.prefix(6))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("编辑文件 · \(paths.count)").fontWeight(.medium)
                Spacer()
                EditStatText(stat: edits.total)
                Button("查看改动") { model.taskContextWindow.showPage(.changes, model: model) }
                    .buttonStyle(.borderless).help("在右栏查看工作区改动")
            }
            ForEach(shown, id: \.self) { path in
                HStack {
                    Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    EditStatText(stat: edits.perFile[path]!)
                }.font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
                    .help(path)
            }
            if paths.count > shown.count || allEdits && paths.count > 6 {
                Button(allEdits ? "收起" : "查看全部文件") { allEdits.toggle() }.buttonStyle(.borderless)
                    .font(.system(size: WorkbenchTheme.Typography.caption))
            }
        }
    }
}
