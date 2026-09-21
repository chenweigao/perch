import Foundation

/// Sidebar and dashboard scoping runs on the main thread for every list update,
/// including each search keystroke, so it is measured as shared code rather than
/// re-implemented inside a benchmark.
public struct SessionScope {
    public let sessions: [WorkspaceSession]
    public let favorites: [WorkspaceSession]
    public let recent: [WorkspaceSession]
}

public enum SessionCatalog {
    public static func scope(_ all: [WorkspaceSession], starred: [SessionReference],
                             group: WorkItemGroup?, hostFilter: UUID?, search: String,
                             onlyAttention: Bool, showArchived: Bool) -> SessionScope {
        let sessions = all.filter { item in
            item.archived == showArchived &&
            (group.map { $0.sessions.contains(item.reference) } ?? (hostFilter == nil || hostFilter == item.reference.hostID)) &&
            (search.isEmpty || "\(item.title) \(item.directory) \(item.detail) \(item.hostName)".localizedCaseInsensitiveContains(search)) &&
            // The inbox is only what needs a person right now. Unread results stay in
            // the workbench review section, which is also what the sidebar count means.
            (!onlyAttention || item.section == .attention)
        }
        let favorites = starred.compactMap { reference in sessions.first { $0.reference == reference } }
        let recent = sessions.filter { showArchived || !starred.contains($0.reference) }
        return SessionScope(sessions: sessions, favorites: favorites, recent: recent)
    }
}
