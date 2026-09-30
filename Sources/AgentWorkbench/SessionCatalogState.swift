import Observation
import WorkbenchCore

/// The catalog is a projection of provider state, never the owner of a connection.
/// Equal snapshots do not invalidate catalog consumers.
@MainActor @Observable
final class SessionCatalogState {
    private(set) var revision = 0
    private(set) var sessions: [WorkspaceSession] = []

    func replace(_ sessions: [WorkspaceSession]) {
        guard self.sessions != sessions else { return }
        self.sessions = sessions
        revision += 1
    }
}
