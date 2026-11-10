import SwiftUI
import WorkbenchCore

/// Provider identity stays visible in every state; the small badge adds status.
struct SidebarAgentIndicator: View {
    let item: WorkspaceSession

    var body: some View {
        let mark = AgentMark(kind: item.reference.kind, size: SidebarMetrics.iconSize)
        if let badge = SidebarStatusBadge(item) {
            // A gap ring cut out of the mark around the badge, so the badge reads on
            // every brand color (several are orange or blue). The cut shows whatever
            // is behind the row, the glass or the row highlight; nothing is painted.
            mark.mask {
                Rectangle().fill(Color.black)
                    .overlay(alignment: .bottomTrailing) {
                        badge.background { Capsule().fill(Color.black).padding(-SidebarMetrics.badgeGap) }
                            .offset(SidebarMetrics.badgeOffset)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) { badge.offset(SidebarMetrics.badgeOffset) }
        } else {
            mark
        }
    }
}

/// The compact rows' status: waiting for input or unread. Offline is said once, by
/// the row itself (dimmed, with a trailing symbol); other states show the agent
/// mark alone.
private struct SidebarStatusBadge: View {
    private enum Kind { case waiting, failed, review }
    private let kind: Kind

    init?(_ item: WorkspaceSession) {
        guard item.online else { return nil }
        if item.turn?.state == .failed { kind = .failed }
        else if item.section == .attention { kind = .waiting }
        else if item.section == .review { kind = .review }
        else { return nil }
    }

    var body: some View {
        Group {
            switch kind {
            case .waiting:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .review:
                Circle().fill(.blue).frame(width: SidebarMetrics.badgeDotSize, height: SidebarMetrics.badgeDotSize)
            }
        }.font(.system(size: SidebarMetrics.badgeSize, weight: .bold))
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
