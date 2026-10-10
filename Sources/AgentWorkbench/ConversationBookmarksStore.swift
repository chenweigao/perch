import Foundation
import WorkbenchCore

/// App-wide turn bookmarks, persisted in UserDefaults. Rows and menus share
/// this one store, so a mark is visible the moment it is set.
@MainActor @Observable
final class ConversationBookmarksStore {
    static let shared = ConversationBookmarksStore()
    private(set) var bookmarks = ConversationBookmarks()
    private let defaultsKey = "perch.conversationBookmarks"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ConversationBookmarks.self, from: data) else { return }
        bookmarks = decoded
    }

    func isBookmarked(_ turn: String, in session: String) -> Bool {
        bookmarks.isBookmarked(turn, in: session)
    }

    func toggle(_ turn: String, in session: String) {
        bookmarks.toggle(turn, in: session)
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
