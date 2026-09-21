import Foundation

/// Group membership and the last session are independent of the list search.
public struct TaskGroupProjection {
    public let sessions: [WorkspaceSession]
    public let needsAttention: [WorkspaceSession]
    public let resume: WorkspaceSession?
    public let missingCount: Int
    public let totalCount: Int

    public init(group: WorkItemGroup, allSessions: [WorkspaceSession], lastSessionID: String?, search: String) {
        let members = SessionCatalog.scope(allSessions, starred: [], group: group, hostFilter: nil,
                                           search: "", onlyAttention: false, showArchived: false).sessions
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        totalCount = members.count
        resume = members.first { $0.id == lastSessionID }
        needsAttention = members.filter { $0.online && $0.section == .attention }
            + members.filter { $0.online && $0.section == .review }
        missingCount = group.sessions.filter { ref in !allSessions.contains { $0.reference == ref } }.count
        sessions = SessionCatalog.scope(members, starred: [], group: nil, hostFilter: nil,
                                        search: search.trimmingCharacters(in: .whitespacesAndNewlines),
                                        onlyAttention: false, showArchived: false).sessions
    }
}
