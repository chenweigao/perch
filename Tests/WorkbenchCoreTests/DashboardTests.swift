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

    // Three priority sections: what needs a person comes before what needs patience.
    precondition(projection.sections.map(\.section) == [.attention, .review, .running])
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

    // The inbox narrows to what needs a person. Unread results stay in the workbench
    // review section, which is what the sidebar count already promises, and the
    // narrowing happens once so the dashboard cannot apply a second rule.
    let inbox = SessionCatalog.scope(sessions, starred: [], group: nil, hostFilter: nil, search: "",
                                    onlyAttention: true, showArchived: false)
    precondition(inbox.sessions.map(\.id) == [reference("approval").id])
    let inboxProjection = DashboardProjection(sessions: inbox.sessions, subjects: subjects, hasEnvironment: true)
    precondition(inboxProjection.sections.map(\.section) == [.attention])

    // The group loop and the restore list are part of the workbench, not only of the
    // editor sheet, and a local-storage failure is visible instead of just recorded.
    let group = WorkItemGroup(name: "productB 验收", goal: "端到端跑通", nextStep: "看审批",
                              sessions: [reference("approval"), reference("gone")])
    let context = DashboardContext(group: group, resume: sessions[0], missing: [reference("gone")],
                                   pendingRestoration: [SavedTerminal(session: reference("gone"), title: "已结束的会话")],
                                   storageError: "工作台保存失败")
    precondition(context.group?.nextStep == "看审批")
    precondition(context.missing == [reference("gone")] && context.resume?.id == sessions[0].id)
    precondition(context.pendingRestoration.map(\.title) == ["已结束的会话"])
    precondition(DashboardContext() == DashboardContext())
    precondition(DashboardContext(group: group) != context)

    // Queue rows carry how long something has waited. A source with no timestamp
    // reports nothing rather than a fabricated "just now", and a remote clock that
    // runs ahead of this Mac is not rendered as a negative wait.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    precondition(SessionTime.label(since: 0, waiting: true, now: now) == nil)
    precondition(SessionTime.label(since: now.timeIntervalSince1970 + 300, waiting: true, now: now) == "刚开始等待")
    precondition(SessionTime.label(since: now.timeIntervalSince1970 - 30, waiting: false, now: now) == "刚刚更新")
    precondition(SessionTime.label(since: now.timeIntervalSince1970 - 720, waiting: true, now: now) == "已等待 12 分钟")
    precondition(SessionTime.label(since: now.timeIntervalSince1970 - 720, waiting: false, now: now) == "12 分钟前")
    precondition(SessionTime.label(since: now.timeIntervalSince1970 - 7_200, waiting: false, now: now) == "2 小时前")
    precondition(SessionTime.label(since: now.timeIntervalSince1970 - 180_000, waiting: false, now: now) == "2 天前")
    print("PASS: dashboard priority sections, offline and archived scoping, explained archive count, metadata-only progress, first-run empty states, single inbox narrowing, group and restore context and queue row times")
}
