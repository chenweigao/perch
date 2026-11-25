import Foundation

/// The one value that names the page on screen. Back/forward history stores it;
/// the sidebar selection and the persisted destination are read from the same
/// state. See docs/design/layout.md「导航与恢复」.
///
/// The workbench's Overview / Projects / Task Groups switch and the new-session
/// draft are not routes: the switch is a view within the workbench page, and the
/// draft is a transient sheet over whichever page is current.
public enum WorkbenchRoute: Hashable, Sendable {
    /// The workbench, optionally scoped to one task group.
    case home(group: UUID?)
    /// Requests that need a person, optionally scoped to one task group.
    case inbox(group: UUID?)
    case allSessions
    case archive
    /// One conversation or terminal, by its stable session identity.
    case session(String)

    public var sessionID: String? {
        if case .session(let id) = self { return id }
        return nil
    }

    /// The task group this page is scoped to, if any.
    public var groupID: UUID? {
        switch self {
        case .home(let group), .inbox(let group): return group
        case .allSessions, .archive, .session: return nil
        }
    }
}
