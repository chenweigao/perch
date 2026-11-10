import SwiftUI
import WorkbenchCore

/// PI's primary action: a draft sends, an empty running composer stops.
struct ComposerActionButton: View {
    @UILocalization private var L
    let isRunning: Bool
    let isStopping: Bool
    let canSend: Bool
    let canStop: Bool
    var hasDraft = false
    /// False while disconnected or waiting for the user, even if the turn is open.
    var showsActivity = true
    /// A localization key ("Queue", "Steer", "Run command").
    var queuedSendTitle = "Queue"
    let onSend: () -> Void
    let onStop: () -> Void
    var onQueue: (() -> Void)? = nil

    private var showsStop: Bool { isRunning && !hasDraft }
    private var stopping: Bool { isRunning && isStopping }
    private var active: Bool { showsStop && canStop && showsActivity && !stopping }
    private var enabled: Bool { !stopping && (showsStop ? canStop : canSend) }
    private var title: String { stopping ? L("Stopping…") : showsStop ? L("Stop task") : L("Send") }
    /// The hint does what Return does; its tooltip names that key and ⌘Return.
    private var queuedSendHelp: String {
        switch queuedSendTitle {
        case "Steer": return onQueue == nil ? L("回车引导当前轮") : L("回车引导当前轮 · ⌘回车排到下一轮")
        case "Run command": return L("回车执行命令")
        default: return L("回车排到下一轮发送")
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            if isRunning && hasDraft && canSend && !stopping {
                if let onQueue {
                    // ⌘↩ is text, not a key equivalent: the composer already handles
                    // ⌘Return, and a pop-up button can fire its items' equivalents
                    // while closed, even when focus is elsewhere or mid-composition.
                    // The chevron keeps its size; it sits in the toolbar layout's send slot.
                    Menu {
                        Button(L("Send next turn") + "  ⌘↩", action: onQueue)
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize().help("Send next turn")
                        .accessibilityLabel(L("Send next turn"))
                }
            }
            Button {
                if showsStop { onStop() } else { onSend() }
            } label: {
                ZStack {
                    Circle().fill(showsStop ? WorkbenchTheme.ink.opacity(0.16)
                                  : enabled ? WorkbenchTheme.accent : WorkbenchTheme.ink.opacity(0.10))
                    Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                        .font(.system(size: showsStop ? 14 : 15, weight: .semibold))
                        .foregroundStyle(showsStop ? WorkbenchTheme.ink
                                         : enabled ? WorkbenchTheme.actionGlyph : WorkbenchTheme.quiet)
                        .opacity(showsStop && !enabled ? 0.5 : 1)
                }.frame(width: 28, height: 28)
            }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title)
                .accessibilityValue(active ? L("Working…") : "")
                .accessibilityIdentifier("composer-primary-action")
                .help(isRunning && hasDraft ? queuedSendHelp : showsStop || stopping ? title : L("Return to send · Shift Return for a new line"))
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
            Image(systemName: "plus").font(.system(size: 15)).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(disabled || !supportsFiles)
            .help(supportsFiles ? L("Add images or files") : L("Attachments are not supported by this agent connection"))
            .accessibilityLabel(supportsFiles ? L("Add images or files") : L("Attachments unavailable"))
    }
}
/// Environment details belong to the composer, without retargeting a running session.
struct ComposerEnvironmentMenu: View {
    let host: SSHHost
    let provider: String
    let directory: String

    var body: some View {
        Menu {
            Text(host.name)
            Text(provider)
            if !directory.isEmpty { Divider(); Text(directory) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: host.isLocal ? "desktopcomputer" : "server.rack")
                Text(host.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 88)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }.font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary).frame(height: 32)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("机器").accessibilityValue(host.name)
            .help(directory.isEmpty ? host.name : host.name + "\n" + directory)
    }
}

struct ComposerDeliveryHint: View {
    let sending: Bool
    let saveError: String?
    /// Character count of a long draft, so a wall of text is visible at a glance.
    var draftLength: Int = 0
    var body: some View {
        if let saveError { Text(saveError).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.orange).textSelection(.enabled) }
        else if sending { Text("Sending…").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary) }
        else if draftLength >= 200 {
            Text("草稿 \(draftLength) 字").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.tertiary)
        }
    }
}
