import Foundation

/// Goal state belongs to the person; live activity is only evidence about sessions.
public struct TaskGroupSummary: Identifiable, Equatable, Sendable {
    public let group: WorkItemGroup
    public let attentionCount: Int
    public let reviewCount: Int
    public let runningCount: Int
    public let unsyncedCount: Int
    public let latestResult: WorkspaceSession?
    public var id: UUID { group.id }

    public init(group: WorkItemGroup, sessions: [WorkspaceSession], hostID: UUID? = nil) {
        self.group = group
        let references = Set(group.sessions.filter { hostID == nil || $0.hostID == hostID })
        let members = sessions.filter { references.contains($0.reference) }
        let live = members.filter { $0.online && !$0.archived }
        attentionCount = live.filter { $0.section == .attention }.count
        reviewCount = live.filter { $0.section == .review }.count
        runningCount = live.filter { $0.section == .running }.count
        unsyncedCount = references.subtracting(Set(members.map(\.reference))).count
            + members.filter { !$0.online && !$0.archived }.count
        latestResult = live.filter { $0.section == .review }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }.first
    }

    /// Stable while agents stream: navigation recency, not session ticks, orders goals.
    public static func ordered(groups: [WorkItemGroup], sessions: [WorkspaceSession], hostID: UUID? = nil) -> [Self] {
        summarize(groups: orderedGroups(groups), sessions: sessions, hostID: hostID)
    }

    private static func orderedGroups(_ groups: [WorkItemGroup]) -> [WorkItemGroup] {
        groups.enumerated().sorted { lhs, rhs in
            if lhs.element.isPinned != rhs.element.isPinned { return lhs.element.isPinned }
            if lhs.element.lastOpenedAt != rhs.element.lastOpenedAt { return lhs.element.lastOpenedAt > rhs.element.lastOpenedAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// One catalog pass shared by all groups, then visit only their members.
    /// Grouping keeps duplicate catalog entries' existing counting semantics.
    private static func summarize(groups: [WorkItemGroup], sessions: [WorkspaceSession], hostID: UUID? = nil) -> [Self] {
        guard !groups.isEmpty else { return [] }
        let index = Dictionary(grouping: sessions, by: \.reference)
        return groups.map { group in
            let members = Set(group.sessions).flatMap { index[$0] ?? [] }
            return Self(group: group, sessions: members, hostID: hostID)
        }
    }

    public static func shortcuts(groups: [WorkItemGroup], sessions: [WorkspaceSession], selectedID: UUID?) -> [Self] {
        let ordered = orderedGroups(groups)
        let pinned = ordered.filter(\.isPinned)
        let recent = ordered.filter { !$0.isPinned && ($0.lastOpenedAt > 0 || $0.id == selectedID) }
        var visible = pinned + recent.prefix(5)
        if let selected = ordered.first(where: { $0.id == selectedID }), !visible.contains(where: { $0.id == selectedID }) {
            visible.append(selected)
        }
        return summarize(groups: visible, sessions: sessions)
    }
}
