import Foundation
import WorkbenchCore

func checkAttentionRouting() {
    let defaults = AttentionPreferences(systemNotifications: true)
    func route(_ event: AttentionEvent, _ context: AttentionContext, _ preferences: AttentionPreferences = defaults) -> AttentionDelivery {
        AttentionRouter.route(event, context: context, preferences: preferences)
    }

    // A finished turn: nothing while watching, a quiet notice elsewhere, a sounding notification away.
    precondition(route(.completed, .watching) == .none, "The status line already shows the end of the watched turn")
    precondition(route(.completed, .elsewhere) == AttentionDelivery(notice: true), "A finished turn never sounds while Perch is in front")
    precondition(route(.completed, .away) == AttentionDelivery(notice: true, systemNotification: true, notificationSound: true))

    // Events that need the reader sound in front too.
    for event in [AttentionEvent.needsInput, .failed] {
        precondition(route(event, .watching) == AttentionDelivery(sound: true), "\(event) sounds even on the watched session")
        precondition(route(event, .elsewhere) == AttentionDelivery(notice: true, sound: true))
        precondition(route(event, .away) == AttentionDelivery(notice: true, systemNotification: true, notificationSound: true))
    }
    // Stalls default to silent.
    precondition(route(.stalled, .elsewhere) == AttentionDelivery(notice: true))
    precondition(route(.stalled, .away) == AttentionDelivery(notice: true, systemNotification: true))

    // Levels: off mutes every channel, silent keeps notices without sound.
    var quiet = defaults
    quiet.levels[.needsInput] = .off
    quiet.levels[.failed] = .silent
    for context in [AttentionContext.watching, .elsewhere, .away] {
        precondition(route(.needsInput, context, quiet) == .none, "Off mutes \(context)")
    }
    precondition(route(.failed, .watching, quiet) == .none)
    precondition(route(.failed, .away, quiet) == AttentionDelivery(notice: true, systemNotification: true))

    // Without system notifications Perch plays nothing from the background.
    let local = AttentionPreferences(systemNotifications: false)
    precondition(route(.needsInput, .away, local) == AttentionDelivery(notice: true), "No background sound without a notification")
    precondition(route(.needsInput, .elsewhere, local) == AttentionDelivery(notice: true, sound: true))

    // Dock badge: a count of sessions waiting for the reader, else a dot for unread results.
    precondition(AttentionBadge.label(attention: 2, unread: 5) == "2")
    precondition(AttentionBadge.label(attention: 0, unread: 1) == AttentionBadge.unreadMark)
    precondition(AttentionBadge.label(attention: 0, unread: 0) == nil)
    let host = UUID()
    func session(_ id: String, _ section: WorkQueueSection, online: Bool = true, archived: Bool = false) -> WorkspaceSession {
        WorkspaceSession(reference: SessionReference(hostID: host, terminalID: id, kind: .kimi), title: id, directory: "/p",
                         hostName: "h", detail: "", online: online, section: section, canMarkReviewed: section == .review, archived: archived)
    }
    let catalog = [session("a", .attention), session("b", .attention, online: false), session("c", .attention, archived: true),
                   session("d", .review), session("e", .running)]
    precondition(AttentionBadge.label(for: catalog) == "1", "Offline and archived sessions do not count")
    precondition(AttentionBadge.label(for: [session("d", .review), session("f", .review, online: false)]) == AttentionBadge.unreadMark)
    print("PASS: attention routing by event, level and reader context; Dock badge counts")
}
