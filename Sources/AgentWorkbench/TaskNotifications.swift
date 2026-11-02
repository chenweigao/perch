import AppKit
import UserNotifications
import WorkbenchCore

final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    var onOpenDashboard: (() -> Void)?
    private var completions: [String: String] = [:]
    private var completionSound = false
    private var completionDelivery: DispatchWorkItem?
    func start() { UNUserNotificationCenter.current().delegate = self }
    func requestPermission(_ completion: @escaping (String?) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, error in
            DispatchQueue.main.async { completion(error?.localizedDescription ?? (allowed ? nil : L("通知未开启，请在系统设置 → 通知中允许 Perch。"))) }
        }
    }
    /// `sound` attaches the default notification sound; the router decides it from
    /// the event's level.
    func post(id: String, title: String, event: TaskEventKind, sound: Bool) {
        if event == .completed {
            completions[id] = title
            completionSound = completionSound || sound
            guard completionDelivery == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.deliverCompletions() }
            completionDelivery = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            return
        }
        cancelPendingCompletions(for: id)
        let content = UNMutableNotificationContent()
        content.title = title
        switch event {
        case .failed: content.body = L("任务执行失败，请查看详情。")
        case .stalled: content.body = L("任务几分钟没有新进展，可能卡住了。")
        case .completed, .needsInput: content.body = L("这个任务需要你确认或回答。")
        }
        content.userInfo = ["session": id]; content.sound = sound ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id):\(event.rawValue)", content: content, trigger: nil))
    }
    func postInactivity(id: String, title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = L("任务长时间没有更新，请检查当前进展。")
        content.userInfo = ["session": id]; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "inactivity:" + id, content: content, trigger: nil))
    }
    func cancelPendingCompletions(for id: String? = nil) {
        if let id { completions.removeValue(forKey: id) } else { completions.removeAll() }
        if completions.isEmpty { completionDelivery?.cancel(); completionDelivery = nil; completionSound = false }
    }
    private func deliverCompletions() {
        let batch = completions, sound = completionSound
        completions.removeAll(); completionDelivery = nil; completionSound = false
        guard !batch.isEmpty, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        if batch.count == 1, let item = batch.first {
            content.title = item.value
            content.body = L("回复已完成，可以查看结果。")
            content.userInfo = ["session": item.key]
        } else {
            content.title = L("\(batch.count) 个任务已有结果")
            content.body = L("打开工作台查看已完成的回复。")
            content.userInfo = ["dashboard": true]
        }
        content.sound = sound ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "completed-batch", content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["session"] as? String {
            DispatchQueue.main.async { self.onOpen?(id); NSApp.activate(ignoringOtherApps: true) }
        } else if response.notification.request.content.userInfo["dashboard"] as? Bool == true {
            DispatchQueue.main.async { self.onOpenDashboard?(); NSApp.activate(ignoringOtherApps: true) }
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
    var message: String {
        switch kind {
        case .completed: return L("结果待查看")
        case .failed: return L("任务执行失败")
        case .needsInput: return L("需要你处理")
        case .stalled: return L("可能卡住了")
        }
    }
}
