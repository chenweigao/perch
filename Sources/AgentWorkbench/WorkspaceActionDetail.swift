import SwiftUI
import WorkbenchCore

struct WorkspaceActionDetail: View {
    @Bindable var model: WorkbenchModel
    let item: WorkspaceSession
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                HStack(alignment: .top, spacing: 10) {
                    SessionStatusIndicator(item: item).frame(width: 17, height: 16).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.title3.weight(.medium)).textSelection(.enabled)
                        Text("\(item.hostName) · \(item.directory)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                Button("关闭") { model.inspectingSession = nil }.keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let agents = model.agentConnections(for: item.reference.hostID) {
                        if item.reference.kind == .kimi {
                            KimiActionDetail(model: model, item: item, connection: agents.kimi).id(item.id)
                        } else if item.reference.kind != .terminal {
                            NativeActionDetail(model: model, item: item, connection: agents.native).id(item.id)
                        } else {
                            Text("终端请求需要在原会话中处理。").foregroundStyle(.secondary)
                        }
                    } else { Text("连接后才能查看当前请求。").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("打开完整会话") { model.inspectingSession = nil; model.open(item) }
                Spacer()
                if item.section == .attention {
                    Text("处理完成后进入下一项").font(.caption).foregroundStyle(.secondary)
                    Button("下一项") { model.inspectNext(after: item) }
                        .buttonStyle(.borderedProminent)
                        .tint(WorkbenchTheme.accent).foregroundStyle(WorkbenchTheme.actionGlyph)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 640, height: 620)
    }
}

private struct NativeActionDetail: View {
    @Bindable var model: WorkbenchModel
    let item: WorkspaceSession
    let connection: NativeAgentConnection
    private var snapshot: NativeAgentSnapshot? { connection.snapshot.flatMap { $0.id == item.reference.terminalID ? $0 : nil } }
    private var pending: [String] { snapshot?.interactions.map(\.display) ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !connection.online { Text("已断开连接，请求状态尚未同步。").foregroundStyle(.orange) }
            if let error = connection.actionError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let s = snapshot {
                if let error = s.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                ForEach(s.interactions, id: \.display) { request in
                    NativeInteractionView(connection: connection, request: request, sessionID: item.reference.terminalID)
                }
                PublicResultPreview(model: model, item: item, messages: s.messages,
                    completed: !s.busy && s.interactions.isEmpty && s.error == nil && s.completed > 0,
                    recapSession: "\(connection.host.id):native:\(s.id)", recapRevision: s.taskRecapRevision,
                    loadHistory: { try await connection.recapMessages(for: s.id) },
                    onReviewed: { model.reviewInspected(s, on: connection.host.id) })
            } else if connection.online { ProgressView("正在读取会话…") }
        }.onChange(of: pending) { old, new in
            if !old.isEmpty && new.isEmpty, let s = snapshot, connection.online, s.error == nil,
               connection.actionError == nil, item.section == .attention { model.inspectNext(after: item) }
        }
    }
}

private struct KimiActionDetail: View {
    @Bindable var model: WorkbenchModel
    let item: WorkspaceSession
    let connection: KimiConnection
    private var current: KimiConversation? {
        guard connection.snapshotReady, connection.conversation?.snapshot.session.id == item.reference.terminalID else { return nil }
        return connection.conversation
    }
    private var pending: [String] {
        guard let c = current else { return [] }
        return c.snapshot.pendingApprovals.map { "a:\($0.id)" } + c.snapshot.pendingQuestions.map { "q:\($0.id)" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !connection.online { Text("已断开连接，请求状态尚未同步。").foregroundStyle(.orange) }
            if let error = connection.actionError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let c = current {
                if let error = c.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                ForEach(c.snapshot.pendingApprovals) { approval in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(approval.action).fontWeight(.medium).textSelection(.enabled)
                        KimiToolCard(tool: VisibleTool(id: approval.id, name: approval.toolName,
                            input: approval.toolInputDisplay, status: .awaitingApproval))
                        HStack {
                            Button("仅允许本次") { if connection.selectedId == item.reference.terminalID { connection.resolve(approval, decision: "approved") } }.buttonStyle(.borderedProminent)
                            Button("拒绝") { if connection.selectedId == item.reference.terminalID { connection.resolve(approval, decision: "rejected") } }
                        }.disabled(!connection.online || !connection.snapshotReady || connection.resolving.contains(approval.id))
                    }
                }
                ForEach(c.snapshot.pendingQuestions) { KimiQuestionView(question: $0, sessionID: item.reference.terminalID, connection: connection) }
                PublicResultPreview(model: model, item: item, messages: c.displayMessages,
                    completed: !c.snapshot.session.isTurnRunning && c.snapshot.session.lastTurnReason == "completed" && pending.isEmpty,
                    recapSession: "\(connection.host.id):kimi:\(c.snapshot.session.id)", recapRevision: c.taskRecapRevision,
                    loadHistory: { try await connection.recapMessages(for: c.snapshot.session.id) },
                    onReviewed: { model.reviewInspected(c.snapshot.session, on: connection.host.id) })
            } else if connection.online { ProgressView("正在读取会话…") }
        }.onChange(of: pending) { old, new in
            if !old.isEmpty && new.isEmpty, let c = current, connection.online, c.error == nil,
               connection.actionError == nil, c.snapshot.session.lastTurnReason != "failed",
               item.section == .attention { model.inspectNext(after: item) }
        }
    }
}

private struct PublicResultPreview: View {
    @Bindable var model: WorkbenchModel
    let item: WorkspaceSession
    let messages: [KimiMessage]
    let completed: Bool
    let recapSession: String
    let recapRevision: String?
    let loadHistory: @MainActor () async throws -> [KimiMessage]
    let onReviewed: () -> Void
    @State private var showRecap = false
    @State private var saved = false
    private var excerpt: String {
        let message = messages.last { $0.role == "assistant" && !$0.content.filter { $0.type == "text" }.compactMap(\.visibleText).joined().isEmpty }
        return message?.content.filter { $0.type == "text" }.compactMap(\.visibleText).joined(separator: "\n") ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(completed ? "结果预览" : "最近回复").font(.system(size: 13, weight: .medium))
            if excerpt.isEmpty { Text("没有可预览的文字，请打开完整会话。").foregroundStyle(.secondary) }
            else {
                KimiMarkdown(text: String(excerpt.prefix(3000)))
                if excerpt.count > 3000 { Text("此处显示前 3000 字，完整内容请打开会话。").font(.caption).foregroundStyle(.secondary) }
            }
            if completed {
                HStack {
                    if let revision = recapRevision {
                        Button("查看 Recap") { showRecap.toggle() }
                            .popover(isPresented: $showRecap) {
                                TaskRecapPopover(key: "\(recapSession):\(revision)", messages: loadHistory,
                                                 stateOverride: nil, configuredOverride: nil, onGenerateOverride: nil)
                            }
                    }
                    Button("标为已查看") { onReviewed(); model.inspectingSession = nil }
                    let groups = model.workspace.groups.filter { $0.sessions.contains(item.reference) }
                    if !groups.isEmpty && !excerpt.isEmpty {
                        Menu(saved ? "已保存成果" : "保存到任务组成果") {
                            ForEach(groups) { group in
                                Button(group.name) {
                                    model.addOutcome(GroupOutcome(title: item.title, detail: String(excerpt.prefix(3000)), source: item.reference), to: group.id)
                                    saved = true
                                }
                            }
                        }
                    }
                }.font(.system(size: 12))
            }
        }
    }
}
