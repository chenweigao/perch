import Foundation
import WorkbenchCore

func checkRestoreReport() throws {
    // Resolution order: missing > pending > busy > failed > completed > interrupted.
    precondition(RestoreResolution.outcome(SessionRestoreProbe(exists: false)) == .missing)
    precondition(RestoreResolution.outcome(SessionRestoreProbe(exists: true, archived: true)) == nil)
    precondition(RestoreResolution.outcome(SessionRestoreProbe(exists: true, busy: true, pendingInteraction: true)) == .attentionRequired)
    // A turn that started after the watched one makes an old failure irrelevant.
    precondition(RestoreResolution.outcome(SessionRestoreProbe(exists: true, busy: true, failed: true)) == .resumed)
    precondition(RestoreResolution.outcome(SessionRestoreProbe(exists: true, failed: true, completed: true)) == .failed)
    precondition(RestoreResolution.outcome(SessionRestoreProbe(exists: true, completed: true)) == .completedAway)
    // Not running and no completion signal: the watched work was cut short.
    precondition(RestoreResolution.outcome(SessionRestoreProbe(exists: true)) == .interrupted)

    precondition(RestoreOutcome.failed.needsAttention && RestoreOutcome.interrupted.needsAttention
                 && RestoreOutcome.attentionRequired.needsAttention && RestoreOutcome.missing.needsAttention)
    precondition(!RestoreOutcome.resumed.needsAttention && !RestoreOutcome.completedAway.needsAttention)

    // Baseline keys are parsed back into references; agent kinds round-trip,
    // terminals and malformed keys stay out of the report.
    let host = UUID()
    let kimi = SessionReference(hostID: host, terminalID: "k-1", kind: .kimi)
    precondition(SessionReference(restoreID: kimi.id) == kimi)
    let codex = SessionReference(hostID: host, terminalID: "c:2:with-colon", kind: .codex)
    precondition(SessionReference(restoreID: codex.id) == codex)
    let terminal = SessionReference(hostID: host, terminalID: "pane-1", kind: .terminal)
    precondition(SessionReference(restoreID: terminal.id) == nil)
    precondition(SessionReference(restoreID: "not-a-reference") == nil)
    precondition(SessionReference(restoreID: "\(UUID()):ghost:s-1") == nil)

    // The context carries the report beside the queue; defaults keep other
    // call sites unchanged.
    precondition(DashboardContext().restoreReport.isEmpty)
    let entry = RestoredSession(reference: kimi, title: "任务", hostName: "dev-env", outcome: .interrupted)
    let context = DashboardContext(restoreReport: [entry])
    precondition(context.restoreReport == [entry] && context.pendingRestoration.isEmpty)
}
