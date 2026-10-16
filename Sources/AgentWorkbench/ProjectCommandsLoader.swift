import Foundation
import WorkbenchCore

/// Project slash command loading lives outside KimiConnection.swift: that file is
/// symlinked into the ConnectionChecks target, which has no RemoteReader.
extension KimiConnection {
    func loadProjectCommands(for id: String) {
        guard projectCommands[id] == nil, !projectCommandsLoading.contains(id),
              let cwd = conversation?.snapshot.session.cwd, !cwd.isEmpty else { return }
        projectCommandsLoading.insert(id)
        let command = ProjectCommandCatalog.script(cwd: cwd)
        let reader = RemoteReader(local: host.isLocal)
        let destination = host.destination
        Task {
            let result = await reader.run(command: command, destination: destination)
            guard case .success(let data) = result else {
                projectCommandsLoading.remove(id)
                return
            }
            setProjectCommands(ProjectCommandCatalog.parse(data), for: id)
        }
    }
}
