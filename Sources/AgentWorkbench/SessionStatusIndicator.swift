import SwiftUI
import WorkbenchCore

/// Provider identity stays visible in every state; the small badge adds status.
struct SidebarAgentIndicator: View {
    let item: WorkspaceSession

    var body: some View {
        AgentMark(kind: item.reference.kind, size: 13)
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if !item.online {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    } else if item.section == .attention {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    } else if item.section == .review {
                        Circle().fill(.blue).frame(width: 5, height: 5)
                    }
                }.font(.system(size: 7, weight: .bold)).offset(x: 3, y: 2)
            }
    }
}

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
                AgentMark(kind: item.reference.kind, size: 12)
            }
        }
    }
}
