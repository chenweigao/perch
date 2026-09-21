import Foundation
import WorkbenchCore

func checkTaskGroup() {
    let host = UUID()
    func session(_ id: String, _ section: WorkQueueSection, updated: Double,
                 online: Bool = true, archived: Bool = false) -> WorkspaceSession {
        WorkspaceSession(reference: SessionReference(hostID: host, terminalID: id, kind: .kimi),
                         title: id, directory: "/tmp/project", hostName: "local", detail: "Kimi",
                         online: online, section: section, canMarkReviewed: section == .review,
                         archived: archived, updatedAt: updated)
    }
    let approval = session("approval", .attention, updated: 2)
    let unread = session("unread", .review, updated: 3)
    let viewed = session("viewed", .other, updated: 4)
    let offline = session("offline", .attention, updated: 5, online: false)
    let archived = session("archived", .other, updated: 6, archived: true)
    let outside = session("outside", .attention, updated: 7)
    let missing = SessionReference(hostID: host, terminalID: "missing", kind: .kimi)
    let group = WorkItemGroup(name: "Group", goal: "", nextStep: "",
                             sessions: [approval, unread, viewed, offline, archived].map(\.reference) + [missing])
    let all = [approval, unread, viewed, offline, archived, outside]
    let page = TaskGroupProjection(group: group, allSessions: all, lastSessionID: viewed.id, search: "")
    // Reviewed and offline sessions remain visible, in recent-update order.
    precondition(page.sessions.map(\.id) == [offline, viewed, unread, approval].map(\.id))
    precondition(page.totalCount == 4 && page.missingCount == 1)
    precondition(page.needsAttention.map(\.id) == [approval, unread].map(\.id))
    precondition(page.resume == viewed)

    // Search narrows the list (and its archive input), not the continuation or inbox.
    let searched = TaskGroupProjection(group: group, allSessions: all, lastSessionID: viewed.id, search: " UNREAD ")
    precondition(searched.sessions == [unread] && searched.totalCount == 4)
    precondition(searched.needsAttention == page.needsAttention && searched.resume == viewed)
    let noMatch = TaskGroupProjection(group: group, allSessions: all, lastSessionID: outside.id, search: "outside")
    precondition(noMatch.sessions.isEmpty && noMatch.resume == nil)
    let filed = TaskGroupProjection(group: group, allSessions: all, lastSessionID: archived.id, search: "")
    precondition(filed.resume == nil)
    print("PASS: task group membership, recency, priority, search, resume and missing-session visibility")
}
