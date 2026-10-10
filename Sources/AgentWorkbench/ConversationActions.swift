import AppKit
import SwiftUI
import WorkbenchCore

/// What a transcript row can ask for. Copy stays local to the row; everything
/// else routes to the connection that owns the session.
enum ConversationMessageAction {
    case quote(String)
    case editAndResend(String)
    case resend(String)
    /// Regeneration targets the assistant message; the connection finds and
    /// re-sends the user prompt that preceded it.
    case regenerate(before: String)
}

/// Which session a transcript row belongs to. Rows are deep inside a native
/// hosting boundary, so actions travel as notifications with this payload.
struct ConversationActionContext: Equatable, Sendable {
    let hostID: UUID
    let kind: SessionKind
    let sessionID: String
}

struct ConversationActionPayload {
    let context: ConversationActionContext
    let action: ConversationMessageAction
}

extension Notification.Name {
    static let conversationAction = Notification.Name("PerchConversationMessageAction")
}

private struct ConversationActionContextKey: EnvironmentKey {
    static let defaultValue: ConversationActionContext? = nil
}
extension EnvironmentValues {
    var conversationActionContext: ConversationActionContext? {
        get { self[ConversationActionContextKey.self] }
        set { self[ConversationActionContextKey.self] = newValue }
    }
}

extension ConversationActionContext {
    func post(_ action: ConversationMessageAction) {
        NotificationCenter.default.post(name: .conversationAction,
                                        object: ConversationActionPayload(context: self, action: action))
    }
}

/// Native (AppKit) rows build an NSMenu from the same action list as the
/// SwiftUI context menu, so both render paths offer identical commands.
final class ConversationMenuTarget: NSObject {
    static let shared = ConversationMenuTarget()
    @objc func perform(_ item: NSMenuItem) {
        guard let payload = item.representedObject as? ConversationActionPayload else { return }
        NotificationCenter.default.post(name: .conversationAction, object: payload)
    }
}

extension ConversationActionContext {
    /// Right-click items for a user's own message, shared by the bubble menu
    /// and the text views inside it.
    func userMenuItems(copyText: String, sourceText: String) -> [NSMenuItem] {
        let copy = NSMenuItem(title: "复制", action: #selector(CopyTextTarget.perform(_:)), keyEquivalent: "")
        copy.target = CopyTextTarget.shared
        copy.representedObject = copyText
        var items = [copy, .separator()]
        for (title, action) in [("引用到输入框", ConversationMessageAction.quote(sourceText)),
                                ("编辑后重发", .editAndResend(sourceText)),
                                ("再次发送", .resend(sourceText))] as [(String, ConversationMessageAction)] {
            let item = NSMenuItem(title: title, action: #selector(ConversationMenuTarget.perform(_:)), keyEquivalent: "")
            item.target = ConversationMenuTarget.shared
            item.representedObject = ConversationActionPayload(context: self, action: action)
            items.append(item)
        }
        return items
    }
    /// Right-click menu for a user's own message bubble.
    func userMenu(copyText: String, sourceText: String) -> NSMenu {
        let menu = NSMenu()
        userMenuItems(copyText: copyText, sourceText: sourceText).forEach { menu.addItem($0) }
        return menu
    }
}

final class CopyTextTarget: NSObject {
    static let shared = CopyTextTarget()
    @objc func perform(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// SwiftUI context menu for a user's own message.
struct UserMessageContextMenu: View {
    let context: ConversationActionContext
    let text: String
    var body: some View {
        Button("复制") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Divider()
        Button("引用到输入框") { context.post(.quote(text)) }
        Button("编辑后重发") { context.post(.editAndResend(text)) }
        Button("再次发送") { context.post(.resend(text)) }
    }
}
