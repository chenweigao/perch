import AppKit
import Observation
import WorkbenchCore

/// Owns notification preferences, per-session event tracking, toast expiry, the
/// in-app sound and the Dock badge. `AttentionRouter` decides the channels for
/// each event from where the reader is; this type only delivers them.
@MainActor @Observable
final class WorkbenchNotificationState {
    var taskNotice: TaskNotice?
    var notificationError: String?
    var notificationsEnabled = UserDefaults.standard.bool(forKey: "task.notifications") {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "task.notifications")
            notifications.cancelPendingCompletions()
            if notificationsEnabled { notifications.requestPermission { [weak self] error in self?.notificationError = error } }
        }
    }
    /// Per-event strength. The former “only notify tasks that need me” switch
    /// becomes a muted finished-turn level the first time this loads.
    private(set) var levels: [AttentionEvent: AttentionLevel] = WorkbenchNotificationState.loadLevels()
    func level(_ event: AttentionEvent) -> AttentionLevel { preferences.level(event) }
    func setLevel(_ level: AttentionLevel, for event: AttentionEvent) {
        levels[event] = level
        UserDefaults.standard.set(level.rawValue, forKey: Self.levelKey(event))
        notifications.cancelPendingCompletions()
    }
    var showsDockBadge = UserDefaults.standard.object(forKey: "task.notifications.dockBadge") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsDockBadge, forKey: "task.notifications.dockBadge")
            applyDockBadge()
        }
    }
    private(set) var mutedTasks = Set(UserDefaults.standard.stringArray(forKey: "task.notifications.muted") ?? [])
    func toggleTaskNotifications(_ id: String) {
        if mutedTasks.contains(id) { mutedTasks.remove(id) } else { mutedTasks.insert(id) }
        UserDefaults.standard.set(Array(mutedTasks), forKey: "task.notifications.muted")
        notifications.cancelPendingCompletions(for: id)
    }
    private let notifications = TaskNotifications()
    @ObservationIgnored private var taskEvents = TaskEventTracker()
    @ObservationIgnored private var dockBadge: String?
    /// One retained instance, so a sound is not cut off when the caller returns.
    @ObservationIgnored private lazy var attentionSound = NSSound(named: NSSound.Name("Glass"))

    var preferences: AttentionPreferences { AttentionPreferences(levels: levels, systemNotifications: notificationsEnabled) }

    func notifyInactiveTask(_ rule: FollowUpRule) {
        if notificationsEnabled && !mutedTasks.contains(rule.session.id) {
            notifications.postInactivity(id: rule.session.id, title: rule.title)
        }
    }
    func start(onOpen: @escaping (String) -> Void, onOpenDashboard: @escaping () -> Void) {
        notifications.start()
        notifications.onOpen = onOpen
        notifications.onOpenDashboard = onOpenDashboard
    }

    func observe(_ state: TaskEventState, id: String, title: String, online: Bool, visibleSessionID: String?) {
        guard let kind = taskEvents.observe(state, id: id, online: online), !mutedTasks.contains(id) else { return }
        deliver(AttentionEvent(kind), id: id, title: title, context: Self.context(for: id, visibleSessionID: visibleSessionID))
    }

    /// Delivers one event through the channels the router picks.
    func deliver(_ event: AttentionEvent, id: String, title: String, context: AttentionContext) {
        let delivery = AttentionRouter.route(event, context: context, preferences: preferences)
        if delivery.notice, let kind = TaskEventKind(event) {
            let notice = TaskNotice(sessionID: id, title: title, kind: kind)
            taskNotice = notice
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?.taskNotice?.id == notice.id { self?.taskNotice = nil }
            }
        }
        if delivery.systemNotification, let kind = TaskEventKind(event) {
            notifications.post(id: id, title: title, event: kind, sound: delivery.notificationSound)
        }
        if delivery.sound { attentionSound?.stop(); attentionSound?.play() }
    }

    /// Mirrors the catalog into the Dock icon: a count of sessions that need the
    /// reader, a dot for unread results, nothing otherwise.
    func updateDockBadge(_ sessions: [WorkspaceSession]) {
        let label = AttentionBadge.label(for: sessions)
        guard label != dockBadge else { return }
        dockBadge = label
        applyDockBadge()
    }

    private func applyDockBadge() {
        let label = showsDockBadge ? dockBadge : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// Watching means the frontmost Perch window shows the session. A minimized,
    /// hidden or fully covered main window counts as elsewhere.
    static func context(for id: String, visibleSessionID: String?) -> AttentionContext {
        guard NSApp.isActive else { return .away }
        guard visibleSessionID == id, let window = NSApp.mainWindow,
              window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return .elsewhere }
        return .watching
    }

    private static func levelKey(_ event: AttentionEvent) -> String { "task.notifications.level.\(event.rawValue)" }

    private static func loadLevels() -> [AttentionEvent: AttentionLevel] {
        let defaults = UserDefaults.standard
        var levels = AttentionPreferences.defaultLevels
        for event in AttentionEvent.allCases {
            if let raw = defaults.string(forKey: levelKey(event)), let level = AttentionLevel(rawValue: raw) { levels[event] = level }
        }
        // The legacy switch muted finished-turn notices; keep that choice once.
        let legacy = "task.notifications.attentionOnly"
        if defaults.bool(forKey: legacy), defaults.string(forKey: levelKey(.completed)) == nil {
            levels[.completed] = .off
            defaults.set(AttentionLevel.off.rawValue, forKey: levelKey(.completed))
        }
        defaults.removeObject(forKey: legacy)
        return levels
    }
}

private extension TaskEventKind {
    /// Stalls are not catalog events and have no notice kind.
    init?(_ event: AttentionEvent) {
        switch event {
        case .completed: self = .completed
        case .needsInput: self = .needsInput
        case .failed: self = .failed
        case .stalled: return nil
        }
    }
}
