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
        let pins = Set(starred)
        var pinned: [SessionReference: WorkspaceSession] = [:]
        var recent: [WorkspaceSession] = []
        var count = 0, attention = 0
        for item in sessions where !item.archived {
            if item.online && item.section == .attention { attention += 1 }
            if pins.contains(item.reference) {
                if pinned[item.reference] == nil { pinned[item.reference] = item }
            } else if filter == .all || item.section == .running {
                count += 1
                if recent.count < 20 { recent.append(item) }
            }
        }
        favorites = starred.compactMap { pinned[$0] }
        self.recent = recent
        totalRecentCount = count
        attentionCount = attention
    }
}
