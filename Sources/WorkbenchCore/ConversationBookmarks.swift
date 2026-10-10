import Foundation

/// Bookmarked turns per session reading key. Toggle semantics keep the most
/// recent bookmarks bounded; order is recency of marking, not turn order.
public struct ConversationBookmarks: Codable, Equatable, Sendable {
    private var turns: [String: [String]] = [:]
    public init() {}
    public func turns(in session: String) -> [String] { turns[session] ?? [] }
    public func isBookmarked(_ turn: String, in session: String) -> Bool {
        turns[session]?.contains(turn) == true
    }
    public mutating func toggle(_ turn: String, in session: String, limit: Int = 50) {
        var list = turns[session] ?? []
        if let index = list.firstIndex(of: turn) {
            list.remove(at: index)
        } else {
            list.append(turn)
            if list.count > limit { list.removeFirst(list.count - limit) }
        }
        turns[session] = list
    }
}
