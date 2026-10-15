import SwiftUI
import WorkbenchCore

/// The primary action follows runtime state, never the contents of the draft.
/// A separate queue action preserves composing while the current turn runs.
struct ComposerActionButton: View {
    @UILocalization private var L
    let isRunning: Bool
    let isStopping: Bool
    let canSend: Bool
    let canStop: Bool
    /// A localization key ("Queue", "Steer", "Run command").
    var queuedSendTitle = "Queue"
    let onSend: () -> Void
    let onStop: () -> Void
    var onQueue: (() -> Void)? = nil

    private var enabled: Bool { !isStopping && (isRunning ? canStop : canSend) }
    private var title: String { isStopping ? L("Stopping…") : isRunning ? L("Stop task") : L("Send") }
    var body: some View {
        HStack(spacing: 8) {
            if isRunning && canSend && !isStopping {
                Button(L(key: queuedSendTitle), action: onSend).buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityLabel(queuedSendTitle == "Queue" ? L("Queue message") : L(key: queuedSendTitle))
                if let onQueue {
                    Menu {
                        Button("Send next turn", action: onQueue)
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize().help("Send next turn")
                }
            }
            Button {
                if isRunning { onStop() } else { onSend() }
            } label: {
                ZStack {
                    Circle().fill(enabled ? WorkbenchTheme.accent : Color.gray.opacity(0.3))
                    if isStopping {
                        ProgressView().controlSize(.mini).tint(WorkbenchTheme.actionGlyph)
                    } else {
                        Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: isRunning ? 12 : 15, weight: .semibold)).foregroundStyle(WorkbenchTheme.actionGlyph)
                    }
                }.frame(width: 32, height: 32)
            }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title)
                .help(isRunning || isStopping ? title : L("Return to send · Shift Return for a new line"))
        }
    }
}

struct ComposerAddButton: View {
    @UILocalization private var L
    var supportsFiles: Bool
    var disabled = false
    var onChoose: () -> Void = {}
    var body: some View {
        Button(action: onChoose) {
            Image(systemName: "plus").font(.system(size: 17)).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(disabled || !supportsFiles)
            .help(supportsFiles ? L("Add images or files") : L("Attachments are not supported by this agent connection"))
            .accessibilityLabel(supportsFiles ? L("Add images or files") : L("Attachments unavailable"))
    }
}
struct ComposerDeliveryHint: View {
    let sending: Bool
    let saveError: String?
    /// Character count of a long draft, so a wall of text is visible at a glance.
    var draftLength: Int = 0
    var body: some View {
        if let saveError { Text(saveError).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        else if sending { Text("Sending…").font(.system(size: 11)).foregroundStyle(.secondary) }
        else if draftLength >= 200 {
            Text("草稿 \(draftLength) 字").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}
