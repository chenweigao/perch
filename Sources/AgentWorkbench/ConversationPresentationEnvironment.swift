import SwiftUI
import WorkbenchCore

private struct ConversationPresentationsKey: EnvironmentKey {
    static let defaultValue: ConversationPresentationCache? = nil
}
extension EnvironmentValues {
    var conversationPresentations: ConversationPresentationCache? {
        get { self[ConversationPresentationsKey.self] }
        set { self[ConversationPresentationsKey.self] = newValue }
    }
}
