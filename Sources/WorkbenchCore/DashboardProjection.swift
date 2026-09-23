import Foundation

/// Which sessions the workbench queue is allowed to show, by identity.
///
/// The facets are independent and narrow together: a group can span machines, so
/// picking one must not decide the other. This is the filter the model holds;
/// `ActiveScope` is the same state spelled out in names for the screen.
public struct DashboardScope: Equatable, Sendable {
    public var groupID: UUID?
    public var hostID: UUID?

    public init(groupID: UUID? = nil, hostID: UUID? = nil) {
        self.groupID = groupID; self.hostID = hostID
    }
}

public struct DashboardSection: Identifiable, Equatable, Sendable {
    public let section: WorkQueueSection
    public let items: [WorkspaceSession]
    public var id: String { section.rawValue }
    public var isEmpty: Bool { items.isEmpty }
}

/// What the workbench offers when there is nothing to act on. A first run needs a
/// way to set up an environment, not an empty list that looks broken.
public enum DashboardEmptyState: Equatable, Sendable {
    case noEnvironment, noSessions, nothingPending, noMatches

    public var title: String {
        switch self {
        case .noEnvironment: return "先连接一台运行 Agent 的机器"
        case .noSessions: return "选择 Agent 和工作目录后开始"
        case .nothingPending: return "当前范围内没有待处理或运行中的事项"
        case .noMatches: return "当前筛选下没有会话"
        }
    }
}

/// The facets currently narrowing the queue, named as the user named them.
///
/// A filter that is not on screen reads as missing sessions, so the queue carries
/// its own scope beside the rows it explains. Clearing is per facet: a group filter
/// and a machine filter answer different questions and one is often still wanted.
public struct ActiveScope: Equatable, Sendable {
    public struct Facet: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case group, host }
        public let kind: Kind
        public let name: String
        public var symbol: String { kind == .group ? "folder" : "server.rack" }
    }

    public let facets: [Facet]
    public var isEmpty: Bool { facets.isEmpty }

    public init(groupName: String? = nil, hostName: String? = nil) {
        facets = [groupName.map { Facet(kind: .group, name: $0) },
                  hostName.map { Facet(kind: .host, name: $0) }].compactMap { $0 }
    }
}

/// What the workbench shows above the queue: saved references that could not be
/// reattached, and a local-storage failure. These states explain the queue, so they
/// travel beside the projection rather than being read from the live model by the view.
/// The task group's own page presents the group, its next step and what to resume.
public struct DashboardContext: Equatable, Sendable {
    public let pendingRestoration: [SavedTerminal]
    public let storageError: String?
    public let scope: ActiveScope

    public init(pendingRestoration: [SavedTerminal] = [], storageError: String? = nil,
                scope: ActiveScope = ActiveScope()) {
        self.pendingRestoration = pendingRestoration; self.storageError = storageError; self.scope = scope
    }
}

/// The workbench is an action surface, so this projection carries only the three
/// priority sections plus the batch plan. Summaries reuse each session's existing
/// detail text; nothing here asks a model to describe a session.
public struct DashboardProjection: Equatable, Sendable {
    public let attention: DashboardSection
    public let running: DashboardSection
    public let review: DashboardSection
    public let other: [WorkspaceSession]
    public let offline: [WorkspaceSession]
    public let archivePlan: BatchArchivePlan
    public let blocked: [ArchiveBlock: Int]
    public let emptyState: DashboardEmptyState?

    /// `hasConfiguredEnvironment` asks whether the user has ever set up a machine, not
    /// whether one is reachable right now. The app keeps a built-in connection so the
    /// terminal surface always has one, so counting connections would hide the first run,
    /// and counting online connections would show it during every reconnect.
    /// `filtered` says the caller narrowed the sessions before handing them over.
    /// Without it an empty queue would advise setting up an agent or starting a
    /// session when the only thing wrong is the active filter.
    public init(sessions: [WorkspaceSession], subjects: [String: ArchiveSubject],
                hasConfiguredEnvironment: Bool, concurrencyLimit: Int = 4, filtered: Bool = false) {
        let visible = sessions.filter { !$0.archived }
        let live = visible.filter(\.online)
        attention = DashboardSection(section: .attention, items: live.filter { $0.section == .attention })
        running = DashboardSection(section: .running, items: live.filter { $0.section == .running })
        review = DashboardSection(section: .review, items: live.filter { $0.section == .review })
        other = live.filter { $0.section == .other }
        offline = visible.filter { !$0.online }

        // Only sessions still in scope may be archived, so a batch can never act on
        // something the current filter hides.
        let scoped = visible.compactMap { subjects[$0.id] }
        archivePlan = BatchArchivePlan(subjects: scoped, concurrencyLimit: concurrencyLimit)
        blocked = archivePlan.blocked.reduce(into: [:]) { counts, item in counts[item.block, default: 0] += 1 }

        // An empty list means one of three different things, and setup advice belongs only
        // to the first two: nothing has been set up yet, nothing has been started, or a
        // filter is hiding everything. Sessions already listed are proof enough that an
        // environment works, and a filter is the caller's own doing.
        if visible.isEmpty {
            emptyState = filtered ? .noMatches : (hasConfiguredEnvironment ? .noSessions : .noEnvironment)
        }
        else if attention.isEmpty && running.isEmpty && review.isEmpty { emptyState = .nothingPending }
        else { emptyState = nil }
    }

    /// Handle first, then look at results, and only then watch what is still running:
    /// the two sections that need a person come before the one that needs patience.
    public var sections: [DashboardSection] { [attention, review, running].filter { !$0.isEmpty } }
    /// Recent rows never repeat an active priority section. Unknown timestamps stay
    /// behind dated sessions; stable identity breaks ties without invented activity.
    public var recent: [WorkspaceSession] {
        Array(other.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }.prefix(6))
    }
    public var archiveCount: Int { archivePlan.count }
    public var archiveActionTitle: String { "归档已完成 \(archiveCount)" }

    /// Explains what the batch will leave behind, so the count is not mistaken for
    /// "everything finished".
    public var blockedSummary: String? {
        guard !blocked.isEmpty else { return nil }
        let parts = blocked.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .map { "\($0.key.reason) \($0.value)" }
        return "不会归档：" + parts.joined(separator: " · ")
    }
}
