import SwiftUI
import WorkbenchCore

struct ActivityNarrativeHistoryView: View {
    let narrative: ActivityNarrative
    var sourceText: String? = nil
    private var text: String {
        sourceText ?? [narrative.headline, narrative.detail].compactMap { $0 }.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if narrative.phase == .blocked {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: ReplyStyle.captionSize, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text(narrative.phase.label))
            }
            KimiMarkdown(text: text).environment(\.isConversationBodyText, true)
        }
        .textSelection(.enabled)
    }
}

/// Process records keep source order inside an initially expanded disclosure. Active and
/// uncertain tools remain visible even when the stage is collapsed.
struct KimiActivityView: View {
    @Environment(\.conversationMemoryKey) private var memoryKey
    @Environment(\.conversationActionContext) private var actionContext
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.conversationReduceMotion) private var conversationReduceMotion
    /// Core lookups (recent targets) read the app language; depending on the
    /// locale re-runs them when the language changes.
    @Environment(\.locale) private var locale
    @UILocalization private var L
    @RememberedExpansion("expanded", initial: true) private var toolExpanded
    @RememberedExpansion("thought", initial: true) private var thoughtExpanded
    @Environment(\.conversationDisclosureWillChange) private var disclosureWillChange
    private var expansion: Binding<Bool> {
        entry.messages.first?.content.first?.type == "thinking" ? $thoughtExpanded : $toolExpanded
    }
    let entry: ConversationTimelineEntry
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    var narrative: ActivityNarrative? = nil
    var isLive = false
    var liveThinkingSummary: String? = nil
    var planProgress: TurnStatus.Progress? = nil
    var reduceMotionOverride: Bool? = nil
    private var reduceMotion: Bool { reduceMotionOverride ?? (systemReduceMotion || conversationReduceMotion) }
    private func stageStatus(_ tools: [VisibleTool]) -> VisibleTool.Status {
        let priorities: [VisibleTool.Status] = [.failed, .running, .awaitingApproval, .disconnected, .missingResult]
        for state in priorities {
            if tools.contains(where: { $0.status == state }) { return state }
        }
        return .succeeded
    }

    var body: some View {
        let items = entry.messages.flatMap(\.content).compactMap { tools[$0.toolCallId ?? ""] }
        let expanded = expansion.wrappedValue
        let partIDs = entry.processPartIDs
        #if TRANSCRIPT_CHECKS
        let _ = NavigationRenderMetrics.count("activity_row_body")
        let _ = NavigationRenderMetrics.count("activity_row_message_scan", by: entry.messages.count)
        let _ = NavigationRenderMetrics.count("activity_row_tool_scan", by: items.count)
        #endif
        let edit = items.count == 1 && ToolPresentation.isEdit(items[0].name) ? items[0] : nil
        let title = entry.processPhase.map { ToolPresentation.phaseTitle($0, tools: items) }
            ?? items.first.map { ToolPresentation.action($0.name) } ?? L("运行上下文")
        /// The header's trailing summary slot (DSH ToolRow form: title · summary,
        /// packed leading, one line). Priority: the live public summary (follows
        /// the active phase), the running tool's latest output line, the first
        /// failure's line in error ink, then the settled recent-targets list.
        var rowSummary: (text: String, isError: Bool)? {
            if isLive, let liveThinkingSummary { return (liveThinkingSummary, false) }
            if isLive, let running = items.last(where: { $0.status == .running }) {
                let detail = ToolPresentation.runningOutputTail(running, maxLines: 1).last
                    ?? ToolPresentation.rowSummary(running)
                return detail.isEmpty ? nil : (detail, false)
            }
            if let failed = items.first(where: { $0.status == .failed }) {
                let firstLine = failed.output?.display.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                let target = ToolPresentation.rowSummary(failed)
                if let firstLine { return (target.isEmpty ? firstLine : "\(target): \(firstLine)", true) }
                return target.isEmpty ? nil : (L("\(target) 失败"), true)
            }
            let targets = ToolPresentation.recentTargets(items)
            return targets.isEmpty ? nil : (targets, false)
        }
        VStack(alignment: .leading, spacing: 0) {
            if let edit {
                EditStepRow(tool: edit, messageID: entry.messages[0].id, expanded: expansion)
            } else {
                HStack(spacing: 8) {
                    DisclosureGroup(isExpanded: expansion) { EmptyView() } label: {
                        HStack(spacing: 6) {
                            // PI tool rows carry the kind's leading glyph; the
                            // name carries the wording.
                            Image(systemName: ToolPresentation.kindIcon(items.first?.name ?? ""))
                                .font(.system(size: ReplyStyle.captionSize))
                                .foregroundStyle(WorkbenchTheme.quiet)
                                .fixedSize()
                            Text(verbatim: title)
                                .lineLimit(1).truncationMode(.middle).fixedSize()
                                .help(Text(verbatim: title))
                            if !items.isEmpty {
                                ProcessStatusDot(status: stageStatus(items))
                            }
                            if let rowSummary {
                                Text(verbatim: "·").fixedSize()
                                Text(verbatim: rowSummary.text)
                                    .lineLimit(1).truncationMode(.tail)
                                    .foregroundStyle(rowSummary.isError ? Color.red : WorkbenchTheme.quiet)
                                    .layoutPriority(-1)
                            }
                        }.font(.system(size: ReplyStyle.Process.labelSize)).foregroundStyle(WorkbenchTheme.quiet)
                    }.disclosureGroupStyle(ProcessDisclosureStyle())
                        .accessibilityIdentifier("activity-phase:" + entry.id)
                    if let planProgress { trailingMetadata(planProgress: planProgress) }
                }
            }
            if let narrative {
                WorkbenchDisclosureContent(expanded: expanded) {
                    ActivityNarrativeHistoryView(narrative: narrative)
                        .padding(.leading, ReplyStyle.Process.nestedIndent).padding(.top, 4)
                }
            }
            let mergedRanges = Self.mergedReadRangesByPath(items)
            ForEach(entry.messages.indices.map { (id: partIDs[$0], index: $0) }, id: \.id) { part in
                let index = part.index
                let message = entry.messages[index]
                if let id = message.content.first?.toolCallId, let tool = tools[id] {
                    // An edit receipt already carries its status. Keep a single
                    // visible receipt and reveal its raw call from that arrow.
                    let alwaysVisible = edit == nil && ToolPresentation.showsResultOutsideStage(
                        tool, isLive: isLive, lastPartToolID: entry.messages.last?.content.last?.toolCallId)
                    WorkbenchDisclosureContent(expanded: expanded || alwaysVisible) {
                        KimiToolCard(tool: tool, mergedReadRange: ToolPresentation.path(tool).flatMap { mergedRanges[$0] })
                            .environment(\.conversationMemoryKey, memoryKey + ":tool:" + tool.id)
                            .background(ProcessFindAnchor(id: "tool:" + tool.id))
                            .padding(.leading, ReplyStyle.Process.nestedIndent).padding(.top, 4)
                    }
                } else {
                    WorkbenchDisclosureContent(expanded: expanded) {
                        Group {
                            if message.content.first?.type == "thinking" {
                                ThoughtOutput(messages: [message], finished: !isLive, embedded: true)
                                    .environment(\.conversationMemoryKey, memoryKey + ":thought:" + message.id)
                            } else {
                                KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId)
                                    .environment(\.conversationMemoryKey, memoryKey + ":part:\(index)")
                            }
                        }.padding(.leading, ReplyStyle.Process.nestedIndent).padding(.top, 4)
                    }
                }
            }
        }
    }

    private static func mergedReadRangesByPath(_ tools: [VisibleTool]) -> [String: String] {
        var rangesByPath: [String: [String]] = [:]
        var countsByPath: [String: Int] = [:]
        for tool in tools where ["read", "read_file", "readfile"].contains(tool.name.lowercased()) {
            guard let path = ToolPresentation.path(tool), !path.isEmpty else { continue }
            countsByPath[path, default: 0] += 1
            if let range = ToolPresentation.readRange(tool) {
                rangesByPath[path, default: []].append(range)
            }
        }
        var result: [String: String] = [:]
        for (path, ranges) in rangesByPath where (countsByPath[path] ?? 0) > 1 && !ranges.isEmpty {
            result[path] = ToolPresentation.formatMergedReadRanges(ranges)
        }
        return result
    }

    private func trailingMetadata(planProgress: TurnStatus.Progress) -> some View {
        HStack(spacing: 8) {
            Group {
                if let actionContext {
                    Button { actionContext.post(.showTurnDetails) } label: {
                        HStack(spacing: 3) {
                            Text(verbatim: "\(planProgress.done) / \(planProgress.total)")
                            Image(systemName: "chevron.right").font(.system(size: ReplyStyle.captionSize - 2, weight: .semibold))
                        }.padding(.horizontal, 4).frame(height: 22).contentShape(Rectangle())
                    }.buttonStyle(WorkbenchDisclosureButtonStyle())
                        .help(Text("在任务面板查看本轮详情"))
                        .accessibilityLabel(Text("本轮状态"))
                        .accessibilityValue(Text(verbatim: L("\(planProgress.done)/\(planProgress.total) 步")))
                } else {
                    Text(verbatim: "\(planProgress.done) / \(planProgress.total)")
                }
            }
        }
        .font(.system(size: ReplyStyle.captionSize))
        .foregroundStyle(WorkbenchTheme.quiet)
        .monospacedDigit()
        .fixedSize()
    }
}

extension KimiActivityView {
    /// "git diff · sed": every part a short ASCII command, not a described step.
    static func readsAsCommands(_ targets: String) -> Bool {
        let parts = targets.components(separatedBy: " · ")
        return !targets.isEmpty && parts.allSatisfy { part in
            part.allSatisfy(\.isASCII) && part.split(separator: " ").count <= 2
        }
    }
}

struct KimiToolCard: View {
    let tool: VisibleTool
    var mergedReadRange: String? = nil
    var onExpand: (() -> Void)? = nil
    /// Opens the process of the subagent this Agent/Task call started. Left nil,
    /// a transcript row's action context provides it when the session's bridge
    /// records subagents; elsewhere the card stays as it was.
    var onOpenProcess: (() -> Void)? = nil
    /// Action and status names come from core lookups in the app language;
    /// depending on the locale re-runs them when the language changes.
    @Environment(\.locale) private var locale
    @Environment(\.conversationActionContext) private var actionContext
    @RememberedExpansion("expanded") private var expanded
    /// Shown only after expanding, so collapsed row geometry never changes.
    private var openProcess: (() -> Void)? {
        guard ToolPresentation.isSubagentCall(name: tool.name) else { return nil }
        if let onOpenProcess { return onOpenProcess }
        guard let context = actionContext, context.opensSubagents else { return nil }
        let id = tool.id
        return { context.post(.openSubagent(toolCallId: id)) }
    }
    // A failed tool's structured output is serialized by exitCodeReport.
    // Resolve it once per body evaluation and share it across the label.
    private func symbol(exitReport: Int?) -> String {
        switch tool.status {
        case .running: return "circle.dotted"
        case .succeeded: return "checkmark"
        case .returned: return "tray"
        case .failed: return exitReport != nil ? "apple.terminal" : "exclamationmark.circle"
        case .missingResult, .disconnected: return "questionmark.circle"
        case .awaitingApproval: return "hand.raised"
        }
    }
    private func attention() -> Bool {
        // A result without its call record is informational; it stays visible but not orange,
        // like the task panel's tool list.
        [.missingResult, .disconnected, .awaitingApproval].contains(tool.status)
    }
    private func resolvedExitReport() -> Int? {
        #if TRANSCRIPT_CHECKS
        NavigationRenderMetrics.count("tool_card_exit_report_read")
        if tool.status == .failed, let output = tool.output {
            NavigationRenderMetrics.count("tool_card_exit_report_output_display")
            if case .string = output {} else {
                NavigationRenderMetrics.count("tool_card_exit_report_json_encode")
            }
        }
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("tool_card_exit_report", since: start) }
        #endif
        return tool.exitCodeReport
    }
    var body: some View {
        let exitReport = resolvedExitReport()
        let summary = ToolPresentation.rowSummary(tool)
        // Named apart from the method so the local never shadows its own initializer.
        let showsAttention = attention()
        // The activity details name the same states with the same words.
        let statusLabel = ConversationActivity.status(of: tool, exitCode: exitReport)
        #if TRANSCRIPT_CHECKS
        // A declaration, not an expression statement: ViewBuilder rejects the latter.
        let _ = NavigationRenderMetrics.count("tool_card_body")
        #endif
        let liveTail = !expanded && tool.status == .running ? ToolPresentation.runningOutputTail(tool) : []
        VStack(alignment: .leading, spacing: 2) {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    if let openProcess {
                        VStack(alignment: .leading, spacing: 6) {
                            details
                            Button("查看过程", action: openProcess).buttonStyle(.borderless)
                                .font(.system(size: ReplyStyle.Process.labelSize))
                                .padding(.leading, ReplyStyle.Process.nestedIndent)
                                .help("读取这个子 Agent 自己的轮次、思考与工具调用")
                        }
                    } else { details }
                }
            } label: {
                let rangeSuffix = mergedReadRange ?? ToolPresentation.readRange(tool).map { ":\($0)" }
                let slowLabel = ToolPresentation.slowDurationLabel(tool)
                HStack(spacing: 8) {
                    Image(systemName: ToolPresentation.kindIcon(tool.name))
                        .font(.system(size: ReplyStyle.captionSize))
                        .foregroundStyle(WorkbenchTheme.quiet)
                        .fixedSize()
                    Text(ToolPresentation.action(tool.name)).font(.system(size: ReplyStyle.Process.labelSize)).lineLimit(1)
                    if !summary.isEmpty {
                        HStack(spacing: 0) {
                            Text(summary).font(.system(size: ReplyStyle.captionSize, design: .monospaced))
                                .lineLimit(1).truncationMode(.tail)
                            if let rangeSuffix {
                                Text(verbatim: rangeSuffix)
                                    .font(.system(size: ReplyStyle.captionSize, design: .monospaced))
                                    .foregroundStyle(WorkbenchTheme.quiet)
                                    .fixedSize()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    // PI's status cluster: spinner while running, a red exit-code
                    // capsule on failure, a quiet green outcome dot once settled.
                    if tool.status == .running { ProcessStatusDot(status: .running) }
                    if let slowLabel {
                        Text(verbatim: slowLabel)
                            .font(.system(size: ReplyStyle.captionSize, design: .monospaced))
                            .foregroundStyle(WorkbenchTheme.quiet)
                            .fixedSize()
                    }
                    if showsAttention {
                        Image(systemName: symbol(exitReport: exitReport)).font(.system(size: ReplyStyle.captionSize)).accessibilityHidden(true)
                        Text(statusLabel).font(.system(size: ReplyStyle.captionSize)).fixedSize()
                    } else if tool.status == .failed {
                        Text(verbatim: exitReport.map { L("退码 \($0) · 失败") } ?? L("失败"))
                            .font(.system(size: ReplyStyle.captionSize))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(nsColor: .systemRed).opacity(0.12), in: Capsule())
                            .fixedSize()
                            .help(Text("展开查看失败记录"))
                    } else if tool.status == .succeeded || tool.status == .returned {
                        HStack(spacing: 4) {
                            ProcessStatusDot(status: tool.status)
                            Text(L("已完成")).font(.system(size: ReplyStyle.captionSize))
                        }.fixedSize()
                    }
                }.font(.system(size: ReplyStyle.Process.labelSize)).foregroundStyle(showsAttention ? Color.orange : WorkbenchTheme.quiet)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: "\(tool.name) · \(summary) · \(statusLabel)"))
                    .help(Text(verbatim: [tool.input?["command"].string ?? ToolPresentation.path(tool), statusLabel].compactMap { $0 }.joined(separator: "\n")))
            }.disclosureGroupStyle(ProcessDisclosureStyle())
                .accessibilityIdentifier("tool-call:" + tool.id)
                .onChange(of: expanded) { _, value in if value { onExpand?() } }
            if !liveTail.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(liveTail.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(verbatim: index == 0 ? "└" : " ")
                                .foregroundStyle(WorkbenchTheme.quiet.opacity(0.65))
                            Text(verbatim: line)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(WorkbenchTheme.quiet)
                        }
                        .font(.system(size: ReplyStyle.captionSize, design: .monospaced))
                    }
                }
                .padding(.leading, ReplyStyle.Process.nestedIndent)
                .padding(.bottom, 2)
            }
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let inlineDiff = ToolInlineDiff.derive(from: tool) {
                ToolInlineDiffCard(diff: inlineDiff, applied: tool.status == .succeeded)
                if let output = tool.output, tool.status == .failed {
                    Text("Output").foregroundStyle(WorkbenchTheme.quiet)
                    DisclosureReplyText(text: output.display)
                }
            } else {
                Text(tool.name).foregroundStyle(WorkbenchTheme.quiet)
                if let rawCommand = tool.input?["command"].string ?? tool.input?["cmd"].string,
                   ["bash", "shell", "exec_command", "run_command"].contains(tool.name.lowercased()) {
                    Text("Command").foregroundStyle(WorkbenchTheme.quiet)
                    DisclosureReplyText(text: ToolPresentation.cleanShellCommand(rawCommand))
                } else if let input = tool.input {
                    Text("Input").foregroundStyle(WorkbenchTheme.quiet)
                    DisclosureReplyText(text: input.display)
                }
                if let progress = tool.progress { Text("Progress").foregroundStyle(WorkbenchTheme.quiet); DisclosureReplyText(text: progress.display) }
                if let output = tool.output { Text("Output").foregroundStyle(WorkbenchTheme.quiet); DisclosureReplyText(text: output.display) }
                if tool.input == nil && tool.output == nil && tool.progress == nil { Text("No input or output").foregroundStyle(WorkbenchTheme.quiet) }
            }
        }.font(.system(size: ReplyStyle.captionSize, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(ReplyStyle.paper, in: RoundedRectangle(cornerRadius: ReplyStyle.Code.cornerRadius, style: .continuous))
            .padding(.leading, ReplyStyle.Process.nestedIndent).padding(.top, 5)
    }
}

struct ToolInlineDiffCard: View {
    let diff: ToolInlineDiff
    var applied = true
    @UILocalization private var L
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !diff.path.isEmpty {
                    Button {
                        var url = URLComponents(); url.scheme = "perch-file"
                        url.queryItems = [URLQueryItem(name: "path", value: diff.path)]
                        if let target = url.url {
                            NotificationCenter.default.post(name: .init("PerchOpenConversationFile"), object: target)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text").font(.system(size: ReplyStyle.captionSize - 1))
                            Text(verbatim: (diff.path as NSString).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                        }.foregroundStyle(Color.primary.opacity(0.82))
                    }.buttonStyle(.plain).help(Text(verbatim: diff.path))
                }
                Spacer(minLength: 0)
                if diff.stat.additions > 0 || diff.stat.deletions > 0 {
                    if applied { EditStatText(stat: diff.stat) }
                    else { Text(verbatim: "+\(diff.stat.additions) −\(diff.stat.deletions)").foregroundStyle(WorkbenchTheme.quiet) }
                }
            }.font(.system(size: ReplyStyle.captionSize))
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.text)
                        .font(.system(size: ReplyStyle.captionSize, design: .monospaced))
                        .foregroundStyle(foreground(for: line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(background(for: line.kind))
                }
                if diff.truncatedCount > 0 {
                    Text(verbatim: L("… 其余 \(diff.truncatedCount) 行已折叠"))
                        .font(.system(size: ReplyStyle.captionSize))
                        .foregroundStyle(WorkbenchTheme.quiet)
                        .padding(.top, 4)
                }
            }.textSelection(.enabled)
        }
    }
    private func foreground(for kind: ToolInlineDiff.LineKind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.92)
        case .removed: return Color.red.opacity(0.92)
        case .header: return WorkbenchTheme.quiet
        case .context: return Color.primary.opacity(0.75)
        }
    }
    private func background(for kind: ToolInlineDiff.LineKind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.09)
        case .removed: return Color.red.opacity(0.09)
        case .header, .context: return .clear
        }
    }
}

/// The provider's public preview occupies a stable, bounded place in the reader.
/// Secondary tier (13/20 by default), like DSH's thinking summaries.
struct LiveThinkingSummary: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(.system(size: ReplyStyle.secondarySize))
            .foregroundStyle(WorkbenchTheme.quiet)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("live-thinking-summary")
    }
}
