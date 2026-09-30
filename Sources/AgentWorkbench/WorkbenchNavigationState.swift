import Foundation
import Observation
import WorkbenchCore

/// UI destination and filters. Remote execution outlives this navigation state.
@MainActor @Observable
final class WorkbenchNavigationState {
    var tabs: TerminalTabs = TerminalTabs()
    var showDashboard: Bool = true
    var showAllTaskGroups: Bool = false
    var selectedGroupID: UUID?
    var scopeHostID: UUID?
    var showArchived: Bool = false
    var showSessionDirectory: Bool = false
    var search: String = ""
    var onlyAttention: Bool = false
    var navigation: SessionNavigation = SessionNavigation()
}
