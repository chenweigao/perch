import Combine
import Foundation
import GhosttyTerminal
import WorkbenchCore

@MainActor
final class AttachedTerminal: ObservableObject, Identifiable {
    let id: String
    let incarnation = UUID()
    let hostID: UUID
    let hostName: String
    let pane: Pane
    let context: TerminalViewState
    @Published var ended = false
    var onInput: (() -> Void)?

    init(id: String, pane: Pane, connection: HostConnection) {
        self.id = id
        self.pane = pane
        hostID = connection.id
        hostName = connection.host.name
        context = TerminalPalettes.makeViewState()
        context.configuration = TerminalSurfaceOptions(
            command: SSHCommand.attach(host: connection.host, binary: connection.binary,
                                       terminalID: pane.terminalID, controlPath: connection.controlPath),
            waitAfterCommand: true)
        context.makePlatformView = { [weak self] in
            let view = WorkbenchTerminalView(frame: .zero)
            view.onInput = { [weak self] in self?.onInput?() }
            return view
        }
        context.onClose = { [weak self] _ in self?.ended = true }
    }
}
