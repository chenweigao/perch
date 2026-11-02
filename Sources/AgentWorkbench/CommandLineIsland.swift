import GhosttyTerminal
import SwiftUI
import WorkbenchCore

/// The quick command line floating over the bottom of the reader. The shell is
/// throwaway: it is not a Herdr pane, it ends when the island closes, and it is
/// never silently killed on selection changes — retargeting is an explicit
/// button in the header.
@MainActor
@Observable
final class CommandLineIslandState {
    struct Target: Equatable {
        let hostID: UUID
        let hostName: String
        let directory: String
    }

    private(set) var visible = false
    private(set) var ended = false
    private(set) var target: Target?
    /// The live surface. Swapping it ends the old shell; identity guards keep a
    /// late `onClose` from marking a fresh surface as ended.
    private(set) var context: TerminalViewState?

    func toggle(target: Target, connection: HostConnection) {
        visible ? hide() : show(target: target, connection: connection)
    }

    /// Opens the island on the target. An existing live shell keeps running even
    /// when it belongs to another session; the header then offers explicit
    /// retargeting. With no live shell the incoming target is adopted outright.
    func show(target: Target, connection: HostConnection) {
        if context == nil {
            self.target = target
            ended = false
            if connection.host.isLocal || connection.online { spawn(connection: connection) }
        }
        visible = true
    }

    func hide() { visible = false }

    /// Ends the shell and releases the island.
    func close() {
        context = nil; target = nil; ended = false; visible = false
    }

    /// Ends the current shell and opens a fresh one on the new target.
    func retarget(target: Target, connection: HostConnection) {
        self.target = target; ended = false
        context = connection.host.isLocal || connection.online ? makeContext(target: target, connection: connection) : nil
        visible = true
    }

    /// Reopens the shell on the same target after it exited.
    func restart(connection: HostConnection) {
        guard let target else { return }
        ended = false
        context = connection.host.isLocal || connection.online ? makeContext(target: target, connection: connection) : nil
        visible = true
    }

    private func spawn(connection: HostConnection) {
        guard let target else { return }
        context = makeContext(target: target, connection: connection)
        ended = false
    }

    private func makeContext(target: Target, connection: HostConnection) -> TerminalViewState {
        let context = TerminalPalettes.makeViewState()
        if connection.host.isLocal {
            context.configuration = TerminalSurfaceOptions(
                workingDirectory: target.directory.isEmpty ? nil : target.directory)
        } else {
            // No waitAfterCommand: an exited throwaway shell closes the surface
            // and surfaces the ended state with a reopen button.
            context.configuration = TerminalSurfaceOptions(
                command: SSHCommand.shell(host: connection.host, directory: target.directory,
                                          controlPath: connection.controlPath))
        }
        context.makePlatformView = { WorkbenchTerminalView(frame: .zero) }
        // Weak context: the state owns the surface, the callback must not keep it alive.
        context.onClose = { [weak self, weak context] _ in
            guard let self, let context, self.context === context else { return }
            self.ended = true
        }
        return context
    }
}

struct CommandLineIslandView: View {
    let state: CommandLineIslandState
    /// Connection of the island's own target, not necessarily the selected session's.
    let connection: HostConnection?
    /// The selected session's target, so the header can offer retargeting.
    let currentTarget: CommandLineIslandState.Target?
    let onRetarget: () -> Void
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let connection {
                CommandLineIslandConnectionView(state: state, connection: connection, onRestart: onRestart)
            } else {
                Text("该会话所属机器不可用。").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .workbenchFloatingSurface()
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.panel, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("命令行").font(.system(size: 12, weight: .medium))
            if let target = state.target {
                Text("\(target.hostName) · \(target.directory.isEmpty ? "~" : target.directory)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let currentTarget, currentTarget != state.target {
                Button { onRetarget() } label: {
                    Text("在当前会话目录重开").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(WorkbenchTheme.accent)
                .help("结束这里的 Shell，在当前会话的目录重新打开").accessibilityLabel("在当前会话目录重开")
            }
            Button { state.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("关闭命令行").accessibilityLabel("关闭命令行")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// Observes the target host's connection so the offline prompt flips to a live
/// surface once connecting finishes.
private struct CommandLineIslandConnectionView: View {
    let state: CommandLineIslandState
    @ObservedObject var connection: HostConnection
    let onRestart: () -> Void

    var body: some View {
        content
            .onChange(of: connection.online) { _, online in
                guard online, state.visible, state.context == nil, let target = state.target else { return }
                state.show(target: target, connection: connection)
            }
    }

    @ViewBuilder private var content: some View {
        if let context = state.context {
            VStack(spacing: 0) {
                TerminalSurfaceView(context: context)
                    .id(ObjectIdentifier(context))
                if state.ended {
                    HStack {
                        Text("命令行已结束；可重新打开一个。").font(.system(size: 12))
                        Spacer()
                        Button("重新打开") { onRestart() }
                    }.padding(14).background(Color.primary.opacity(0.035))
                }
            }
        } else if !connection.host.isLocal {
            VStack(spacing: 10) {
                Text("连接「\(connection.host.name)」后可在其目录中使用命令行。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("连接") { connection.connect() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // A local shell spawns eagerly; reaching here means the surface is
            // still being set up.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
