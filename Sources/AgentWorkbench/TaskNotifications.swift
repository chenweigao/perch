import AppKit
import UserNotifications
import WorkbenchCore

final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    func start() { UNUserNotificationCenter.current().delegate = self }
    func requestPermission(_ completion: @escaping (String?) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, error in
            DispatchQueue.main.async { completion(error?.localizedDescription ?? (allowed ? nil : "Notifications are disabled. Enable Perch in System Settings → Notifications.")) }
        }
    }
    func post(id: String, title: String, event: TaskEventKind) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = event == .completed ? "A response is ready to review." : event == .failed ? "The task reported a failure." : "This task needs your input."
        content.userInfo = ["session": id]; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id):\(event.rawValue)", content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["session"] as? String {
            DispatchQueue.main.async { self.onOpen?(id); NSApp.activate(ignoringOtherApps: true) }
        }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([]) // The app presents an actionable in-window notice while active.
    }
}
struct TaskNotice: Identifiable {
    let id = UUID()
    let sessionID: String
    let title: String
    let kind: TaskEventKind
    var message: String { kind == .completed ? "Response ready" : kind == .failed ? "Task failed" : "Needs your input" }
}
