import AppKit
import Observation
import WorkbenchCore

/// Owns notification preferences, per-session event tracking and toast expiry.
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
    var notifyAttentionOnly = UserDefaults.standard.bool(forKey: "task.notifications.attentionOnly") {
        didSet {
            UserDefaults.standard.set(notifyAttentionOnly, forKey: "task.notifications.attentionOnly")
            notifications.cancelPendingCompletions()
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
        guard let event = taskEvents.observe(state, id: id, online: online) else { return }
        guard !mutedTasks.contains(id), !notifyAttentionOnly || event != .completed else { return }
        if NSApp.isActive && visibleSessionID == id { return }
        let notice = TaskNotice(sessionID: id, title: title, kind: event)
        taskNotice = notice
        if notificationsEnabled && !NSApp.isActive { notifications.post(id: id, title: title, event: event) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.taskNotice?.id == notice.id { self?.taskNotice = nil }
        }
    }
}
