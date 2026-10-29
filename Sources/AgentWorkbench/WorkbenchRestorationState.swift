import Foundation
import Observation
import WorkbenchCore

@MainActor @Observable
final class WorkbenchRestorationState {
    /// The resolved outcomes of sessions that were mid-turn the last time each
    /// source was seen. Reported once per reconnect, dismissed explicitly.
    private(set) var restoreReport: [RestoredSession] = []
    /// Sources currently offline (or never connected this launch), keyed
    /// "kind:hostID". An armed source resolves its report on its first fresh
    /// catalog after reconnecting.
    @ObservationIgnored private var restoreArmed: Set<String> = []
    func dismissRestoreReport() { restoreReport = [] }
    /// Runs before the dashboardSeen baseline is updated below, so the comparison
    /// still sees the state the session had when the connection was lost.
    func resolveKimi(host: SSHHost, online: Bool, sessions: [KimiSession],
                     workspace: LocalWorkspace, allSessions: [WorkspaceSession]) {
        let key = "kimi:\(host.id)"
        guard online else { restoreArmed.insert(key); return }
        guard restoreArmed.remove(key) != nil else { return }
        collectKimiRestoreEntries(host: host, sessions: sessions, workspace: workspace, allSessions: allSessions)
    }
    func resolveNative(host: SSHHost, online: Bool, catalogSynced: Bool, sessions: [NativeAgentSession],
                       workspace: LocalWorkspace, allSessions: [WorkspaceSession]) {
        let key = "native:\(host.id)"
        guard online else { restoreArmed.insert(key); return }
        guard catalogSynced, restoreArmed.remove(key) != nil else { return }
        collectNativeRestoreEntries(host: host, sessions: sessions, workspace: workspace, allSessions: allSessions)
    }
    private func collectKimiRestoreEntries(host: SSHHost, sessions: [KimiSession], workspace: LocalWorkspace, allSessions: [WorkspaceSession]) {
        let hostID = host.id
        var entries: [RestoredSession] = []
        for (id, observation) in workspace.dashboardSeen {
            guard observation.state == "running", let reference = SessionReference(restoreID: id),
                  reference.hostID == hostID, reference.kind == .kimi else { continue }
            let session = sessions.first { $0.id == reference.terminalID }
            let probe = SessionRestoreProbe(exists: session != nil, archived: session?.archived == true,
                                            busy: session?.busy ?? false,
                                            pendingInteraction: ["approval", "question"].contains(session?.pendingInteraction ?? ""),
                                            failed: session?.lastTurnReason == "failed",
                                            completed: session?.lastTurnReason == "completed")
            guard let outcome = RestoreResolution.outcome(probe) else { continue }
            entries.append(RestoredSession(reference: reference, title: restoreTitle(reference, fallback: session?.title ?? "", workspace: workspace, allSessions: allSessions),
                                           hostName: host.name, outcome: outcome))
        }
        mergeRestoreEntries(entries)
    }
    private func collectNativeRestoreEntries(host: SSHHost, sessions: [NativeAgentSession], workspace: LocalWorkspace, allSessions: [WorkspaceSession]) {
        let hostID = host.id
        var entries: [RestoredSession] = []
        for (id, observation) in workspace.dashboardSeen {
            guard observation.state == "running", let reference = SessionReference(restoreID: id),
                  reference.hostID == hostID, reference.kind != .kimi else { continue }
            let session = sessions.first { $0.id == reference.terminalID && $0.provider == reference.kind }
            // Running baselines record "completed:pending:error" (see dashboardObservation),
            // so a completion is only claimed when the count provably advanced.
            let baselineCompleted = observation.revision.split(separator: ":").first.flatMap { Int($0) }
            let probe = SessionRestoreProbe(exists: session != nil, archived: session?.archived ?? false,
                                            busy: session?.busy ?? false,
                                            pendingInteraction: (session?.pending ?? 0) > 0,
                                            failed: session?.error != nil,
                                            completed: baselineCompleted.map { (session?.completed ?? 0) > $0 } ?? false)
            guard let outcome = RestoreResolution.outcome(probe) else { continue }
            entries.append(RestoredSession(reference: reference, title: restoreTitle(reference, fallback: session?.title ?? "", workspace: workspace, allSessions: allSessions),
                                           hostName: host.name, outcome: outcome))
        }
        mergeRestoreEntries(entries)
    }
    private func restoreTitle(_ reference: SessionReference, fallback: String, workspace: LocalWorkspace, allSessions: [WorkspaceSession]) -> String {
        let named = workspace.displayTitle(fallback, for: reference)
        return named.isEmpty ? (allSessions.first { $0.id == reference.id }?.title ?? reference.terminalID) : named
    }
    /// A session re-reported by a later reconnect replaces its earlier entry; the
    /// report describes the latest known outcome, not a history.
    private func mergeRestoreEntries(_ entries: [RestoredSession]) {
        guard !entries.isEmpty else { return }
        let ids = Set(entries.map(\.id))
        restoreReport.removeAll { ids.contains($0.id) }
        restoreReport.append(contentsOf: entries)
    }
}
