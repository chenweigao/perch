import Foundation
import WorkbenchCore

func checkUnifiedWorkbench() throws {
    let local = UUID(), remote = UUID()
    func session(_ id: String, host: UUID, section: WorkQueueSection, online: Bool = true, archived: Bool = false) -> WorkspaceSession {
        WorkspaceSession(reference: SessionReference(hostID: host, terminalID: id, kind: .codex), title: id,
                         directory: "/fixture", hostName: "fixture", detail: "fixture", online: online,
                         section: section, canMarkReviewed: section == .review, archived: archived, updatedAt: 10)
    }
    let approval = session("approval", host: local, section: .attention)
    let result = session("result", host: remote, section: .review)
    let stale = session("stale", host: remote, section: .attention, online: false)
    let archived = session("archived", host: remote, section: .attention, archived: true)
    let missing = SessionReference(hostID: remote, terminalID: "missing", kind: .codex)
    let catalog = [approval, result, stale, archived]
    var group = WorkItemGroup(name: "Goal", goal: "Ship", nextStep: "Review", sessions: catalog.map(\.reference) + [missing])
    group.criteria = [GroupCriterion(title: "Verified", completed: true)]
    group.outcomes = [GroupOutcome(title: "Report", link: "/home/user/report.md", source: result.reference)]
    let summary = TaskGroupSummary(group: group, sessions: catalog)
    precondition(summary.attentionCount == 1 && summary.reviewCount == 1 && summary.unsyncedCount == 2)
    precondition(summary.latestResult == result && summary.group.stage == .active)
    precondition(group.outcomes[0].webURL == nil)
    let remoteSummary = TaskGroupSummary(group: group, sessions: catalog, hostID: remote)
    precondition(remoteSummary.attentionCount == 0 && remoteSummary.reviewCount == 1 && remoteSummary.unsyncedCount == 2)
    let localSummary = TaskGroupSummary(group: group, sessions: catalog, hostID: local)
    precondition(localSummary.attentionCount == 1 && localSummary.unsyncedCount == 0)
    var second = WorkItemGroup(name: "Another goal", goal: "", nextStep: "", sessions: [approval.reference])
    second.lastOpenedAt = 20
    // A session in two goals is still one global action.
    let global = DashboardProjection(sessions: catalog, subjects: [:], hasConfiguredEnvironment: true)
    precondition(global.attention.items.count == 1)
    precondition(TaskGroupSummary.ordered(groups: [group, second], sessions: catalog).first?.id == second.id)
    group.isPinned = true
    precondition(TaskGroupSummary.shortcuts(groups: [group, second], sessions: catalog, selectedID: nil).map(\.id) == [group.id, second.id])
    var neverVisited = WorkItemGroup(name: "Selected", goal: "", nextStep: "", sessions: [])
    neverVisited.stage = .completed
    precondition(TaskGroupSummary.shortcuts(groups: [neverVisited], sessions: [], selectedID: neverVisited.id).count == 1)
    // Old workspaces migrate without altering goal identity, membership or manual stage.
    let encoded = try JSONEncoder().encode(group)
    var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    for key in ["criteria", "outcomes", "stage", "isPinned", "lastOpenedAt"] { object.removeValue(forKey: key) }
    let migrated = try JSONDecoder().decode(WorkItemGroup.self, from: JSONSerialization.data(withJSONObject: object))
    precondition(migrated.id == group.id && migrated.sessions == group.sessions)
    precondition(migrated.stage == .active && migrated.criteria.isEmpty && migrated.outcomes.isEmpty && !migrated.isPinned)
    let roundTrip = try JSONDecoder().decode(WorkItemGroup.self, from: encoded)
    precondition(roundTrip == group)
    group.stage = .completed
    precondition(TaskGroupSummary(group: group, sessions: catalog).group.stage == .completed)
    precondition(TaskGroupSummary(group: group, sessions: catalog).attentionCount == 1)
    print("PASS: unified workbench multi-host goals, non-duplicated actions, offline evidence, stable shortcuts, manual completion and legacy migration")
}
