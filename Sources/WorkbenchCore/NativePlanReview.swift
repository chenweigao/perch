import Foundation

/// A real runtime approval request, never inferred from assistant prose or a task list.
public struct NativePlanReview: Equatable, Identifiable {
    public let id: String
    public let revision: String
    public let content: String
    public let complete: Bool
    public let deferred: Bool
    public let changed: Bool
    public init?(_ request: JSONValue) {
        guard let id = request["id"].string, let revision = request["planReview"]["revision"].string else { return nil }
        self.id = id
        self.revision = revision
        content = request["planReview"]["content"].string ?? ""
        complete = request["planReview"]["complete"] == .bool(true) && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        changed = request["planReview"]["changed"] == .bool(true)
        deferred = request["planReview"]["status"].string == "deferred"
    }
    public func answer(_ decision: String, feedback: String) -> [String: JSONValue] {
        ["id": .string(id), "planRevision": .string(revision), "decision": .string(decision), "feedback": .string(feedback)]
    }
}
