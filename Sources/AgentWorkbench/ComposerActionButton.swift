import SwiftUI

/// The primary action follows runtime state, never the contents of the draft.
/// A separate queue action preserves composing while the current turn runs.
struct ComposerActionButton: View {
    let isRunning: Bool
    let isStopping: Bool
    let canSend: Bool
    let canStop: Bool
    var queuedSendTitle = "Queue"
    let onSend: () -> Void
    let onStop: () -> Void

    private var enabled: Bool { !isStopping && (isRunning ? canStop : canSend) }
    private var title: String { isStopping ? "Stopping…" : isRunning ? "Stop task" : "Send" }
    var body: some View {
        HStack(spacing: 8) {
            if isRunning && canSend && !isStopping {
                Button(queuedSendTitle, action: onSend).buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityLabel(queuedSendTitle == "Queue" ? "Queue message" : queuedSendTitle)
            }
            Button {
                if isRunning { onStop() } else { onSend() }
            } label: {
                ZStack {
                    Circle().fill(enabled ? Color(red: 0.16, green: 0.16, blue: 0.17) : Color.gray.opacity(0.3))
                    if isStopping {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: isRunning ? 12 : 15, weight: .semibold)).foregroundStyle(.white)
                    }
                }.frame(width: 32, height: 32)
            }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title)
                .help(isRunning || isStopping ? title : "Return to send · Shift Return for a new line")
        }
    }
}

struct ComposerAddButton: View {
    var supportsFiles: Bool
    var disabled = false
    var onChoose: () -> Void = {}
    var body: some View {
        Button(action: onChoose) {
            Image(systemName: "plus").font(.system(size: 17)).frame(width: 23, height: 25)
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(disabled || !supportsFiles)
            .help(supportsFiles ? "Add images or files" : "Attachments are not supported by this agent connection")
            .accessibilityLabel(supportsFiles ? "Add images or files" : "Attachments unavailable")
    }
}
struct ComposerDeliveryHint: View {
    let running: Bool
    let sending: Bool
    let saveError: String?
    var body: some View {
        if let saveError { Text(saveError).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        else if sending { Text("Sending…").font(.system(size: 11)).foregroundStyle(.secondary) }
        else if running { Text("Working · New messages will be queued").font(.system(size: 11)).foregroundStyle(.tertiary) }
    }
}
