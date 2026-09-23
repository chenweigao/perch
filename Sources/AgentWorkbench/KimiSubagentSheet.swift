import SwiftUI
import WorkbenchCore

/// One subagent's own transcript: its turns, steps and frames, read over REST and
/// kept current by the operations its subscription streams. Read-only — a child
/// belongs to the turn that started it, which the conversation's Stop covers.
struct KimiSubagentTranscriptSheet: View {
    let agentId: String
    let subject: KimiTask
    @ObservedObject var connection: KimiConnection
    @Environment(\.dismiss) private var dismiss

    private var transcript: KimiSubagentTranscript? {
        guard let value = connection.subagentTranscript, value.agentId == agentId else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(16) }
            Divider()
            footer
        }.frame(width: 640, height: 600)
            .task(id: agentId) { await connection.openSubagentTranscript(agentId) }
            .onDisappear { connection.closeSubagentTranscript() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("子 Agent 过程", systemImage: "person.2").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(subject.description).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
            Text([subject.subagentType, subject.model, subject.phaseLabel, agentId]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }.padding(16)
    }

    @ViewBuilder private var content: some View {
        if !connection.online {
            Text("连接已断开，以下为最后读取的内容。").font(.system(size: 12)).foregroundStyle(.orange)
                .padding(.bottom, 10)
        }
        if let transcript {
            if transcript.hasMoreOlder {
                Button {
                    Task { await connection.loadOlderSubagentTurns() }
                } label: {
                    if connection.loadingOlderSubagentTurns { Text("正在加载更早轮次…") }
                    else { Text("加载更早轮次") }
                }.disabled(connection.loadingOlderSubagentTurns || !connection.online)
                    .frame(maxWidth: .infinity).padding(.bottom, 12)
            }
            if transcript.turns.isEmpty && !connection.loadingSubagentTranscript {
                Text("这个子 Agent 还没有可见的轮次。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(transcript.turns) { turn in turnView(turn) }
            }
        } else if connection.loadingSubagentTranscript {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
        if let error = connection.subagentTranscriptError {
            Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                .padding(.top, 10)
        }
    }

    private func turnView(_ turn: KimiTranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: turnSymbol(turn.state))
                    .font(.system(size: 11))
                    .foregroundStyle(turn.state == "failed" ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text("第 \(turn.ordinal ?? 0) 轮").font(.system(size: 12, weight: .medium))
                if let state = turn.state, state != "completed" {
                    Text(turnStateLabel(state)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }.accessibilityElement(children: .combine)
            ForEach(turn.steps ?? []) { step in
                ForEach(step.frames ?? []) { frame in frameView(frame) }
            }
            if let error = turn.error, !error.isEmpty {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    /// Each frame needs its own expansion scope: tool cards and thoughts remember
    /// their state by key, so one shared scope would open them all together.
    private func frameView(_ frame: KimiTranscriptFrame) -> some View {
        frameContent(frame)
            .environment(\.conversationMemoryKey, "subagent:\(agentId):\(frame.frameId)")
    }

    @ViewBuilder private func frameContent(_ frame: KimiTranscriptFrame) -> some View {
        switch frame.kind {
        case "tool":
            if let tool = frame.tool { KimiToolCard(tool: tool) }
        case "thinking":
            if let text = frame.text, !text.isEmpty { ThoughtDisclosure(text: text) }
        case "notice":
            if let message = frame.message, !message.isEmpty {
                Label {
                    Text(message).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }.font(.system(size: 12))
                    .foregroundStyle(frame.level == "error" ? Color.orange : Color.secondary)
            }
        default:
            if let text = frame.text, !text.isEmpty {
                if frame.role == "user" {
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    KimiMarkdown(text: text).environment(\.isConversationBodyText, true)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("子 Agent 在远端继续运行；关闭这里不会停止它。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button("重新读取") { Task { await connection.openSubagentTranscript(agentId) } }
                .disabled(!connection.online || connection.loadingSubagentTranscript)
        }.padding(.horizontal, 16).padding(.vertical, 10)
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
