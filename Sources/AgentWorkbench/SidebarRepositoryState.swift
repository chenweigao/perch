import Foundation
import Observation
import WorkbenchCore

struct SidebarRepositoryRequest: Equatable {
    let host: SSHHost
    let directories: [String]
    var sessions: [SidebarRepositorySession] = []
}

struct SidebarRepositorySession: Equatable {
    let reference: SessionReference
    let directory: String
    let revision: Double
}

struct SidebarRepositoryLoad: Equatable {
    let requests: [SidebarRepositoryRequest]
    let retry: Int
}

/// Catalog metadata, independent of navigation membership and execution cwd.
/// Read each distinct directory once per host configuration, never per row.
@MainActor @Observable
final class SidebarRepositoryState {
    private(set) var revision = 0
    private(set) var retryRevision = 0
    private(set) var isResolving = false
    private(set) var failed = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var roots: [String: [String: SidebarRepositoryMatch]] = [:]
    @ObservationIgnored private var checked: [String: Set<String>] = [:]
    @ObservationIgnored private var evidenceChecked: [String: (hostKey: String, session: SidebarRepositorySession)] = [:]
    @ObservationIgnored private var assignments: [String: (hostKey: String, directory: String, project: String)] = [:]
    @ObservationIgnored var read: (SSHHost, [String]) async -> Result<Data, Error> = { host, directories in
        let reader = RemoteReader(local: host.isLocal)
        return await withTaskCancellationHandler {
            await reader.run(command: SidebarRepositoryCommand.command(directories: directories), destination: host.destination)
        } onCancel: { reader.terminate() }
    }

    func retry() {
        generation += 1
        checked.removeAll()
        evidenceChecked.removeAll()
        retryRevision += 1
        isResolving = false
        failed = false
    }

    private func key(_ host: SSHHost) -> String { host.id.uuidString + ":" + host.destination }

    #if PERCH_ACCEPTANCE
    func acceptanceReplace(host: SSHHost, roots: [String: String]) {
        self.roots[key(host)] = roots.mapValues { SidebarRepositoryMatch(directory: $0, isRepository: true) }
        revision += 1
    }
    #endif

    func location(for item: WorkspaceSession, host: SSHHost?) -> SidebarProjectLocation {
        let assignment = assignments[item.id]
        let directory = assignment?.directory == item.directory && assignment?.hostKey == host.map(key) ? assignment!.project
            : host.flatMap { roots[key($0)]?[item.directory]?.directory } ?? item.directory
        return SidebarProjectLocation(hostID: item.reference.hostID, directory: directory, hostName: item.hostName)
    }

    func resolve(_ requests: [SidebarRepositoryRequest],
                 evidence: (SessionReference) async throws -> [KimiMessage] = { _ in [] }) async {
        generation += 1
        let token = generation
        isResolving = true
        failed = false
        defer { if generation == token { isResolving = false } }
        for request in requests {
            let hostKey = key(request.host)
            let missing = request.directories.filter { checked[hostKey]?.contains($0) != true }
            for start in stride(from: 0, to: missing.count, by: 64) {
                guard !Task.isCancelled else { return }
                let directories = Array(missing[start..<min(start + 64, missing.count)])
                let result = await read(request.host, directories)
                guard !Task.isCancelled, generation == token else { return }
                guard case .success(let data) = result,
                      let resolved = try? SidebarRepositoryCommand.parseMatches(data, directories: directories) else {
                    failed = true
                    break
                }
                roots[hostKey, default: [:]].merge(resolved) { _, new in new }
                checked[hostKey, default: []].formUnion(resolved.keys)
                revision += 1
            }
            for session in request.sessions {
                guard !Task.isCancelled, generation == token else { return }
                guard roots[hostKey]?[session.directory]?.isRepository == false,
                      evidenceChecked[session.reference.id]?.session != session
                        || evidenceChecked[session.reference.id]?.hostKey != hostKey else { continue }
                do {
                    let messages = try await evidence(session.reference)
                    guard !Task.isCancelled, generation == token else { return }
                    let hints = SidebarProjectEvidence.directories(messages: messages, cwd: session.directory)
                    let missingHints = Array(Set(hints.filter { checked[hostKey]?.contains($0) != true })).sorted()
                    if !missingHints.isEmpty {
                        let result = await read(request.host, missingHints)
                        guard !Task.isCancelled, generation == token else { return }
                        let data = try result.get()
                        let resolved = try SidebarRepositoryCommand.parseMatches(data, directories: missingHints)
                        roots[hostKey, default: [:]].merge(resolved) { _, new in new }
                        checked[hostKey, default: []].formUnion(resolved.keys)
                    }
                    if let project = SidebarProjectEvidence.project(directories: hints, matches: roots[hostKey] ?? [:]) {
                        assignments[session.reference.id] = (hostKey, session.directory, project)
                    }
                    evidenceChecked[session.reference.id] = (hostKey, session)
                    revision += 1
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    failed = true
                }
            }
        }
    }
}
