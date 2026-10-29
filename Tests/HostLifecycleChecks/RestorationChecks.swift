import Foundation
import WorkbenchCore

@MainActor func checkRestorationOwnership() throws {
    let state = WorkbenchRestorationState()
    let host = SSHHost(name: "Restoration fixture", destination: "fixture.invalid")
    let reference = SessionReference(hostID: host.id, terminalID: "shared", kind: .omp)
    let kimiReference = SessionReference(hostID: host.id, terminalID: "shared", kind: .kimi)
    var workspace = LocalWorkspace()
    workspace.dashboardSeen[reference.id] = DashboardObservation(state: "running", revision: "1:0:")
    workspace.dashboardSeen[kimiReference.id] = DashboardObservation(state: "running", revision: "old")
    workspace.rename(reference, title: "Local title")
    let completed = try JSONDecoder().decode(NativeAgentSession.self, from: Data(#"{"id":"shared","provider":"omp","title":"Remote title","cwd":"/fixture","busy":false,"archived":false,"updated":1,"completed":2,"pending":0,"model":"fixture"}"#.utf8))
    func native(online: Bool, synced: Bool, sessions: [NativeAgentSession]) {
        state.resolveNative(host: host, online: online, catalogSynced: synced, sessions: sessions,
                            workspace: workspace, allSessions: [])
    }
    native(online: false, synced: false, sessions: [])
    native(online: true, synced: false, sessions: [])
    precondition(state.restoreReport.isEmpty, "An unsynchronized catalog must not report sessions missing")
    native(online: true, synced: true, sessions: [completed])
    precondition(state.restoreReport == [RestoredSession(reference: reference, title: "Local title",
        hostName: host.name, outcome: .completedAway)],
        "Reconnect must compare against the running baseline and retain the local title")
    native(online: true, synced: true, sessions: [])
    precondition(state.restoreReport.first?.outcome == .completedAway,
                 "Ordinary catalog changes must not resolve a reconnect twice")
    state.dismissRestoreReport()
    native(online: true, synced: true, sessions: [completed])
    precondition(state.restoreReport.isEmpty, "Dismissed reports must stay dismissed until reconnect")
    native(online: false, synced: false, sessions: [])
    native(online: true, synced: true, sessions: [])
    precondition(state.restoreReport.first?.outcome == .missing)
    native(online: false, synced: false, sessions: [])
    native(online: true, synced: true, sessions: [completed])
    precondition(state.restoreReport.count == 1 && state.restoreReport.first?.outcome == .completedAway,
                 "A later reconnect must replace the earlier outcome for the same session")

    let waiting = try KimiWire.decoder().decode(KimiSession.self, from: Data(#"{"id":"shared","title":"Kimi title","updated_at":"now","busy":true,"pending_interaction":"approval","metadata":{},"agent_config":{}}"#.utf8))
    state.resolveKimi(host: host, online: false, sessions: [], workspace: workspace, allSessions: [])
    state.resolveKimi(host: host, online: true, sessions: [waiting], workspace: workspace, allSessions: [])
    precondition(state.restoreReport.count == 2
        && state.restoreReport.first { $0.id == kimiReference.id }?.outcome == .attentionRequired,
        "Kimi and native reconnects must stay independent even with the same host/session ID")

    let otherHost = SSHHost(name: "Other host", destination: "other.invalid")
    let otherReference = SessionReference(hostID: otherHost.id, terminalID: "shared", kind: .omp)
    workspace.dashboardSeen[otherReference.id] = DashboardObservation(state: "running", revision: "2:0:")
    state.resolveNative(host: otherHost, online: false, catalogSynced: false, sessions: [],
                        workspace: workspace, allSessions: [])
    state.resolveNative(host: otherHost, online: true, catalogSynced: true, sessions: [completed],
                        workspace: workspace, allSessions: [])
    precondition(state.restoreReport.count == 3
        && state.restoreReport.first { $0.id == otherReference.id }?.outcome == .interrupted,
        "Host baselines must stay independent; unchanged completion counts do not prove completion")
    print("PASS: reconnect catalog gating, baseline comparison, dismissal and host/provider isolation")
}
