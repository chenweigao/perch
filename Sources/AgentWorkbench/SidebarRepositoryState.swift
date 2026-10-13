import Foundation
import Observation
import WorkbenchCore

struct SidebarRepositoryRequest: Equatable {
    let host: SSHHost
    let directories: [String]
}

/// Catalog metadata, independent of navigation membership and execution cwd.
/// Read each distinct directory once per host configuration, never per row.
@MainActor @Observable
final class SidebarRepositoryState {
    private(set) var revision = 0
    @ObservationIgnored private var roots: [String: [String: String]] = [:]

    private func key(_ host: SSHHost) -> String { host.id.uuidString + ":" + host.destination }

    #if PERCH_ACCEPTANCE
    func acceptanceReplace(host: SSHHost, roots: [String: String]) {
        self.roots[key(host)] = roots
        revision += 1
    }
    #endif

    func location(for item: WorkspaceSession, host: SSHHost?) -> SidebarProjectLocation {
        let directory = host.flatMap { roots[key($0)]?[item.directory] } ?? ""
        return SidebarProjectLocation(hostID: item.reference.hostID, directory: directory, hostName: item.hostName)
    }

    func resolve(_ requests: [SidebarRepositoryRequest]) async {
        for request in requests {
            let hostKey = key(request.host)
            let missing = request.directories.filter { roots[hostKey]?[$0] == nil }
            for start in stride(from: 0, to: missing.count, by: 64) {
                guard !Task.isCancelled else { return }
                let directories = Array(missing[start..<min(start + 64, missing.count)])
                let reader = RemoteReader(local: request.host.isLocal)
                let result = await withTaskCancellationHandler {
                    await reader.run(command: SidebarRepositoryCommand.command(directories: directories),
                                     destination: request.host.destination)
                } onCancel: { reader.terminate() }
                guard !Task.isCancelled else { return }
                guard case .success(let data) = result,
                      let resolved = try? SidebarRepositoryCommand.parse(data, directories: directories) else { break }
                roots[hostKey, default: [:]].merge(resolved) { _, new in new }
                revision += 1
            }
        }
    }
}
