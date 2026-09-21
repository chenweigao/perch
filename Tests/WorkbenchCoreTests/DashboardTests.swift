import Foundation
import WorkbenchCore

func checkDashboard() throws {
    let host = UUID()
    func reference(_ id: String, kind: SessionKind = .omp) -> SessionReference {
        SessionReference(hostID: host, terminalID: id, kind: kind)
    }
    func session(_ id: String, section: WorkQueueSection, online: Bool = true, archived: Bool = false,
                 kind: SessionKind = .omp) -> WorkspaceSession {
        WorkspaceSession(reference: reference(id, kind: kind), title: "productB-\(id)", directory: "/tmp/productB",
                         hostName: "本机", detail: "OMP · \(section.rawValue)", online: online,
                         section: section, canMarkReviewed: section == .review, archived: archived)
    }
    func subject(_ id: String, kind: SessionKind = .omp, busy: Bool = false, reviewed: Bool = true,
                 pendingInteraction: Bool = false, starred: Bool = false,
                 hasCompletionSignal: Bool = true) -> (String, ArchiveSubject) {
        let value = ArchiveSubject(reference: reference(id, kind: kind), fingerprint: "r1", busy: busy,
                                   pendingInteraction: pendingInteraction, starred: starred,
                                   reviewed: reviewed, hasCompletionSignal: hasCompletionSignal)
        return (value.reference.id, value)
    }

    let sessions = [
        session("approval", section: .attention), session("streaming", section: .running),
        session("unread", section: .review), session("done", section: .other),
        session("shell", section: .other, kind: .terminal),
        session("lost", section: .other, online: false),
        session("filed", section: .other, archived: true),
    ]
    let subjects = Dictionary(uniqueKeysWithValues: [
        subject("approval", pendingInteraction: true), subject("streaming", busy: true),
        subject("unread", reviewed: false), subject("done"),
        subject("shell", kind: .terminal, hasCompletionSignal: false),
        subject("filed"),
    ])
    let projection = DashboardProjection(sessions: sessions, subjects: subjects, hasEnvironment: true)

    // Three priority sections, in the order the workbench presents them.
    precondition(projection.sections.map(\.section) == [.attention, .running, .review])
    precondition(projection.attention.items.map(\.id) == [reference("approval").id])
    precondition(projection.running.items.map(\.id) == [reference("streaming").id])
    precondition(projection.review.items.map(\.id) == [reference("unread").id])
    // Offline sessions are kept apart so they do not inflate the actionable counts.
    precondition(projection.offline.map(\.id) == [reference("lost").id])
    precondition(!projection.other.contains { !$0.online })
    // Archived sessions are out of scope entirely, including for the batch.
    precondition(!projection.other.contains { $0.archived })
    precondition(!projection.archivePlan.candidates.contains { $0.reference == reference("filed") })

    // Only the genuinely finished, reviewed session is a candidate.
    precondition(projection.archiveCount == 1)
    precondition(projection.archivePlan.candidates.map(\.reference) == [reference("done")])
    precondition(projection.archiveActionTitle == "归档已完成 1")
    // The count is explained, so it is not read as "everything is finished".
    guard let summary = projection.blockedSummary else { fatalError("blocked reasons must be shown") }
    precondition(summary.contains("正在运行") && summary.contains("结果还没查看") && summary.contains("没有完成语义"))
    precondition(projection.blocked[.running] == 1 && projection.blocked[.noCompletionSignal] == 1)
    // A shell reporting idle is never silently swept into the batch.
    precondition(!projection.archivePlan.candidates.contains { $0.reference.kind == .terminal })

    // Progress comes from existing metadata only; no percentage is invented.
    precondition(projection.running.items.allSatisfy { !$0.detail.contains("%") })

    // Empty states offer a path forward rather than a blank list.
    let firstRun = DashboardProjection(sessions: [], subjects: [:], hasEnvironment: false)
    precondition(firstRun.emptyState == .noEnvironment)
    precondition(firstRun.archiveCount == 0 && firstRun.blockedSummary == nil)
    let connected = DashboardProjection(sessions: [], subjects: [:], hasEnvironment: true)
    precondition(connected.emptyState == .noSessions)
    let quiet = DashboardProjection(sessions: [session("done", section: .other)],
                                    subjects: Dictionary(uniqueKeysWithValues: [subject("done")]),
                                    hasEnvironment: true)
    precondition(quiet.emptyState == .nothingPending)
    precondition(quiet.sections.isEmpty && quiet.archiveCount == 1)
    // A dashboard with work to do has no empty state.
    precondition(projection.emptyState == nil)

    // The batch keeps the caller's concurrency bound.
    let bounded = DashboardProjection(sessions: sessions, subjects: subjects, hasEnvironment: true, concurrencyLimit: 2)
    precondition(bounded.archivePlan.concurrencyLimit == 2)
    print("PASS: dashboard priority sections, offline and archived scoping, explained archive count, metadata-only progress and first-run empty states")
}
