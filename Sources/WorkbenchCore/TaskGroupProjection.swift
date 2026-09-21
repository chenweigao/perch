import Foundation

/// Group membership and the last session are independent of the list search.
public struct TaskGroupProjection {
    public let sessions: [WorkspaceSession]
    public let needsAttention: [WorkspaceSession]
    public let archived: [WorkspaceSession]
    public let archivedCount: Int
    public let resume: WorkspaceSession?
    public let missingCount: Int
    public let totalCount: Int

    public init(group: WorkItemGroup, allSessions: [WorkspaceSession], lastSessionID: String?, search: String) {
        let members = SessionCatalog.scope(allSessions, starred: [], group: group, hostFilter: nil,
                                           search: "", onlyAttention: false, showArchived: false).sessions
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        let filed = SessionCatalog.scope(allSessions, starred: [], group: group, hostFilter: nil,
                                         search: "", onlyAttention: false, showArchived: true).sessions
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        archivedCount = filed.count
        archived = SessionCatalog.scope(filed, starred: [], group: nil, hostFilter: nil,
                                        search: search.trimmingCharacters(in: .whitespacesAndNewlines),
                                        onlyAttention: false, showArchived: true).sessions
        totalCount = members.count
        resume = members.first { $0.id == lastSessionID }
        needsAttention = members.filter { $0.online && $0.section == .attention }

        missingCount = group.sessions.filter { ref in !allSessions.contains { $0.reference == ref } }.count
        sessions = SessionCatalog.scope(members, starred: [], group: nil, hostFilter: nil,
                                        search: search.trimmingCharacters(in: .whitespacesAndNewlines),
                                        onlyAttention: false, showArchived: false).sessions
    }
}
