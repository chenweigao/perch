import Foundation

/// Filters shared by local and remote conversations. Environment scope is selected separately.
public enum SidebarRecentFilter: String, CaseIterable {
    case all = "全部会话", running = "运行中"
}

/// Navigation membership only. Moving a session here never changes its runtime cwd.
public struct SidebarProjectLocation: Codable, Equatable, Sendable, Identifiable {
    public let hostID: UUID
    public let directory: String
    public let hostName: String
    public var id: String { "\(hostID.uuidString):\(directory)" }
    public var name: String { directory == "/" ? "/" : (directory as NSString).lastPathComponent }

    public init(hostID: UUID, directory: String, hostName: String) {
        self.hostID = hostID
        // Do not resolve remote paths against the local filesystem or collapse symlinks.
        var path = directory
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        self.directory = path
        self.hostName = hostName
    }
}

public struct SidebarProject: Identifiable, Sendable {
    public let location: SidebarProjectLocation?
    public var sessions: [WorkspaceSession]
    public var disambiguate = false
    public var id: String { location?.id ?? "temporary" }
    public var title: String { location?.name ?? L("临时会话") }
    public var detail: String? {
        guard let location else { return nil }
        return "\(location.hostName) · \(location.directory)"
    }
}

/// Daily navigation is independent of the page, task group and archive scope.
public struct SidebarProjection {
    public let favorites: [WorkspaceSession]
    public let recent: [WorkspaceSession]
    public let ungrouped: [WorkspaceSession]
    public let totalRecentCount: Int
    public let attentionCount: Int
    public let projects: [SidebarProject]

    public init(sessions: [WorkspaceSession], starred: [SessionReference], filter: SidebarRecentFilter = .all,
                projectLocations: [String: SidebarProjectLocation] = [:]) {
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
                recent.append(item)
            }
        }
        favorites = starred.compactMap { pinned[$0] }
        self.recent = Array(recent.prefix(20))
        ungrouped = recent
        totalRecentCount = count
        attentionCount = attention

        // Use the full catalog: the old 20-row recent limit must not hide projects.
        var projectOrder: [String] = []
        var grouped: [String: SidebarProject] = [:]
        var seen = Set<String>()
        let hosts = Dictionary(sessions.map { ($0.reference.hostID, $0.hostName) }, uniquingKeysWith: { first, _ in first })
        for item in sessions where !item.archived && seen.insert(item.id).inserted {
            let source = projectLocations[item.id] ?? SidebarProjectLocation(hostID: item.reference.hostID,
                directory: item.directory, hostName: item.hostName)
            let location = source.directory.isEmpty ? nil : SidebarProjectLocation(hostID: source.hostID,
                directory: source.directory, hostName: hosts[source.hostID] ?? source.hostName)
            let id = location?.id ?? "temporary"
            if grouped[id] == nil {
                grouped[id] = SidebarProject(location: location, sessions: [])
                projectOrder.append(id)
            }
            if !pins.contains(item.reference) && (filter == .all || item.section == .running) {
                grouped[id]?.sessions.append(item)
            }
        }
        let names = Dictionary(projectOrder.map { (grouped[$0]!.title, 1) }, uniquingKeysWith: +)
        projects = projectOrder.compactMap { id -> SidebarProject? in
            guard var project = grouped[id] else { return nil }
            project.disambiguate = names[project.title, default: 0] > 1
            return project
        }.sorted {
            if ($0.location == nil) != ($1.location == nil) { return $0.location != nil }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
