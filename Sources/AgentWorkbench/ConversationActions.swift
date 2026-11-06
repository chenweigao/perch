import AppKit
import SwiftUI
import WorkbenchCore

/// What a transcript row or the status line can ask for. Copy stays local to
/// the row; everything else routes to the model or the connection that owns the session.
enum ConversationMessageAction {
    case quote(String)
    case editAndResend(String)
    case resend(String)
    /// Regeneration targets the assistant message; the connection finds and
    /// re-sends the user prompt that preceded it.
    case regenerate(before: String)
    /// Opens the transcript of the subagent an Agent/Task tool call started.
    case openSubagent(toolCallId: String)
    /// The status line: this turn in the task panel, the working-tree changes,
    /// and a suspected stall for the reminder settings.
    case showTurnDetails
    case showChanges
    case showEdit(VisibleTool, messageID: String)
    case turnStalled(minutes: Int)
}

/// Which session a transcript row belongs to. Rows are deep inside a native
/// hosting boundary, so actions travel as notifications with this payload.
struct ConversationActionContext: Equatable, Sendable {
    let hostID: UUID
    let kind: SessionKind
    let sessionID: String
    /// The session's bridge records subagents, so Agent/Task tool cards offer
    /// `openSubagent`. Set once per session load; it never changes per token.
    var opensSubagents = false
    /// Completed-task Recap key and the settled assistant message that hosts
    /// its action button. Both stay nil while a turn runs.
    var recapKey: String? = nil
    var recapMessageID: String? = nil

    static func recapTargetID(in messages: [KimiMessage], recapKey: String?) -> String? {
        guard recapKey != nil else { return nil }
        for message in messages.reversed() {
            guard message.role == "assistant", !message.isCompactionSummary else { continue }
            if message.content.contains(where: { $0.type == "text" && !$0.isRuntimeContext }) {
                return message.id
            }
        }
        return nil
    }
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
        let copy = NSMenuItem(title: L("复制"), action: #selector(CopyTextTarget.perform(_:)), keyEquivalent: "")
        copy.target = CopyTextTarget.shared
        copy.representedObject = copyText
        var items = [copy, .separator()]
        for (title, action) in [(L("引用到输入框"), ConversationMessageAction.quote(sourceText)),
                                (L("编辑后重发"), .editAndResend(sourceText)),
                                (L("再次发送"), .resend(sourceText))] as [(String, ConversationMessageAction)] {
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

final class BookmarkTurnTarget: NSObject {
    static let shared = BookmarkTurnTarget()
    struct Mark { let turn: String; let session: String }
    @objc func perform(_ sender: NSMenuItem) {
        guard let mark = sender.representedObject as? Mark else { return }
        Task { @MainActor in ConversationBookmarksStore.shared.toggle(mark.turn, in: mark.session) }
    }
}

extension ConversationActionContext {
    /// Bookmark items read the store at menu-open time, so the title always
    /// reflects the current mark.
    @MainActor static func bookmarkMenuItem(turn: String, session: String) -> NSMenuItem {
        let marked = ConversationBookmarksStore.shared.isBookmarked(turn, in: session)
        let item = NSMenuItem(title: marked ? L("取消收藏此轮") : L("收藏此轮"),
                              action: #selector(BookmarkTurnTarget.perform(_:)), keyEquivalent: "")
        item.target = BookmarkTurnTarget.shared
        item.representedObject = BookmarkTurnTarget.Mark(turn: turn, session: session)
        return item
    }
}

/// SwiftUI context menu for a user's own message.
struct UserMessageContextMenu: View {
    let context: ConversationActionContext
    let text: String
    /// Turn id + reading key for the bookmark toggle; nil hides it.
    var bookmark: (turn: String, session: String)? = nil
    var body: some View {
        Button("复制") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Divider()
        Button("引用到输入框") { context.post(.quote(text)) }
        Button("编辑后重发") { context.post(.editAndResend(text)) }
        Button("再次发送") { context.post(.resend(text)) }
        if let bookmark {
            Divider()
            let marked = ConversationBookmarksStore.shared.isBookmarked(bookmark.turn, in: bookmark.session)
            Button(marked ? "取消收藏此轮" : "收藏此轮") {
                ConversationBookmarksStore.shared.toggle(bookmark.turn, in: bookmark.session)
            }
        }
    }
}
