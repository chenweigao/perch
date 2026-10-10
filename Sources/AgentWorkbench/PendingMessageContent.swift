import SwiftUI
import WorkbenchCore

/// Pending text stays in the transcript at full length until the runtime echoes it.
struct PendingMessageContent: View {
    let text: String
    let status: String
    var mode: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let mode { Text(L(key: mode)) }
                Text(L(key: status)).textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Editing a not-yet-accepted queue entry; save failure keeps the typed revision.
struct PendingMessageEditor: View {
    let message: OutboundMessage
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var messageError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑待发消息").font(.headline)
            TextEditor(text: $text).frame(minHeight: 140)
            if let messageError { Text(messageError).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    if save(text) { dismiss() }
                    else { messageError = "消息已经提交，修改未保存。可复制这里的文字作为新的补充。" }
                }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 460).onAppear { text = message.text }
    }
}
