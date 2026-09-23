import SwiftUI
import WorkbenchCore

/// Process records keep source order inside one compact disclosure. Active,
/// failed and uncertain tools remain visible even when the stage is collapsed.
struct KimiActivityView: View {
    @Environment(\.conversationMemoryKey) private var memoryKey
    @RememberedExpansion("expanded") private var expanded
    let entry: ConversationTimelineEntry
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    var summary: String? = nil
    var body: some View {
        let items = entry.messages.flatMap(\.content).compactMap { tools[$0.toolCallId ?? ""] }
        let grouped = entry.messages.count > 1 || items.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            if grouped {
                if let summary {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("自动摘要", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(summary).font(.system(size: 13)).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                }
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    HStack(spacing: 8) {
                        if entry.isExploration { Text("读取与搜索 · \(items.count) 次调用").fixedSize() }
                        else if !items.isEmpty { Text("过程记录 · \(items.count) 次调用").fixedSize() }
                        else { Text("运行上下文").fixedSize() }
                        if !expanded {
                            Text(ToolPresentation.recentTargets(items)).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        let attention = items.filter { $0.staysVisible && $0.status != .running }.count
                        if attention > 0 { Text("\(attention) 项需关注").foregroundStyle(.orange).fixedSize() }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }.disclosureGroupStyle(WorkbenchDisclosureStyle(horizontalPadding: 0))
            }
            // Each phase contains one part. Offset identity also handles thoughts
            // and tools originating in the same provider message without collisions.
            ForEach(Array(entry.messages.enumerated()), id: \.offset) { index, message in
                if let id = message.content.first?.toolCallId, let tool = tools[id] {
                    if !grouped || expanded || tool.staysVisible {
                        KimiToolCard(tool: tool, onExpand: { if !grouped { expanded = true } })
                            .environment(\.conversationMemoryKey, memoryKey + ":tool:" + tool.id)
                            .padding(.leading, grouped && expanded ? 20 : 0)
                    }
                } else if expanded {
                    KimiMessageView(message: message, tools: tools, api: api, sessionId: sessionId)
                        .environment(\.conversationMemoryKey, memoryKey + ":part:\(index)")
                        .padding(.leading, 20)
                }
            }
        }
    }
}

struct KimiToolCard: View {
    let tool: VisibleTool
    var onExpand: (() -> Void)? = nil
    @RememberedExpansion("expanded") private var expanded
    private var summary: String {
        ToolPresentation.compactTarget(tool)
    }
    private var label: String {
        switch tool.status {
        case .running: return "Running"
        case .succeeded: return "Completed"
        case .returned: return "Returned"
        case .failed: return "Failed"
        case .missingResult: return "Result not received"
        case .disconnected: return "Disconnected · Status unknown"
        case .awaitingApproval: return "Needs approval"
        }
    }
    private var symbol: String {
        switch tool.status {
        case .running: return "circle.dotted"
        case .succeeded: return "checkmark"
        case .returned: return "tray"
        case .failed: return "exclamationmark.circle"
        case .missingResult, .disconnected: return "questionmark.circle"
        case .awaitingApproval: return "hand.raised"
        }
    }
    private var attention: Bool {
        [.failed, .missingResult, .disconnected, .awaitingApproval].contains(tool.status) || !tool.hasCall
    }
    private var statusLabel: String { tool.hasCall ? label : "\(label) · Call record missing" }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tool.name).foregroundStyle(.secondary)
                    if let input = tool.input { Text("Input").foregroundStyle(.secondary); SelectableReplyText(input.display) }
                    if let progress = tool.progress { Text("Progress").foregroundStyle(.secondary); SelectableReplyText(progress.display) }
                    if let output = tool.output { Text("Output").foregroundStyle(.secondary); SelectableReplyText(output.display) }
                    if tool.input == nil && tool.output == nil && tool.progress == nil { Text("暂无Input或返回内容").foregroundStyle(.secondary) }
                }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(ReplyStyle.paper, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 10).padding(.top, 5)
            }
        } label: {
            HStack(spacing: 8) {
                Text(ToolPresentation.action(tool.name)).font(.system(size: 12)).lineLimit(1)
                if summary != tool.name { Text(summary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0)
                if attention || tool.status == .running {
                    Image(systemName: symbol).font(.system(size: 11)).accessibilityHidden(true)
                    Text(statusLabel).font(.system(size: 11)).fixedSize()
                }
            }.font(.system(size: 12)).foregroundStyle(attention ? Color.orange : Color.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "\(tool.name) · \(summary) · \(statusLabel)"))
                .help(Text(verbatim: [tool.input?["command"].string ?? ToolPresentation.path(tool), statusLabel].compactMap { $0 }.joined(separator: "\n")))
        }.disclosureGroupStyle(WorkbenchDisclosureStyle(horizontalPadding: 0))
            .onChange(of: expanded) { _, value in if value { onExpand?() } }
    }
}
