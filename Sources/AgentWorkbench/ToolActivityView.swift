import SwiftUI
import WorkbenchCore

/// Active/attention rows stay in one ForEach as history arrives. Only completed
/// rows depend on the execution disclosure; public text lives in separate entries.
struct KimiActivityView: View {
    @State private var expanded = false
    let entry: ConversationTimelineEntry
    let tools: [String: VisibleTool]
    let api: KimiAPI?
    let sessionId: String
    var body: some View {
        let items = entry.messages.flatMap(\.content).compactMap { tools[$0.toolCallId ?? ""] }
        let completed = items.filter { !$0.staysVisible }.count
        let context = entry.messages.filter { $0.content.contains(where: \.isRuntimeContext) }
        VStack(alignment: .leading, spacing: 4) {
            if completed > 0 || !context.isEmpty {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                        Text(completed == 0 ? "运行上下文" : "执行过程 · \(completed) 项已返回")
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityValue(expanded ? "已展开" : "已收起")
            }
            ForEach(items) { tool in
                if tool.staysVisible || expanded { KimiToolCard(tool: tool) }
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
    @State private var expanded = false
    private var summary: String {
        tool.input?["description"].string ?? tool.input?["command"].string
            ?? tool.input?["file_path"].string ?? tool.input?["path"].string ?? tool.name
    }
    private var label: String {
        switch tool.status {
        case .running: return "执行中"
        case .succeeded: return "已完成"
        case .returned: return "已返回"
        case .failed: return "失败"
        case .missingResult: return "结果未收到"
        case .disconnected: return "连接中断 · 状态未知"
        case .awaitingApproval: return "待确认"
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
                    if let input = tool.input { Text("参数").foregroundStyle(.secondary); SelectableReplyText(input.display) }
                    if let progress = tool.progress { Text("执行进度").foregroundStyle(.secondary); SelectableReplyText(progress.display) }
                    if let output = tool.output { Text("返回结果").foregroundStyle(.secondary); SelectableReplyText(output.display) }
                    if tool.input == nil && tool.output == nil && tool.progress == nil { Text("暂无参数或返回内容").foregroundStyle(.secondary) }
                }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10).padding(.top, 7)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(summary).lineLimit(1).truncationMode(.middle)
                if summary != tool.name { Text(tool.name).font(.system(size: 10)).foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
                Text(tool.hasCall ? label : "\(label) · 调用记录缺失").font(.system(size: 10))
            }.font(.system(size: 12)).foregroundStyle(attention ? Color.orange : Color.secondary)
        }.padding(.vertical, 5)
    }
}
