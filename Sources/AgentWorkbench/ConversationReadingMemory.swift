import SwiftUI
import WorkbenchCore

/// Small presentation records survive detached hosting controllers and session switches.
final class ConversationReadingMemory {
    static let shared = ConversationReadingMemory()
    struct Position {
        var entry: String
        var index: Int
        var offset: CGFloat
    }
    private(set) var measuredHeights: [String: [String: CGFloat]] = [:]
    private var heightOrder: [String] = []
    private var sessionOrder: [String] = []
    private(set) var positions: [String: Position] = [:]
    var following: [String: Bool] = [:]
    var expansions: [String: Bool] = [:]
    var seenRevision: [String: String] = [:]

    func visit(_ session: String) {
        if sessionOrder.last != session {
            sessionOrder.removeAll { $0 == session }
            sessionOrder.append(session)
        }
        if sessionOrder.count > 256 { remove(sessionOrder[0]) }
    }

    func saveHeights(_ heights: [String: CGFloat], for session: String) {
        // SwiftUI can dismantle a deleted/evicted transcript after its records
        // were removed. That late teardown must not recreate the cache entry.
        guard sessionOrder.contains(session) else { return }
        measuredHeights[session] = heights
        heightOrder.removeAll { $0 == session }
        heightOrder.append(session)
        if heightOrder.count > 16 { measuredHeights.removeValue(forKey: heightOrder.removeFirst()) }
    }

    func savePosition(_ position: Position, for session: String) {
        guard sessionOrder.contains(session) else { return }
        positions[session] = position
    }

    func remove(_ session: String) {
        sessionOrder.removeAll { $0 == session }
        heightOrder.removeAll { $0 == session }
        measuredHeights.removeValue(forKey: session)
        positions.removeValue(forKey: session)
        following.removeValue(forKey: session)
        seenRevision.removeValue(forKey: session)
        expansions = expansions.filter { !$0.key.hasPrefix(session + ":") }
    }
}
private struct ConversationReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private struct ConversationDisclosureAction: EnvironmentKey { static let defaultValue: () -> Void = {} }
private struct ConversationMemoryKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var conversationReduceMotion: Bool {
        get { self[ConversationReduceMotionKey.self] }
        set { self[ConversationReduceMotionKey.self] = newValue }
    }
    var conversationDisclosureWillChange: () -> Void {
        get { self[ConversationDisclosureAction.self] }
        set { self[ConversationDisclosureAction.self] = newValue }
    }
    var conversationMemoryKey: String {
        get { self[ConversationMemoryKey.self] }
        set { self[ConversationMemoryKey.self] = newValue }
    }
}
@propertyWrapper struct RememberedExpansion: DynamicProperty {
    @Environment(\.conversationMemoryKey) private var scope
    @Environment(\.conversationDisclosureWillChange) private var disclosureWillChange
    @State private var revision = 0
    let name: String
    let initial: Bool
    init(_ name: String, initial: Bool = false) { self.name = name; self.initial = initial }
    var wrappedValue: Bool {
        get { _ = revision; return ConversationReadingMemory.shared.expansions[scope + ":" + name] ?? initial }
        nonmutating set {
            guard newValue != wrappedValue else { return }
            disclosureWillChange()
            // Commit content and native row geometry without an intermediate
            // clipping animation that can detach and reattach neighboring rows.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                ConversationReadingMemory.shared.expansions[scope + ":" + name] = newValue
                revision += 1
            }
        }
    }
    var projectedValue: Binding<Bool> {
        let binding = Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
        #if TRANSCRIPT_CHECKS
        if ConversationDisclosureFixture.enabled {
            ConversationDisclosureFixture.bindings[scope + ":" + name] = binding
        }
        #endif
        return binding
    }
}

struct ConversationFindTarget {
    let session: String
    let hit: ConversationSearchHit
    let query: String
    var options = ConversationFindOptions()
}

/// Highlight-all request from the find bar; an empty query clears highlights.
struct ConversationHighlightUpdate {
    let session: String
    let query: String
    let options: ConversationFindOptions
}

#if TRANSCRIPT_CHECKS
/// Exercise the same state setter as the disclosure buttons in native fixtures.
enum ConversationDisclosureFixture {
    static var enabled = false
    static var bindings: [String: Binding<Bool>] = [:]
    static var fullBindings: [String: Binding<Bool>] = [:]
}
#endif
