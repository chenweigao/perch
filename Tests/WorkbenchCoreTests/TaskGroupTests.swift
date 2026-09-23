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
    precondition(page.needsAttention.map(\.id) == [approval].map(\.id))
    precondition(page.resume == viewed)
    precondition(page.archivedCount == 1 && page.archived == [archived])
    precondition(page.totalCount + page.archivedCount + page.missingCount == group.sessions.count)
    precondition(Set(page.sessions.map(\.id)).isDisjoint(with: Set(page.archived.map(\.id))))

    // Search narrows the list (and its archive input), not the continuation or inbox.
    let searched = TaskGroupProjection(group: group, allSessions: all, lastSessionID: viewed.id, search: " UNREAD ")
    precondition(searched.sessions == [unread] && searched.totalCount == 4)
    precondition(searched.archived.isEmpty && searched.archivedCount == 1)
    let archiveSearch = TaskGroupProjection(group: group, allSessions: all, lastSessionID: viewed.id, search: " archived ")
    precondition(archiveSearch.sessions.isEmpty && archiveSearch.archived == [archived])
    precondition(searched.needsAttention == page.needsAttention && searched.resume == viewed)
    let noMatch = TaskGroupProjection(group: group, allSessions: all, lastSessionID: outside.id, search: "outside")
    precondition(noMatch.sessions.isEmpty && noMatch.resume == nil)
    let filed = TaskGroupProjection(group: group, allSessions: all, lastSessionID: archived.id, search: "")
    precondition(filed.resume == nil)
    // Sidebar and page totals follow archive/restore and membership changes,
    // never counting unrelated, archived, or not-yet-synced references as current.
    let restored = session("archived", .other, updated: 6)
    let afterRestore = TaskGroupProjection(group: group, allSessions: all.filter { $0.id != archived.id } + [restored],
                                           lastSessionID: nil, search: "")
    precondition(afterRestore.totalCount == 5 && afterRestore.archivedCount == 0 && afterRestore.missingCount == 1)
    var reducedGroup = group
    reducedGroup.sessions.removeAll { $0 == viewed.reference }
    let afterRemoval = TaskGroupProjection(group: reducedGroup, allSessions: all, lastSessionID: nil, search: "")
    precondition(afterRemoval.totalCount == 3 && afterRemoval.archivedCount == 1 && afterRemoval.missingCount == 1)
    let archivedGroup = WorkItemGroup(name: "Archived", goal: "", nextStep: "", sessions: [archived.reference])
    let archivedOnly = TaskGroupProjection(group: archivedGroup, allSessions: all, lastSessionID: nil, search: "")
    precondition(archivedOnly.totalCount == 0 && archivedOnly.archivedCount == 1)

    // A row names the groups it belongs to, in sidebar order, and only the first is
    // spelled out so the group badge does not take the title's width.
    let secondHost = UUID()
    let remote = WorkspaceSession(reference: SessionReference(hostID: secondHost, terminalID: "remote", kind: .kimi),
                                  title: "remote", directory: "/tmp/project", hostName: "remote-host", detail: "Kimi",
                                  online: true, section: .review, canMarkReviewed: true, updatedAt: 8)
    let spanning = WorkItemGroup(name: "Spanning", goal: "", nextStep: "",
                                 sessions: [unread.reference, remote.reference])
    let index = SessionGroupIndex(groups: [group, spanning])
    precondition(index[unread.id] == ["Group", "Spanning"])
    precondition(index[approval.id] == ["Group"])
    precondition(index[outside.id].isEmpty)
    precondition(SessionGroupIndex.label(index[unread.id]) == "Group +1")
    precondition(SessionGroupIndex.label(index[approval.id]) == "Group")
    precondition(SessionGroupIndex.label(index[outside.id]) == nil)
    // Membership is read from the saved references, so a badge survives a session that
    // has not reconnected and is not in the catalog yet.
    precondition(index[missing.id] == ["Group"])

    // A group spans machines, so the two facets narrow together instead of one
    // replacing the other, and neither may widen past the other.
    let catalog = all + [remote]
    let bothHosts = SessionCatalog.scope(catalog, starred: [], group: spanning, hostFilter: nil,
                                         search: "", onlyAttention: false, showArchived: false)
    precondition(bothHosts.sessions.map(\.id) == [unread.id, remote.id])
    let remoteOnly = SessionCatalog.scope(catalog, starred: [], group: spanning, hostFilter: secondHost,
                                          search: "", onlyAttention: false, showArchived: false)
    precondition(remoteOnly.sessions.map(\.id) == [remote.id])
    let localOnly = SessionCatalog.scope(catalog, starred: [], group: spanning, hostFilter: host,
                                         search: "", onlyAttention: false, showArchived: false)
    precondition(localOnly.sessions.map(\.id) == [unread.id])
    let unscoped = SessionCatalog.scope(catalog, starred: [], group: nil, hostFilter: nil,
                                        search: "", onlyAttention: false, showArchived: false)
    precondition(unscoped.sessions.count == catalog.count - 1)
    print("PASS: task group membership, recency, priority, search, resume, missing-session visibility, row group badges and combined group/machine scoping")
}
