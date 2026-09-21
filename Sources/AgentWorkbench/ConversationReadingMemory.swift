import SwiftUI
import WorkbenchCore

/// Small presentation records survive detached hosting controllers and session switches.
final class ConversationReadingMemory {
    static let shared = ConversationReadingMemory()
    static let disclosureDuration: TimeInterval = 0.2
    struct Position {
        var entry: String
        var index: Int
        var offset: CGFloat
    }
    var measuredHeights: [String: [String: CGFloat]] = [:]
    var positions: [String: Position] = [:]
    var following: [String: Bool] = [:]
    var expansions: [String: Bool] = [:]
    var seenRevision: [String: String] = [:]
}
private struct ConversationReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private struct ConversationDisclosureAction: EnvironmentKey { static let defaultValue: (Bool) -> Void = { _ in } }
private struct ConversationMemoryKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var conversationReduceMotion: Bool {
        get { self[ConversationReduceMotionKey.self] }
        set { self[ConversationReduceMotionKey.self] = newValue }
    }
    var conversationDisclosureWillChange: (Bool) -> Void {
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.conversationReduceMotion) private var inheritedReduceMotion
    @Environment(\.conversationDisclosureWillChange) private var disclosureWillChange
    @State private var revision = 0
    let name: String
    let initial: Bool
    init(_ name: String, initial: Bool = false) { self.name = name; self.initial = initial }
    var wrappedValue: Bool {
        get { _ = revision; return ConversationReadingMemory.shared.expansions[scope + ":" + name] ?? initial }
        nonmutating set {
            let reduceMotion = systemReduceMotion || inheritedReduceMotion
            disclosureWillChange(!reduceMotion)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: ConversationReadingMemory.disclosureDuration)) {
                ConversationReadingMemory.shared.expansions[scope + ":" + name] = newValue
                revision += 1
            }
        }
    }
    var projectedValue: Binding<Bool> { Binding(get: { wrappedValue }, set: { wrappedValue = $0 }) }
}

struct ConversationFindTarget {
    let session: String
    let hit: ConversationSearchHit
    let query: String
}
