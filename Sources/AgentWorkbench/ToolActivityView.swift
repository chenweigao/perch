import SwiftUI
import WorkbenchCore

/// Adjacent exploration folds as one group. Active and uncertain calls remain
/// visible, and expanding preserves each call's identity and source order.
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
        let context = entry.messages.filter { $0.content.contains(where: \.isRuntimeContext) }
        VStack(alignment: .leading, spacing: 4) {
            if items.count > 1 {
                if let summary {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动摘要").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(summary).font(.system(size: 13)).lineLimit(2).textSelection(.enabled)
                    }.padding(.bottom, 3)
                }
                Button { expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                        Text("读取与搜索 · \(items.count) 次调用")
                        Spacer(minLength: 0)
                        let attention = items.filter { $0.staysVisible && $0.status != .running }.count
                        if attention > 0 { Text("\(attention) 项需关注").foregroundStyle(.orange) }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(WorkbenchDisclosureButtonStyle()).accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if !expanded {
                    ForEach(Array(items.filter { !$0.staysVisible }.suffix(2))) { tool in
                        Text(ToolPresentation.target(tool)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).padding(.leading, 17)
                            .help(ToolPresentation.path(tool) ?? ToolPresentation.target(tool))
                    }
                }
            }
            ForEach(items.filter { items.count == 1 || expanded || $0.staysVisible }) { tool in
                KimiToolCard(tool: tool, onExpand: { if items.count == 1 { expanded = true } })
                    .environment(\.conversationMemoryKey, memoryKey + ":tool:" + tool.id)
            }
            if !context.isEmpty {
                Button { expanded.toggle() } label: {
                    Label("Runtime context", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(WorkbenchDisclosureButtonStyle()).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
            if expanded {
                ForEach(context) { message in
                    // Context may share a message with a tool already rendered above.
                    ForEach(Array(message.content.enumerated()), id: \.offset) { _, part in
                        if part.isRuntimeContext { KimiMarkdown(text: part.text ?? "").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }
            }
        }.padding(.vertical, 2)
    }
}

struct KimiToolCard: View {
    let tool: VisibleTool
    var onExpand: (() -> Void)? = nil
    @RememberedExpansion("expanded") private var expanded
    private var summary: String {
        ToolPresentation.target(tool)
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
                Image(systemName: symbol).font(.system(size: 11)).accessibilityHidden(true)
                Text(ToolPresentation.action(tool.name)).font(.system(size: 11)).lineLimit(1)
                if summary != tool.name { Text(summary).lineLimit(1).truncationMode(.middle) }
                if let directory = ToolPresentation.directory(tool) {
                    Text(directory).lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary).layoutPriority(-1)
                }
                Spacer(minLength: 0)
                if attention || tool.status == .running {
                    Text(statusLabel).font(.system(size: 11)).fixedSize()
                }
            }.font(.system(size: 12)).foregroundStyle(attention ? Color.orange : Color.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "\(tool.name) · \(summary) · \(statusLabel)"))
                .help(Text(verbatim: [ToolPresentation.path(tool), statusLabel].compactMap { $0 }.joined(separator: "\n")))
        }.disclosureGroupStyle(WorkbenchDisclosureStyle()).padding(.vertical, 1)
            .onChange(of: expanded) { _, value in if value { onExpand?() } }
    }
}
