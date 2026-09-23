import Foundation

/// A small in-memory cache makes revisiting a conversation independent of network latency.
/// Cached content remains read-only until the fresh snapshot has been reconciled.
public struct KimiConversationCache {
    private var values: [String: KimiConversation] = [:]
    private var order: [String] = []
    private let capacity: Int
    public init(capacity: Int = 8) { self.capacity = capacity }
    public mutating func store(_ conversation: KimiConversation) {
        let id = conversation.snapshot.session.id
        values[id] = conversation
        order.removeAll { $0 == id }; order.append(id)
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }
    /// Read-only lookup that leaves the eviction order untouched.
    public func value(_ id: String) -> KimiConversation? { values[id] }
    public mutating func take(_ id: String) -> KimiConversation? {
        guard let value = values[id] else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return value
    }
    public mutating func remove(_ id: String) { values.removeValue(forKey: id); order.removeAll { $0 == id } }
}
