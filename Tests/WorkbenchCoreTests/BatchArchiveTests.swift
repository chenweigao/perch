import Foundation
import WorkbenchCore

func checkBatchArchive() throws {
    let hostA = UUID(), hostB = UUID()
    func reference(_ id: String, host: UUID = hostA, kind: SessionKind = .omp) -> SessionReference {
        SessionReference(hostID: host, terminalID: id, kind: kind)
    }
    func subject(_ id: String, host: UUID = hostA, kind: SessionKind = .omp, fingerprint: String = "r1",
                 archived: Bool = false, online: Bool = true, busy: Bool = false, pendingInteraction: Bool = false,
                 failed: Bool = false, stopped: Bool = false, starred: Bool = false, completedTurns: Int = 1,
                 reviewed: Bool = true, queuedMessages: Int = 0, hasCompletionSignal: Bool = true) -> ArchiveSubject {
        ArchiveSubject(reference: reference(id, host: host, kind: kind), fingerprint: fingerprint, archived: archived,
                       online: online, busy: busy, pendingInteraction: pendingInteraction, failed: failed,
                       stopped: stopped, starred: starred, completedTurns: completedTurns, reviewed: reviewed,
                       queuedMessages: queuedMessages, hasCompletionSignal: hasCompletionSignal)
    }

    // Idle is not completion. Every non-completed state names its own reason.
    precondition(subject("ready").isEligible)
    precondition(subject("running", busy: true).block == .running)
    precondition(subject("approval", pendingInteraction: true).block == .pendingInteraction)
    precondition(subject("broken", failed: true).block == .failed)
    precondition(subject("halted", stopped: true).block == .stopped)
    precondition(subject("kept", starred: true).block == .starred)
    precondition(subject("fresh", completedTurns: 0).block == .neverRan)
    precondition(subject("unread", reviewed: false).block == .unreviewed)
    precondition(subject("pending", queuedMessages: 2).block == .queued)
    precondition(subject("gone", online: false).block == .offline)
    precondition(subject("done", archived: true).block == .alreadyArchived)
    // A Herdr terminal reporting idle carries no turn-completion semantics.
    precondition(subject("shell", kind: .terminal, hasCompletionSignal: false).block == .noCompletionSignal)
    // Running outranks starred so the reason shown is the one that blocks soonest.
    precondition(subject("both", busy: true, starred: true).block == .running)

    let mixed = [subject("a"), subject("b", busy: true), subject("c", reviewed: false),
                 subject("d", host: hostB), subject("e", starred: true)]
    let plan = BatchArchivePlan(subjects: mixed, concurrencyLimit: 2)
    precondition(plan.count == 2)
    precondition(plan.blocked.count == 3)
    // Same terminal ID on two hosts stays two distinct candidates.
    let sameID = BatchArchivePlan(subjects: [subject("shared", host: hostA), subject("shared", host: hostB)])
    precondition(sameID.count == 2)
    precondition(Set(sameID.candidates.map(\.id)).count == 2)

    // Concurrency is bounded and a candidate is never started twice.
    var run = BatchArchiveRun(plan: plan)
    let first = run.nextBatch()
    precondition(first.count == 2)
    precondition(run.nextBatch().isEmpty)
    // A session that began running between planning and commit is skipped, not archived.
    let startedRunning = first[0]
    let live = ArchiveSubject(reference: startedRunning.reference, fingerprint: startedRunning.fingerprint, busy: true)
    precondition(run.revalidate(startedRunning, against: live) == .blocked(.running))
    run.skip(startedRunning, .blocked(.running))
    // A new revision means new output the user has not seen.
    let changed = first[1]
    let moved = ArchiveSubject(reference: changed.reference, fingerprint: "r2")
    precondition(run.revalidate(changed, against: moved) == .changed)
    // Disappearing between planning and commit is its own outcome.
    precondition(run.revalidate(changed, against: nil) == .disappeared)
    precondition(run.revalidate(changed, against: ArchiveSubject(reference: changed.reference, fingerprint: "r1")) == nil)
    run.fail(changed, "远端拒绝：会话正在运行")
    precondition(run.isFinished)
    precondition(run.archived.isEmpty && run.skipped.count == 1 && run.failures.count == 1)
    // Repeated completion callbacks for the same candidate must not double-count.
    run.succeed(changed); run.skip(changed, .disappeared)
    precondition(run.archived.isEmpty && run.skipped.count == 1)
    // Only failures are retried, and the retry keeps the original bound.
    let retry = run.retryPlan
    precondition(retry?.count == 1 && retry?.concurrencyLimit == 2)
    precondition(run.summary == "已归档 0 · 跳过 1 · 失败 1")

    // Undo restores exactly the set that was actually archived.
    var second = BatchArchiveRun(plan: BatchArchivePlan(subjects: [subject("x"), subject("y"), subject("z")], concurrencyLimit: 4))
    let all = second.nextBatch()
    precondition(all.count == 3)
    second.succeed(all[0]); second.succeed(all[2]); second.skip(all[1], .blocked(.running))
    precondition(second.undoTargets == [all[0].reference, all[2].reference])
    precondition(second.retryPlan == nil)
    precondition(second.summary == "已归档 2 · 跳过 1")

    // A retry belongs to the original batch, retaining earlier successes for undo.
    var cumulative = BatchArchiveRun(plan: BatchArchivePlan(subjects: [subject("a"), subject("b")]))
    let candidates = cumulative.nextBatch()
    cumulative.succeed(candidates[0]); cumulative.fail(candidates[1], "temporary failure")
    cumulative.retryFailures()
    precondition(cumulative.nextBatch() == [candidates[1]])
    cumulative.succeed(candidates[1])
    precondition(Set(cumulative.undoTargets) == Set(candidates.map(\.reference)))
    cumulative.beginUndo()
    cumulative.restored(candidates[0].reference)
    cumulative.undoFailed(candidates[1].reference, "restore unavailable")
    precondition(cumulative.undoTargets == [candidates[1].reference] && cumulative.undoFailures.count == 1)
    cumulative.beginUndo(); cumulative.restored(candidates[1].reference)
    precondition(cumulative.undoTargets.isEmpty && cumulative.restoredCount == 2)

    // Archiving a batch keeps history: only the archived flag moves in the workspace.
    var workspace = LocalWorkspace()
    let terminal = reference("productB-terminal", kind: .terminal)
    workspace.groups = [WorkItemGroup(name: "productB 批量", goal: "验证归档", nextStep: "复查", sessions: [terminal])]
    workspace.starred = [terminal]
    workspace.archivedTerminals.insert(terminal)
    precondition(workspace.groups[0].sessions == [terminal])
    workspace.archivedTerminals.remove(terminal)
    precondition(workspace.groups[0].sessions == [terminal] && workspace.starred == [terminal])
    print("PASS: completion semantics, batch planning, cross-host identity, revalidation, bounded concurrency, retry and undo sets")
}
