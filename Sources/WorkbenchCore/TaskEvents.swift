import Foundation

public struct TaskEventState: Equatable {
    public let running: Bool
    public let pending: Bool
    public let failed: Bool
    public let completion: String?
    public init(running: Bool, pending: Bool, failed: Bool, completion: String?) {
        self.running = running; self.pending = pending; self.failed = failed; self.completion = completion
    }
}
public enum TaskEventKind: String { case completed, needsInput, failed }
public struct TaskEventTracker {
    private var previous: [String: TaskEventState] = [:]
    public init() {}
    public mutating func observe(_ state: TaskEventState, id: String, online: Bool) -> TaskEventKind? {
        guard online else { return nil }
        let old = previous.updateValue(state, forKey: id)
        guard let old else { return nil }
        if state.failed && !old.failed { return .failed }
        if state.pending && !old.pending { return .needsInput }
        if !state.running, let completion = state.completion, completion != old.completion { return .completed }
        return nil
    }
}
