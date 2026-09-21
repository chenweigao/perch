import Foundation

public enum DashboardScope: Equatable, Sendable {
    case all, group(UUID)
}

public struct DashboardSection: Identifiable, Equatable, Sendable {
    public let section: WorkQueueSection
    public let items: [WorkspaceSession]
    public var id: String { section.rawValue }
    public var isEmpty: Bool { items.isEmpty }
}

/// What the workbench offers when there is nothing to act on. A first run needs
/// two starting paths, not an empty list that looks broken.
public enum DashboardEmptyState: Equatable, Sendable {
    case noEnvironment, noSessions, nothingPending

    public var title: String {
        switch self {
        case .noEnvironment: return "先选择一个执行环境"
        case .noSessions: return "选择 Agent 和工作目录后开始"
        case .nothingPending: return "当前范围内没有待处理或运行中的事项"
        }
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

    public init(sessions: [WorkspaceSession], subjects: [String: ArchiveSubject],
                hasEnvironment: Bool, concurrencyLimit: Int = 4) {
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

        if !hasEnvironment { emptyState = .noEnvironment }
        else if visible.isEmpty { emptyState = .noSessions }
        else if attention.isEmpty && running.isEmpty && review.isEmpty { emptyState = .nothingPending }
        else { emptyState = nil }
    }

    public var sections: [DashboardSection] { [attention, running, review].filter { !$0.isEmpty } }
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
