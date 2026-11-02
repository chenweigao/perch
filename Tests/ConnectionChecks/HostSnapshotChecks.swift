import Combine
import Foundation
import WorkbenchCore

@MainActor
func checkHostSnapshotChanges() throws {
    func snapshot(title: String = "Shell", revision: Int = 1, status: String = "idle",
                  cwd: String = "/fixture", tabLabel: String = "Terminal",
                  workspaceLabel: String = "Project", includePane: Bool = true) throws -> Snapshot {
        let pane: [String: Any] = ["pane_id": "p", "terminal_id": "t", "workspace_id": "w",
                                 "tab_id": "tab", "cwd": cwd, "title": title,
                                 "revision": revision, "agent_status": status]
        let object: [String: Any] = ["version": "1", "workspaces": [["workspace_id": "w", "label": workspaceLabel]],
                                    "tabs": [["tab_id": "tab", "workspace_id": "w", "label": tabLabel]],
                                    "panes": includePane ? [pane] : [], "agents": []]
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let host = HostConnection(host: SSHHost(name: "Fixture", destination: "fixture"))
    var callbacks = 0
    var publications = 0
    host.onSnapshot = { callbacks += 1 }
    let observation = host.$snapshot.dropFirst().sink { _ in publications += 1 }
    defer { observation.cancel() }
    let initial = try snapshot()
    host.applySnapshot(initial)
    let firstRefresh = host.updatedAt
    for _ in 0..<20 { host.applySnapshot(try snapshot()) }
    precondition(callbacks == 1 && publications == 1, "Identical decoded snapshots must not rebuild the catalog")
    precondition(host.online && host.updatedAt! >= firstRefresh!, "Successful idle polls still update freshness")
    let changes = try [snapshot(title: "Renamed"), snapshot(revision: 2), snapshot(status: "done"),
                       snapshot(cwd: "/other"), snapshot(tabLabel: "New tab"),
                       snapshot(workspaceLabel: "New workspace"), snapshot(includePane: false)]
    for change in changes {
        let before = callbacks
        host.applySnapshot(change)
        precondition(callbacks == before + 1 && host.snapshot == change)
    }
    host.disconnect()
    let before = callbacks
    host.applySnapshot(changes.last!)
    precondition(host.online && callbacks == before + 1, "Reconnect must notify even when its snapshot is unchanged")
    print("PASS: Herdr idle snapshots skip 20 redundant catalog callbacks; metadata, removal and reconnect still publish")
}
