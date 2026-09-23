import Foundation

/// Which task groups a session belongs to, keyed by session id.
///
/// A list surface asks this once per row, and the catalog changes several times a
/// second while an agent streams, so the index is built once per view pass from the
/// saved groups rather than walking every group inside every row.
public struct SessionGroupIndex: Equatable, Sendable {
    public let names: [String: [String]]

    /// Names follow the sidebar's group order, so two rows in the same groups read
    /// the same way.
    public init(groups: [WorkItemGroup]) {
        var index: [String: [String]] = [:]
        for group in groups {
            for reference in group.sessions { index[reference.id, default: []].append(group.name) }
        }
        names = index
    }

    public subscript(sessionID: String) -> [String] { names[sessionID] ?? [] }

    /// A row has one line of secondary text and it is shared with the agent, the
    /// machine and the directory, so only the first group is spelled out. Collapsing
    /// the rest into a count keeps membership visible without pushing the title out.
    public static func label(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }
}
