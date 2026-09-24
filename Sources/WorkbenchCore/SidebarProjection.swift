import Foundation

/// Filters shared by local and remote conversations. Environment scope is selected separately.
public enum SidebarRecentFilter: String, CaseIterable {
    case all = "全部会话", running = "运行中"
}

/// Daily navigation is independent of the page, task group and archive scope.
public struct SidebarProjection {
    public let favorites: [WorkspaceSession]
    public let recent: [WorkspaceSession]
    public let totalRecentCount: Int
    public let attentionCount: Int

    public init(sessions: [WorkspaceSession], starred: [SessionReference], filter: SidebarRecentFilter = .all) {
        let active = sessions.filter { !$0.archived }
        let pins = Set(starred)
        favorites = starred.compactMap { ref in active.first { $0.reference == ref } }
        attentionCount = active.filter { $0.online && $0.section == .attention }.count
        let candidates = active.filter { item in
            !pins.contains(item.reference) &&
            (filter == .all || (filter == .running && item.section == .running))
        }
        totalRecentCount = candidates.count
        recent = Array(candidates.prefix(20))
    }
}
