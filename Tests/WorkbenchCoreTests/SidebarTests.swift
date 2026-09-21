import Foundation
import WorkbenchCore

func checkSidebar() {
    let remote = UUID()
    func session(_ id: String, section: WorkQueueSection = .other, online: Bool = true,
                 archived: Bool = false, local: Bool = false) -> WorkspaceSession {
        WorkspaceSession(reference: SessionReference(hostID: local ? ExecutionEnvironment.localHostID : remote,
                         terminalID: id, kind: .omp), title: id, directory: "/tmp/sidebar",
                         hostName: local ? "本机" : "SSH", detail: section.rawValue, online: online,
                         section: section, canMarkReviewed: section == .review, archived: archived)
    }
    let pinned = session("pinned")
    let archived = session("archived", archived: true)
    let approval = session("approval", section: .attention)
    let localRun = session("local-run", section: .running, local: true)
    let sessions = [pinned, archived, approval, session("unread", section: .review),
                    session("offline-approval", section: .attention, online: false), localRun]
                 + (0..<30).map { session("recent-\($0)") }
    let pins = [archived.reference, pinned.reference]
    let all = SidebarProjection(sessions: sessions, starred: pins)
    expectEqual(all.favorites.map(\.id), [pinned.id])
    expectEqual(all.attentionCount, 1)
    expectEqual(all.recent.count, 20)
    expectEqual(all.totalRecentCount, 34)
    expectEqual(all.recent.first?.id, approval.id)
    expectFalse(all.recent.contains { $0.archived || $0.id == pinned.id })
    let running = SidebarProjection(sessions: sessions, starred: pins, filter: .running)
    let local = SidebarProjection(sessions: sessions, starred: pins, filter: .local)
    expectEqual(running.recent.map(\.id), [localRun.id])
    expectEqual(local.recent.map(\.id), [localRun.id])
    expectEqual(running.attentionCount, all.attentionCount)
    expectEqual(local.favorites.map(\.id), all.favorites.map(\.id))
    print("PASS: stable sidebar pins, bounded recents, independent filters and actionable attention count")
}
