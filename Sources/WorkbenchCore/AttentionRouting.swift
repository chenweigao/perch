import Foundation

/// Events that may call the reader back to a session. Calling back is the app's
/// job, so the reader does not have to keep watching a running turn.
public enum AttentionEvent: String, CaseIterable, Sendable {
    case completed, needsInput, failed, stalled

    public init(_ kind: TaskEventKind) {
        switch kind {
        case .completed: self = .completed
        case .needsInput: self = .needsInput
        case .failed: self = .failed
        }
    }

    /// The agent is blocked or needs a look: these may sound while Perch is in
    /// front. A finished turn sounds only when Perch is in the background.
    public var needsReader: Bool { self != .completed }
}

/// How strongly one kind of event calls the reader back.
public enum AttentionLevel: String, CaseIterable, Sendable {
    /// No notice, notification or sound; badges and sidebar marks still update.
    case off
    /// A notice or notification without sound.
    case silent
    /// A notice or notification with sound.
    case sound
}

/// Where the reader is relative to the session the event belongs to.
public enum AttentionContext: Equatable, Sendable {
    /// Perch is frontmost and its window shows this session.
    case watching
    /// Perch is frontmost but shows another session, the workbench, or no main window.
    case elsewhere
    /// Perch is not the active app.
    case away
}

public struct AttentionDelivery: Equatable, Sendable {
    /// The in-window notice that opens the session.
    public var notice = false
    /// A system notification, and whether it carries the default sound.
    public var systemNotification = false
    public var notificationSound = false
    /// A sound played by Perch itself, for events delivered while it is frontmost.
    public var sound = false

    public init(notice: Bool = false, systemNotification: Bool = false, notificationSound: Bool = false, sound: Bool = false) {
        self.notice = notice; self.systemNotification = systemNotification
        self.notificationSound = notificationSound; self.sound = sound
    }
    public static let none = AttentionDelivery()
}

public struct AttentionPreferences: Equatable, Sendable {
    public var levels: [AttentionEvent: AttentionLevel]
    /// System notifications for events that happen while Perch is in the background.
    public var systemNotifications: Bool

    public init(levels: [AttentionEvent: AttentionLevel] = AttentionPreferences.defaultLevels, systemNotifications: Bool) {
        self.levels = levels
        self.systemNotifications = systemNotifications
    }

    /// Blocking events and failures sound; a finished turn sounds only in the
    /// background; a stall is noted without sound.
    public static let defaultLevels: [AttentionEvent: AttentionLevel] = [
        .completed: .sound, .needsInput: .sound, .failed: .sound, .stalled: .silent,
    ]

    public func level(_ event: AttentionEvent) -> AttentionLevel { levels[event] ?? Self.defaultLevels[event] ?? .silent }
}

public enum AttentionRouter {
    /// One rule for every channel:
    /// - watching: the session's own status line already shows the event; only
    ///   events that need the reader may sound.
    /// - elsewhere: an in-window notice; only events that need the reader may sound.
    /// - away: a system notification (when allowed) carrying the sound; Perch plays
    ///   nothing itself from the background.
    public static func route(_ event: AttentionEvent, context: AttentionContext, preferences: AttentionPreferences) -> AttentionDelivery {
        let level = preferences.level(event)
        guard level != .off else { return .none }
        let audible = level == .sound
        switch context {
        case .watching:
            return AttentionDelivery(sound: audible && event.needsReader)
        case .elsewhere:
            return AttentionDelivery(notice: true, sound: audible && event.needsReader)
        case .away:
            return AttentionDelivery(notice: true, systemNotification: preferences.systemNotifications,
                                     notificationSound: preferences.systemNotifications && audible)
        }
    }
}

/// The Dock badge: the number of sessions that need the reader (waiting for
/// confirmation or an answer, or failed), the sidebar's 待处理 count; a dot when
/// none do but finished results are unread; nothing otherwise.
public enum AttentionBadge {
    public static let unreadMark = "•"

    public static func label(attention: Int, unread: Int) -> String? {
        if attention > 0 { return String(attention) }
        return unread > 0 ? unreadMark : nil
    }

    public static func label(for sessions: [WorkspaceSession]) -> String? {
        var attention = 0, unread = 0
        for item in sessions where item.online && !item.archived {
            if item.section == .attention { attention += 1 } else if item.section == .review { unread += 1 }
        }
        return label(attention: attention, unread: unread)
    }
}
