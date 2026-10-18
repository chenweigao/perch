import SwiftUI
import WorkbenchCore

/// One subagent's own transcript: its turns, steps and frames, read over REST and
/// kept current by the operations its subscription streams. Read-only — a child
/// belongs to the turn that started it, which the conversation's Stop covers.
struct KimiSubagentTranscriptSheet: View {
    let agentId: String
    let subject: KimiTask
    let connection: KimiConnection
    @Environment(\.dismiss) private var dismiss
    @State private var visibleRow: String?

    private var transcript: KimiSubagentTranscript? {
        guard let value = connection.subagentTranscript, value.agentId == agentId else { return nil }
        return value
    }

    /// Header, transcript and footer run edge to edge between dividers; the dialog
    /// padding is their shared horizontal inset.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(.horizontal, WorkbenchTheme.Dialog.padding).padding(.vertical, 16) }
                .scrollPosition(id: $visibleRow)
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
        }.padding(.horizontal, WorkbenchTheme.Dialog.padding).padding(.vertical, 16)
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
            // The turn/step hierarchy is flattened before building lazy children:
            // one long turn must not become one enormous layout unit.
            SubagentTranscriptList(rows: SubagentTranscriptRow.rows(from: transcript),
                                   memoryScope: "subagent:\(agentId)")
        } else if connection.loadingSubagentTranscript {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
        if let error = connection.subagentTranscriptError {
            Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                .padding(.top, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("子 Agent 在远端继续运行；关闭这里不会停止它。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button("重新读取") { Task { await connection.openSubagentTranscript(agentId) } }
                .disabled(!connection.online || connection.loadingSubagentTranscript)
        }.padding(.horizontal, WorkbenchTheme.Dialog.padding).padding(.vertical, 10)
    }
}
