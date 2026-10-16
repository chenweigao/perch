import SwiftUI
import WorkbenchCore

struct ActivityNarrativeHistoryView: View {
    let narrative: ActivityNarrative

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: narrative.phase == .blocked ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(narrative.phase == .blocked ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(narrative.headline).font(.system(size: ReplyStyle.Process.labelSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = narrative.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [narrative.headline, narrative.detail]
            .compactMap { $0 }.joined(separator: ". ")))
    }
}

/// Process records keep source order inside one compact disclosure. Active,
/// failed and uncertain tools remain visible even when the stage is collapsed.
struct KimiActivityView: View {
    @Environment(\.conversationMemoryKey) private var memoryKey
    /// Core lookups (recent targets) read the app language; depending on the
    /// locale re-runs them when the language changes.
    @Environment(\.locale) private var locale
    @RememberedExpansion("expanded") private var expanded
    let entry: ConversationTimelineEntry
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    var narrative: ActivityNarrative? = nil
    var body: some View {
        let items = entry.messages.flatMap(\.content).compactMap { tools[$0.toolCallId ?? ""] }
        #if TRANSCRIPT_CHECKS
        // Occurrences only, and a declaration because ViewBuilder rejects bare
        // expression statements. Records that a collapsed activity row still walks
        // every message and every tool before laying out its header.
        let _ = NavigationRenderMetrics.count("activity_row_body")
        let _ = NavigationRenderMetrics.count("activity_row_message_scan", by: entry.messages.count)
        let _ = NavigationRenderMetrics.count("activity_row_tool_scan", by: items.count)
        #endif
        VStack(alignment: .leading, spacing: 2) {
            DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    HStack(spacing: 8) {
                        if let narrative {
                            Text("\(narrative.headline) · \(items.count) 次调用").lineLimit(1).truncationMode(.tail)
                        } else if entry.isExploration { Text("读取与搜索 · \(items.count) 次调用").fixedSize() }
                        else if !items.isEmpty { Text("思考与工具 · \(items.count) 次调用").fixedSize() }
                        else { Text("运行上下文").fixedSize() }
                        if !expanded {
                            Text(ToolPresentation.recentTargets(items)).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        let attention = items.filter { $0.staysVisible && $0.status != .running }.count
                        if attention > 0 { Text("\(attention) 项需关注").foregroundStyle(.orange).fixedSize() }
                    }.font(.system(size: ReplyStyle.Process.labelSize)).foregroundStyle(.secondary)
                }.disclosureGroupStyle(ProcessDisclosureStyle())
            if expanded, let narrative {
                ActivityNarrativeHistoryView(narrative: narrative).padding(.leading, ReplyStyle.Process.nestedIndent)
            }
            // Each phase contains one part. Offset identity also handles thoughts
            // and tools originating in the same provider message without collisions.
            ForEach(Array(entry.messages.enumerated()), id: \.offset) { index, message in
                if let id = message.content.first?.toolCallId, let tool = tools[id] {
                    if expanded || tool.staysVisible || tool.status == .failed {
                        KimiToolCard(tool: tool)
                            .environment(\.conversationMemoryKey, memoryKey + ":tool:" + tool.id)
                            .padding(.leading, expanded ? ReplyStyle.Process.nestedIndent : 0)
                    }
                } else if expanded {
                    KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId)
                        .environment(\.conversationMemoryKey, memoryKey + ":part:\(index)")
                        .padding(.leading, ReplyStyle.Process.nestedIndent)
                }
            }
        }
    }
}

struct KimiToolCard: View {
    let tool: VisibleTool
    var onExpand: (() -> Void)? = nil
    /// Action and status names come from core lookups in the app language;
    /// depending on the locale re-runs them when the language changes.
    @Environment(\.locale) private var locale
    @RememberedExpansion("expanded") private var expanded
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
    private func attention(exitReport: Int?) -> Bool {
        ([.failed, .missingResult, .disconnected, .awaitingApproval].contains(tool.status) && exitReport == nil) || !tool.hasCall
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
        let showsAttention = attention(exitReport: exitReport)
        // The activity details name the same states with the same words.
        let statusLabel = ConversationActivity.status(of: tool, exitCode: exitReport)
        #if TRANSCRIPT_CHECKS
        // A declaration, not an expression statement: ViewBuilder rejects the latter.
        let _ = NavigationRenderMetrics.count("tool_card_body")
        #endif
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tool.name).foregroundStyle(.secondary)
                    if let input = tool.input { Text("Input").foregroundStyle(.secondary); DisclosureReplyText(text: input.display) }
                    if let progress = tool.progress { Text("Progress").foregroundStyle(.secondary); DisclosureReplyText(text: progress.display) }
                    if let output = tool.output { Text("Output").foregroundStyle(.secondary); DisclosureReplyText(text: output.display) }
                    if tool.input == nil && tool.output == nil && tool.progress == nil { Text("No input or output").foregroundStyle(.secondary) }
                }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(ReplyStyle.paper, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, ReplyStyle.Process.nestedIndent).padding(.top, 5)
            }
        } label: {
            HStack(spacing: 8) {
                Text(ToolPresentation.action(tool.name)).font(.system(size: ReplyStyle.Process.labelSize)).lineLimit(1)
                if summary != tool.name { Text(summary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0)
                if showsAttention || tool.status == .running || exitReport != nil {
                    Image(systemName: symbol(exitReport: exitReport)).font(.system(size: 11)).accessibilityHidden(true)
                    Text(statusLabel).font(.system(size: 11)).fixedSize()
                }
            }.font(.system(size: ReplyStyle.Process.labelSize)).foregroundStyle(showsAttention ? Color.orange : Color.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "\(tool.name) · \(summary) · \(statusLabel)"))
                .help(Text(verbatim: [tool.input?["command"].string ?? ToolPresentation.path(tool), statusLabel].compactMap { $0 }.joined(separator: "\n")))
        }.disclosureGroupStyle(ProcessDisclosureStyle())
            .onChange(of: expanded) { _, value in if value { onExpand?() } }
    }
}
