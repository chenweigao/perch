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

/// Process records keep source order inside one compact disclosure. Active and
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
    @RememberedExpansion("expanded") private var expanded
    let entry: ConversationTimelineEntry
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    var narrative: ActivityNarrative? = nil
    var isLive = false
    var planProgress: TurnStatus.Progress? = nil
    var reduceMotionOverride: Bool? = nil
    private var reduceMotion: Bool { reduceMotionOverride ?? (systemReduceMotion || conversationReduceMotion) }

    private func progressPulse(_ items: [VisibleTool]) -> Int {
        var hasher = Hasher()
        hasher.combine(narrative?.revision ?? 0)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.status)
            if item.status == .running { hasher.combine(item.progress?.display.utf16.count ?? -1) }
        }
        return hasher.finalize()
    }

    var body: some View {
        let items = entry.messages.flatMap(\.content).compactMap { tools[$0.toolCallId ?? ""] }
        let hasRunningTool = items.contains { $0.status == .running }
        let activeStage = isLive || hasRunningTool
        let waitingForModel = isLive && !hasRunningTool
        let editStat = SessionEditStats.derive(from: entry.messages)
        #if TRANSCRIPT_CHECKS
        // Occurrences only, and a declaration because ViewBuilder rejects bare
        // expression statements. Records that a collapsed activity row still walks
        // every message and every tool before laying out its header.
        let _ = NavigationRenderMetrics.count("activity_row_body")
        let _ = NavigationRenderMetrics.count("activity_row_message_scan", by: entry.messages.count)
        let _ = NavigationRenderMetrics.count("activity_row_tool_scan", by: items.count)
        #endif
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    HStack(spacing: 8) {
                        if let narrative {
                            let eyebrow = items.isEmpty ? narrative.phase.label : L("\(narrative.phase.label) · \(items.count) 次调用")
                            Text(verbatim: eyebrow).fixedSize()
                            if !expanded, !hasRunningTool, let last = items.last {
                                let action = ToolPresentation.action(last.name)
                                let target = ToolPresentation.compactTarget(last)
                                let lastDesc = target == last.name ? action : "\(action) \(target)"
                                Text(verbatim: "· " + L("最近：\(lastDesc)"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else if entry.isExploration {
                            let label = ToolPresentation.explorationBucketSummary(items)
                            Text(verbatim: label).fixedSize()
                                .overlay {
                                    if activeStage && !reduceMotion {
                                        ShimmerGlint(text: label, size: ReplyStyle.captionSize, pulse: progressPulse(items))
                                    }
                                }
                        } else if !items.isEmpty {
                            let label = L("思考与工具 · \(items.count) 次调用")
                            Text(verbatim: label).fixedSize()
                                .overlay {
                                    if activeStage && !reduceMotion {
                                        ShimmerGlint(text: label, size: ReplyStyle.captionSize, pulse: progressPulse(items))
                                    }
                                }
                        } else {
                            Text("运行上下文").fixedSize()
                        }
                        if !expanded && narrative == nil {
                            let targets = ToolPresentation.recentTargets(items)
                            // Command names read as code; a sentence-like description stays prose.
                            Text(targets).font(.system(size: ReplyStyle.captionSize,
                                                       design: Self.readsAsCommands(targets) ? .monospaced : .default))
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(WorkbenchTheme.quiet)
                        }
                        Spacer(minLength: 0)
                        let attention = items.filter { $0.staysVisible && $0.status != .running }
                        // One item is named so the collapsed row says what to look at.
                        if attention.count == 1, let only = attention.first {
                            Text("\(ToolPresentation.compactTarget(only)) 需关注").lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.orange)
                        } else if attention.count > 1 {
                            Text("\(attention.count) 项需关注").foregroundStyle(.orange).fixedSize()
                        }
                    }.font(.system(size: ReplyStyle.captionSize)).foregroundStyle(WorkbenchTheme.quiet)
                }.disclosureGroupStyle(ProcessDisclosureStyle())
                if planProgress != nil || editStat != nil {
                    trailingMetadata(planProgress: planProgress, editStat: editStat)
                }
            }
            let tierTwoHeadline: String? = {
                if let narrative, narrative.source != .local { return narrative.headline }
                if let todoTitle = planProgress?.currentTitle, !todoTitle.isEmpty { return todoTitle }
                return narrative?.headline
            }()
            if let tierTwoHeadline {
                Button { expanded.toggle() } label: {
                    Text(verbatim: tierTwoHeadline)
                        .font(.system(size: ReplyStyle.Process.labelSize))
                        .foregroundStyle(Color.primary.opacity(0.76))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topLeading) {
                            if activeStage && !reduceMotion {
                                ShimmerGlint(text: tierTwoHeadline, size: ReplyStyle.Process.labelSize, pulse: progressPulse(items))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: tierTwoHeadline))
                .padding(.leading, ReplyStyle.Process.nestedIndent)
                .padding(.bottom, 2)
            }
            if expanded, let narrative, let detail = narrative.detail, !detail.isEmpty {
                ActivityNarrativeHistoryView(narrative: narrative, sourceText: detail)
                    .padding(.leading, ReplyStyle.Process.nestedIndent)
            }
            // Each phase contains one part. Offset identity also handles thoughts
            // and tools originating in the same provider message without collisions.
            let mergedRanges = expanded ? Self.mergedReadRangesByPath(items) : [:]
            ForEach(Array(entry.messages.enumerated()), id: \.offset) { index, message in
                if let id = message.content.first?.toolCallId, let tool = tools[id] {
                    if expanded || tool.staysVisible {
                        let rangeBadge = ToolPresentation.path(tool).flatMap { mergedRanges[$0] }
                        KimiToolCard(tool: tool, mergedReadRange: rangeBadge)
                            .environment(\.conversationMemoryKey, memoryKey + ":tool:" + tool.id)
                            .padding(.leading, expanded ? ReplyStyle.Process.nestedIndent : 0)
                    }
                } else if expanded {
                    KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId)
                        .environment(\.conversationMemoryKey, memoryKey + ":part:\(index)")
                        .padding(.leading, ReplyStyle.Process.nestedIndent)
                }
            }
            if waitingForModel {
                HStack(spacing: 6) {
                    PerchBusyIndicator(size: 13)
                    Text("工具已返回，正在等待模型下一步推理…")
                        .font(.system(size: ReplyStyle.captionSize))
                        .foregroundStyle(WorkbenchTheme.quiet)
                        .lineLimit(1)
                }
                .padding(.leading, ReplyStyle.Process.nestedIndent)
                .padding(.top, 3)
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

    private func trailingMetadata(planProgress: TurnStatus.Progress?,
                                  editStat: (perFile: [String: SessionEditStat], total: SessionEditStat)?) -> some View {
        HStack(spacing: 8) {
            if let planProgress {
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
            if let editStat {
                if let actionContext {
                    Button { actionContext.post(.showChanges) } label: {
                        EditStatText(stat: editStat.total)
                            .padding(.horizontal, 4).frame(height: 22).contentShape(Rectangle())
                    }.buttonStyle(WorkbenchDisclosureButtonStyle())
                        .help(Text("查看改动：本轮改了 \(editStat.perFile.count) 个文件"))
                        .accessibilityLabel(Text("查看改动"))
                        .accessibilityValue(Text(verbatim: L("本轮改了 \(editStat.perFile.count) 个文件") + " +\(editStat.total.additions) −\(editStat.total.deletions)"))
                } else {
                    EditStatText(stat: editStat.total)
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
        let summary = ToolPresentation.compactTarget(tool)
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
                    Text(ToolPresentation.action(tool.name)).font(.system(size: ReplyStyle.Process.labelSize)).lineLimit(1)
                    if summary != tool.name {
                        HStack(spacing: 0) {
                            Text(summary).lineLimit(1).truncationMode(.middle)
                            if let rangeSuffix {
                                Text(verbatim: rangeSuffix)
                                    .font(.system(size: ReplyStyle.captionSize, design: .monospaced))
                                    .foregroundStyle(WorkbenchTheme.quiet)
                                    .fixedSize()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if let slowLabel {
                        Text(verbatim: slowLabel)
                            .font(.system(size: ReplyStyle.captionSize, design: .monospaced))
                            .foregroundStyle(WorkbenchTheme.quiet)
                            .fixedSize()
                    }
                    // A returned error keeps its quiet status label; only uncertainty
                    // or a user decision earns the orange attention treatment.
                    if showsAttention || tool.status == .running || tool.status == .failed {
                        Image(systemName: symbol(exitReport: exitReport)).font(.system(size: ReplyStyle.captionSize)).accessibilityHidden(true)
                        Text(statusLabel).font(.system(size: ReplyStyle.captionSize)).fixedSize()
                    }
                }.font(.system(size: ReplyStyle.Process.labelSize)).foregroundStyle(showsAttention ? Color.orange : WorkbenchTheme.quiet)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: "\(tool.name) · \(summary) · \(statusLabel)"))
                    .help(Text(verbatim: [tool.input?["command"].string ?? ToolPresentation.path(tool), statusLabel].compactMap { $0 }.joined(separator: "\n")))
            }.disclosureGroupStyle(ProcessDisclosureStyle())
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
                ToolInlineDiffCard(diff: inlineDiff)
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

private struct ToolInlineDiffCard: View {
    let diff: ToolInlineDiff
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
                    EditStatText(stat: diff.stat)
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
