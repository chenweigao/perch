import SwiftUI
import WorkbenchCore

/// One status vocabulary for every list that shows sessions: archived, disconnected,
/// running, actionable, unread, and an ordinary session identified by its source. The
/// sidebar and the workbench queue share it, so the same session never reads as two
/// different states.
struct SessionStatusIndicator: View {
    let item: WorkspaceSession

    var body: some View {
        if item.archived {
            Image(systemName: "archivebox").font(.system(size: 10))
        } else if !item.online {
            Image(systemName: "wifi.slash").font(.system(size: 10))
        } else {
            switch item.section {
            case .running:
                ConversationBusyIndicator()
            case .attention:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .review:
                Circle().fill(.blue).frame(width: 6, height: 6)
            case .other:
                Image(systemName: item.reference.kind.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
