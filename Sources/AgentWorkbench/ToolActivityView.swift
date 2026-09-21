import SwiftUI
import WorkbenchCore

/// Every tool keeps a visible summary in source order; only its payload folds.
struct KimiActivityView: View {
    @Environment(\.conversationMemoryKey) private var memoryKey
    @RememberedExpansion("expanded") private var expanded
    let entry: ConversationTimelineEntry
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    var body: some View {
        let items = entry.messages.flatMap(\.content).compactMap { tools[$0.toolCallId ?? ""] }
        let context = entry.messages.filter { $0.content.contains(where: \.isRuntimeContext) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { tool in
                KimiToolCard(tool: tool).environment(\.conversationMemoryKey, memoryKey + ":tool:" + tool.id)
            }
            if !context.isEmpty {
                Button { expanded.toggle() } label: {
                    Label("Runtime context", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed")
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
    @RememberedExpansion("expanded") private var expanded
    private var summary: String {
        tool.input?["description"].string ?? tool.input?["command"].string
            ?? tool.input?["file_path"].string ?? tool.input?["path"].string ?? tool.name
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
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let input = tool.input { Text("Input").foregroundStyle(.secondary); SelectableReplyText(input.display) }
                    if let progress = tool.progress { Text("Progress").foregroundStyle(.secondary); SelectableReplyText(progress.display) }
                    if let output = tool.output { Text("Output").foregroundStyle(.secondary); SelectableReplyText(output.display) }
                    if tool.input == nil && tool.output == nil && tool.progress == nil { Text("暂无Input或返回内容").foregroundStyle(.secondary) }
                }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10).padding(.top, 7)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(tool.name).lineLimit(1)
                if summary != tool.name { Text(summary).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Text(tool.hasCall ? label : "\(label) · Call record missing").font(.system(size: 10))
            }.font(.system(size: 12)).foregroundStyle(attention ? Color.orange : Color.secondary)
        }.padding(.vertical, 5)
    }
}
