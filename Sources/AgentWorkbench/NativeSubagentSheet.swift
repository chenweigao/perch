import SwiftUI
import WorkbenchCore

/// One native subagent's own transcript (bridge protocol 7), followed while the
/// sheet is open: the latest window, then deltas, with older pages on demand.
/// Closing it, switching sessions or disconnecting only ends the reads; the
/// subagent keeps running on the remote host.
struct NativeSubagentSheet: View {
    let subject: NativeSubagentSubject
    let connection: NativeAgentConnection
    @Environment(\.dismiss) private var dismiss
    @State private var visibleRow: String?
    @UILocalization private var L

    private var state: NativeSubagentState { connection.subagents }
    /// The transcript of this sheet, never another subject's.
    private var transcript: NativeSubagentTranscript? {
        guard state.presented == subject, let value = state.transcript, value.key == subject.key else { return nil }
        return value
    }

    var body: some View {
        let entry = connection.subagentEntry(for: subject)
        let live = entry?.status.isLive == true
        let rows = transcript.map {
            SubagentTranscriptRow.rows(from: $0.messages, isRunning: live, online: connection.online)
        } ?? []
        VStack(alignment: .leading, spacing: 0) {
            header(entry.map(KimiTask.init(native:)))
            Divider()
            ScrollView {
                content(rows).padding(.horizontal, WorkbenchTheme.Dialog.padding).padding(.vertical, 16)
            }
                .scrollPosition(id: $visibleRow)
                // A transcript reads toward its latest message.
                .defaultScrollAnchor(.bottom)
            Divider()
            footer(live: live, status: entry.map { KimiTask(native: $0).phaseLabel })
        }.frame(width: 640, height: 600)
            .task(id: subject) { await connection.followSubagent(subject) }
            #if PERCH_ACCEPTANCE
            .background(NativeSubagentSheetProbe(rows: rows.map(\.id)))
            #endif
    }

    private func header(_ task: KimiTask?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("子 Agent 过程", systemImage: "person.2").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(task?.description ?? subject.key).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
            Text(meta(task)).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }.padding(.horizontal, WorkbenchTheme.Dialog.padding).padding(.vertical, 16)
    }

    /// Type, phase, usage and the key, as far as they are known.
    private func meta(_ task: KimiTask?) -> String {
        var parts: [String] = []
        if let task {
            if let type = task.subagentType { parts.append(type) }
            parts.append(task.phaseLabel)
            if let tokens = task.tokenCount { parts.append(L("已用 \(tokens) Token")) }
            if let calls = task.toolUseCount { parts.append(L("\(calls) 次调用")) }
        }
        parts.append(subject.key)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func content(_ rows: [SubagentTranscriptRow]) -> some View {
        if !connection.online {
            Text("连接已断开，以下为最后读取的内容。").font(.system(size: 12)).foregroundStyle(.orange)
                .padding(.bottom, 10)
        }
        if let transcript {
            if transcript.hasOlder {
                Button {
                    connection.loadOlderSubagent()
                } label: {
                    if state.loadingOlder { Text("正在加载更早消息…") } else { Text("加载更早消息") }
                }.disabled(state.loadingOlder || !connection.online)
                    .frame(maxWidth: .infinity).padding(.bottom, 12)
            }
            if rows.isEmpty && !state.loading {
                Text("这个子 Agent 还没有可见的过程。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            SubagentTranscriptList(rows: rows,
                                   memoryScope: "native-subagent:\(connection.host.id.uuidString):\(subject.sessionID):\(subject.key)")
        }
        if state.loading && rows.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
        if let error = state.error {
            Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                .padding(.top, 10)
        }
    }

    private func footer(live: Bool, status: String?) -> some View {
        HStack(spacing: 12) {
            if live || status == nil {
                Text("子 Agent 在远端继续运行；关闭这里不会停止它。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else if let status {
                Text(status).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
        }.padding(.horizontal, WorkbenchTheme.Dialog.padding).padding(.vertical, 10)
    }
}
