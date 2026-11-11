import AppKit
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

/// Top section of the right inspector: session-wide overview with goal,
/// completed progress, current status, next steps, and explicit blockers.
struct TaskSessionOverviewSection: View {
    @UILocalization private var L
    let model: WorkbenchModel
    let item: WorkspaceSession
    let snapshot: TaskContextSnapshot
    @Bindable var reading: TaskContextReadingState
    @ObservedObject private var recapStore = TaskRecapStore.shared
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @State private var showSettings = false
    @State private var copied = false

    private var sessionScope: String {
        "\(item.reference.hostID):\(item.reference.kind == .kimi ? "kimi" : "native"):\(item.reference.terminalID)"
    }

    private var context: TaskTurnContext? {
        model.turnContext(item.reference, busy: snapshot.busy)
    }

    private var overviewKey: String? {
        snapshot.taskOverviewRevision.map { "\(sessionScope):\($0)" }
    }

    private var currentKey: String? {
        overviewKey ?? context?.recapKey
    }

    private var exactEntry: TaskRecapCache.Entry? {
        overviewKey.flatMap { recapStore.entry(for: $0) }
            ?? context?.recapKey.flatMap { recapStore.entry(for: $0) }
    }

    private var retainedEntry: TaskRecapCache.Entry? {
        exactEntry ?? recapStore.latestEntry(forSession: sessionScope)
    }

    private var isGenerating: Bool {
        recapStore.isLoading(for: overviewKey) || recapStore.isLoading(for: context?.recapKey)
    }

    private var configured: Bool {
        summarySettings.configuration.enabled && summarySettings.configuration.isValid
    }

    private var failureMessage: String? {
        if let overviewKey, case .failed(let message) = recapStore.state(for: overviewKey) { return message }
        if let recapKey = context?.recapKey, case .failed(let message) = recapStore.state(for: recapKey) { return message }
        return nil
    }

    private var overview: SessionOverview? {
        SessionOverview.derive(
            snapshot: snapshot,
            recapEntry: retainedEntry,
            isGeneratingRecap: isGenerating || (exactEntry == nil && retainedEntry != nil && snapshot.busy),
            updatedAtFallback: item.updatedAt > 946_684_800 ? Date(timeIntervalSince1970: item.updatedAt) : nil
        )
    }

    var body: some View {
        let overview = self.overview
        VStack(alignment: .leading, spacing: 8) {
            if let overview {
                overviewCard(overview)
                if let failureMessage {
                    failureBanner(failureMessage)
                }
            } else if isGenerating {
                VStack(alignment: .leading, spacing: 8) {
                    cardTopBar(nil)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在生成会话概述…")
                            .font(.system(size: WorkbenchTheme.Typography.caption))
                            .foregroundStyle(WorkbenchTheme.quiet)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(WorkbenchTheme.Fill.surface,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-overview-loading")
            } else if let failureMessage {
                VStack(alignment: .leading, spacing: 8) {
                    cardTopBar(nil)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("会话概述生成失败", systemImage: "exclamationmark.triangle")
                            .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                            .foregroundStyle(.orange)
                        Text(failureMessage)
                            .font(.system(size: WorkbenchTheme.Typography.caption))
                            .foregroundStyle(WorkbenchTheme.quiet)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button("重试") { triggerGenerate(force: true) }
                                .buttonStyle(.borderless)
                                .fontWeight(.medium)
                            Button("配置活动叙事与 Recap…") { showSettings = true }
                                .buttonStyle(.borderless)
                                .foregroundStyle(WorkbenchTheme.quiet)
                        }.font(.system(size: WorkbenchTheme.Typography.caption))
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("task-overview-failed")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(WorkbenchTheme.Fill.surface,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))
            } else {
                emptyCard
            }
        }
        .font(.system(size: WorkbenchTheme.Typography.body))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-session-overview")
        .task(id: currentKey) {
            guard let key = currentKey, !snapshot.busy, !snapshot.messages.isEmpty else { return }
            let messages = messageProvider()
            recapStore.registerMessages(for: key, provider: messages)
            recapStore.considerAutoGenerate(key: key, messages: messages, settings: summarySettings)
        }
        .sheet(isPresented: $showSettings) { ActivitySummarySettingsSheet() }
    }

    private func cardTopBar(_ overview: SessionOverview?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "leaf")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.green.opacity(0.85))
                    .accessibilityHidden(true)
                Text("会话概述")
                    .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                    .foregroundStyle(WorkbenchTheme.quiet)
                Spacer(minLength: 4)
                if !snapshot.messages.isEmpty {
                    Button {
                        if configured { triggerGenerate(force: true) }
                        else { showSettings = true }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(WorkbenchTheme.quiet)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(WorkbenchDisclosureButtonStyle())
                    .disabled(isGenerating || snapshot.busy)
                    .help(configured ? "更新会话概述" : "配置活动叙事与 Recap…")
                    .accessibilityLabel("更新会话概述")
                    .accessibilityIdentifier("task-overview-refresh")
                }
                if overview != nil {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { reading.overviewExpanded.toggle() }
                    } label: {
                        Text(reading.overviewExpanded ? "收起" : "展开")
                            .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                            .foregroundStyle(WorkbenchTheme.quiet)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(WorkbenchDisclosureButtonStyle())
                    .accessibilityValue(reading.overviewExpanded ? "已展开" : "已收起")
                    .accessibilityIdentifier("task-overview-toggle")
                }
            }
            if overview?.isUpdating == true || isGenerating {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("正在更新…")
                }
                .font(.system(size: WorkbenchTheme.Typography.caption))
                .foregroundStyle(WorkbenchTheme.quiet)
                .accessibilityIdentifier("task-overview-updating")
            } else if let updatedAt = overview?.updatedAt, updatedAt.timeIntervalSince1970 > 0 {
                SessionTimeText(updatedAt: updatedAt.timeIntervalSince1970, tone: .tertiary)
            }
        }
    }

    private func overviewCard(_ overview: SessionOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTopBar(overview)
            Group {
                if reading.overviewExpanded {
                    expandedBody(overview)
                } else {
                    compactBody(overview)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(reading.overviewExpanded ? "task-overview-expanded" : "task-overview-compact")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(WorkbenchTheme.overviewCard,
                    in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous)
            .strokeBorder(WorkbenchTheme.Stroke.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// Default 3–5 line summary covering goal, completed progress, current status/next step, and blockers.
    @ViewBuilder private func compactBody(_ overview: SessionOverview) -> some View {
        if !overview.blockers.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("阻塞")
                    .font(.system(size: WorkbenchTheme.Typography.caption, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(verbatim: overview.blockers.joined(separator: "；"))
                    .font(.system(size: WorkbenchTheme.Typography.caption))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        Text(verbatim: compactParagraph(overview))
            .font(.system(size: WorkbenchTheme.Typography.caption))
            .foregroundStyle(WorkbenchTheme.ink.opacity(0.88))
            .lineSpacing(3)
            .lineLimit(overview.blockers.isEmpty ? 5 : 4)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactParagraph(_ overview: SessionOverview) -> String {
        func trimSentence(_ text: String) -> String {
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix("。") || trimmed.hasSuffix(".") || trimmed.hasSuffix("；") || trimmed.hasSuffix(";") {
                trimmed.removeLast()
            }
            return trimmed
        }
        var sentences: [String] = [trimSentence(overview.goal)]
        if !overview.completed.isEmpty {
            sentences.append("\(L("已完成"))：\(overview.completed.map(trimSentence).joined(separator: "；"))")
        }
        if !overview.inProgress.isEmpty {
            sentences.append("\(L("进行中"))：\(overview.inProgress.map(trimSentence).joined(separator: "；"))")
        } else if !overview.planned.isEmpty {
            sentences.append("\(L("计划"))：\(overview.planned.map(trimSentence).joined(separator: "；"))")
        } else if !overview.nextSteps.isEmpty {
            sentences.append("\(L("下一步"))：\(overview.nextSteps.map(trimSentence).joined(separator: "；"))")
        }
        return sentences.filter { !$0.isEmpty }.joined(separator: "。") + "。"
    }

    @ViewBuilder private func expandedBody(_ overview: SessionOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !overview.blockers.isEmpty {
                expandedSection("阻塞", items: overview.blockers, tint: .orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("目标")
                    .font(.system(size: WorkbenchTheme.Typography.caption, weight: .semibold))
                    .foregroundStyle(WorkbenchTheme.quiet)
                Text(verbatim: overview.goal)
                    .font(.system(size: WorkbenchTheme.Typography.body))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            expandedSection(
                "已完成",
                items: overview.completed.isEmpty ? [L("暂无已完成项")] : overview.completed,
                tint: overview.completed.isEmpty ? WorkbenchTheme.quiet : .primary
            )
            if !overview.validation.isEmpty {
                expandedSection("验证", items: overview.validation, tint: .primary)
            }
            if !overview.inProgress.isEmpty {
                expandedSection("进行中", items: overview.inProgress, tint: .primary)
            }
            if !overview.planned.isEmpty {
                expandedSection("计划", items: overview.planned, tint: WorkbenchTheme.quiet)
            }
            if !overview.nextSteps.isEmpty {
                expandedSection("下一步", items: overview.nextSteps, tint: WorkbenchTheme.quiet)
            }
            HStack(spacing: 12) {
                Button(copied ? "已复制" : "复制") { copyOverview(overview) }
                    .buttonStyle(.borderless)
                Spacer()
                if configured {
                    Button("重新生成") { triggerGenerate(force: true) }
                        .buttonStyle(.borderless)
                        .disabled(isGenerating || snapshot.busy)
                } else {
                    Button("配置活动叙事与 Recap…") { showSettings = true }
                        .buttonStyle(.borderless)
                }
            }
            .font(.system(size: WorkbenchTheme.Typography.caption))
            .foregroundStyle(WorkbenchTheme.quiet)
            .padding(.top, 2)
        }
    }

    private func expandedSection(_ title: LocalizedStringKey, items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: WorkbenchTheme.Typography.caption, weight: .semibold))
                .foregroundStyle(tint == .orange ? .orange : WorkbenchTheme.quiet)
            ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text(verbatim: "•").foregroundStyle(tint == .orange ? .orange : WorkbenchTheme.quiet)
                    Text(verbatim: line)
                        .font(.system(size: WorkbenchTheme.Typography.caption))
                        .foregroundStyle(tint)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .foregroundStyle(WorkbenchTheme.quiet)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试") { triggerGenerate(force: true) }
                .buttonStyle(.borderless)
                .fontWeight(.medium)
                .foregroundStyle(WorkbenchTheme.accent)
        }
        .font(.system(size: WorkbenchTheme.Typography.caption))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WorkbenchTheme.Fill.surface,
                    in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row, style: .continuous))
        .accessibilityIdentifier("task-overview-failed-banner")
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardTopBar(nil)
            VStack(alignment: .leading, spacing: 6) {
                Text("暂无会话概述")
                    .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                    .foregroundStyle(WorkbenchTheme.quiet)
                Text(snapshot.messages.isEmpty
                     ? "开始对话并产生进展后，这里会汇总目标、已完成进展、当前状态与下一步。"
                     : "尚未生成可靠摘要，不会仅用标题或单条消息充当概述。")
                    .font(.system(size: WorkbenchTheme.Typography.caption))
                    .foregroundStyle(WorkbenchTheme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                if !snapshot.messages.isEmpty {
                    HStack(spacing: 12) {
                        Button(configured ? "生成 Recap" : "配置活动叙事与 Recap…") {
                            if configured { triggerGenerate(force: true) }
                            else { showSettings = true }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                        .foregroundStyle(WorkbenchTheme.accent)
                        .disabled(isGenerating || snapshot.busy)
                    }.padding(.top, 2)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("task-overview-empty")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(WorkbenchTheme.Fill.surface,
                    in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))
    }

    private func messageProvider() -> (@MainActor () async throws -> [KimiMessage]) {
        if let context { return context.recapMessages }
        let captured = snapshot.messages
        return { captured }
    }

    private func triggerGenerate(force: Bool) {
        copied = false
        let key = currentKey ?? "\(sessionScope):manual"
        let messages = messageProvider()
        recapStore.registerMessages(for: key, provider: messages)
        recapStore.generate(key: key, force: force, messages: messages, settings: summarySettings)
    }

    private func copyOverview(_ overview: SessionOverview) {
        var blocks = ["\(L("目标"))：\(overview.goal)"]
        if !overview.blockers.isEmpty {
            blocks.append(L("阻塞") + "\n" + overview.blockers.map { "- " + $0 }.joined(separator: "\n"))
        }
        if !overview.completed.isEmpty {
            blocks.append(L("已完成") + "\n" + overview.completed.map { "- " + $0 }.joined(separator: "\n"))
        }
        if !overview.validation.isEmpty {
            blocks.append(L("验证") + "\n" + overview.validation.map { "- " + $0 }.joined(separator: "\n"))
        }
        if !overview.inProgress.isEmpty {
            blocks.append(L("进行中") + "\n" + overview.inProgress.map { "- " + $0 }.joined(separator: "\n"))
        }
        if !overview.planned.isEmpty {
            blocks.append(L("计划") + "\n" + overview.planned.map { "- " + $0 }.joined(separator: "\n"))
        }
        if !overview.nextSteps.isEmpty {
            blocks.append(L("下一步") + "\n" + overview.nextSteps.map { "- " + $0 }.joined(separator: "\n"))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copied = pasteboard.setString(blocks.joined(separator: "\n\n"), forType: .string)
    }
}

/// Fourth section of the right inspector: host, directory, branch, and entry points for changes, files, and run details.
struct TaskEnvironmentDetailsSection: View {
    @UILocalization private var L
    let model: WorkbenchModel
    let item: WorkspaceSession
    let snapshot: TaskContextSnapshot
    private var branchCache: ComposerGitBranchCache { .shared }

    private var host: SSHHost? {
        model.connections.first { $0.id == item.reference.hostID }?.host
    }

    var body: some View {
        let branch = branchCache.branch(hostID: item.reference.hostID, directory: item.directory)
        let changedCount = snapshot.edits?.perFile.count ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("环境与详情")
                    .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                    .foregroundStyle(WorkbenchTheme.quiet)
                Spacer(minLength: 0)
            }.padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    HostIdentityIcon(hostID: item.reference.hostID)
                        .foregroundStyle(WorkbenchTheme.quiet)
                        .frame(width: 16)
                    Text(item.hostName)
                        .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(item.reference.kind.label)
                        .font(.system(size: WorkbenchTheme.Typography.caption))
                        .foregroundStyle(WorkbenchTheme.quiet)
                    if let branch, !branch.isEmpty {
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(verbatim: branch).lineLimit(1)
                        }
                        .font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced))
                        .foregroundStyle(WorkbenchTheme.quiet)
                    }
                }
                if !item.directory.isEmpty {
                    Text(item.directory)
                        .font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced))
                        .foregroundStyle(WorkbenchTheme.quiet)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.directory)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(WorkbenchTheme.Fill.surface,
                        in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    model.taskContextWindow.showPage(.changes, model: model)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: WorkbenchTheme.Typography.caption))
                            .foregroundStyle(WorkbenchTheme.quiet)
                        Text("改动")
                        if changedCount > 0 {
                            Text(verbatim: "\(changedCount)")
                                .font(.system(size: WorkbenchTheme.Typography.caption))
                                .monospacedDigit()
                                .foregroundStyle(WorkbenchTheme.quiet)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TaskContextRowStyle(tinted: true))
                .accessibilityIdentifier("task-context-open-changes")

                Button {
                    model.toggleFileViewer()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: WorkbenchTheme.Typography.caption))
                            .foregroundStyle(WorkbenchTheme.quiet)
                        Text("文件")
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TaskContextRowStyle(tinted: true))
                .accessibilityIdentifier("task-context-open-files")
            }
        }
        .font(.system(size: WorkbenchTheme.Typography.body))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-environment-details")
        .task(id: "\(item.reference.hostID.uuidString):\(item.directory)") {
            if let host {
                await branchCache.load(host: host, directory: item.directory)
            }
        }
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

/// The task page's per-file edits and summary failures, without
/// repeating the transcript's stage narrative or elapsed clock.
struct TaskTurnSection: View {
    let model: WorkbenchModel
    let item: WorkspaceSession
    let snapshot: TaskContextSnapshot
    @ObservedObject private var narratives = ActivityNarrativeStore.shared
    @ObservedObject private var summarySettings = ActivitySummarySettings.shared
    @State private var allEdits = false

    var body: some View {
        let context = model.turnContext(item.reference, busy: snapshot.busy)
        let failure = context.flatMap { narratives.failure(session: $0.narrativeKey)?.message }
        if failure != nil || snapshot.edits != nil {
            VStack(alignment: .leading, spacing: 22) {
                if let edits = snapshot.edits { self.edits(edits) }
                if let failure, let context { externalFailure(failure, key: context.narrativeKey) }
            }.font(.system(size: WorkbenchTheme.Typography.body))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-context-turn")
        }
    }

    private func externalFailure(_ message: String, key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("外部摘要更新失败：\(message)")
                .foregroundStyle(WorkbenchTheme.quiet)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if narratives.canRetry(session: key) {
                Button("重试外部摘要") { narratives.retry(session: key, settings: summarySettings) }
                    .buttonStyle(.borderless)
                    .fontWeight(.medium)
                    .foregroundStyle(WorkbenchTheme.accent)
            }
        }.font(.system(size: WorkbenchTheme.Typography.caption))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(WorkbenchTheme.Fill.surface,
                        in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row, style: .continuous))
    }

    private func edits(_ edits: (perFile: [String: SessionEditStat], total: SessionEditStat)) -> some View {
        let paths = edits.perFile.keys.sorted()
        let shown = allEdits ? paths : Array(paths.prefix(6))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("编辑文件 · \(paths.count)").fontWeight(.medium)
                Spacer()
                if edits.total.additions > 0 || edits.total.deletions > 0 {
                    EditStatText(stat: edits.total)
                }
                Button("查看改动") { model.taskContextWindow.showPage(.changes, model: model) }
                    .buttonStyle(.borderless).help("在右栏查看工作区改动")
            }.padding(.bottom, 4)
            ForEach(shown, id: \.self) { path in
                let stat = edits.perFile[path]!
                let name = (path as NSString).lastPathComponent
                Button {
                    model.taskContextWindow.fileDetail = TaskContextFileRoute(source: item.reference, path: path, name: name)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: TaskContextFileIcon.name(name))
                            .foregroundStyle(WorkbenchTheme.quiet)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(name)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        if stat.additions > 0 || stat.deletions > 0 {
                            EditStatText(stat: stat)
                                .font(.system(size: WorkbenchTheme.Typography.caption))
                        }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(TaskContextRowStyle())
                    .disabled(!item.online)
                    .help(path)
            }
            if paths.count > shown.count || allEdits && paths.count > 6 {
                Button { withAnimation(.snappy(duration: 0.18)) { allEdits.toggle() } } label: {
                    HStack(spacing: 10) {
                        Text(allEdits ? "收起" : "查看全部文件").foregroundStyle(WorkbenchTheme.quiet)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                            .foregroundStyle(WorkbenchTheme.quiet).rotationEffect(.degrees(allEdits ? 90 : 0))
                            .accessibilityHidden(true)
                    }.frame(minHeight: 30).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .font(.system(size: WorkbenchTheme.Typography.caption))
            }
        }
    }
}
