import SwiftUI
import WorkbenchCore

/// One subagent's transcript rows, shared by the Kimi and native sheets. The
/// rows are flat (`SubagentTranscriptRow`), so one long turn never becomes one
/// enormous lazy layout unit. Place it inside the sheet's scroll view.
struct SubagentTranscriptList: View {
    let rows: [SubagentTranscriptRow]
    /// Prefix of each row's expansion scope; unique per subagent. Tool cards and
    /// thoughts remember their state by key, so one shared scope would open
    /// them all together.
    let memoryScope: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                content(row).environment(\.conversationMemoryKey, memoryScope + ":" + row.id)
            }
        }.scrollTargetLayout()
    }

    @ViewBuilder private func content(_ row: SubagentTranscriptRow) -> some View {
        switch row.content {
        case .turn(let ordinal, let state):
            turnHeader(ordinal: ordinal, state: state).padding(.top, row.id == rows.first?.id ? 0 : 10)
        case .text(let text, let role):
            if role == "user" {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                KimiMarkdown(text: text).environment(\.isConversationBodyText, true)
            }
        case .thinking(let text):
            ThoughtDisclosure(text: text)
        case .tool(let tool):
            KimiToolCard(tool: tool)
        case .notice(let message, let level):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }.font(.system(size: 12))
                .foregroundStyle(level == "error" ? Color.orange : Color.secondary)
        case .error(let text):
            Text(text).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
        }
    }

    private func turnHeader(ordinal: Int?, state: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: turnSymbol(state))
                    .font(.system(size: 11))
                    .foregroundStyle(state == "failed" ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text("第 \(ordinal ?? 0) 轮").font(.system(size: 12, weight: .medium))
                if let state, state != "completed" {
                    Text(turnStateLabel(state)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }.accessibilityElement(children: .combine)
        }
    }

    private func turnSymbol(_ state: String?) -> String {
        switch state {
        case "running": return "circle.dotted"
        case "queued": return "clock"
        case "failed": return "exclamationmark.circle"
        case "cancelled": return "xmark.circle"
        default: return "checkmark"
        }
    }

    private func turnStateLabel(_ state: String) -> String {
        switch state {
        case "queued": return L("排队中")
        case "running": return L("运行中")
        case "failed": return L("失败")
        case "cancelled": return L("已取消")
        default: return state
        }
    }
}
