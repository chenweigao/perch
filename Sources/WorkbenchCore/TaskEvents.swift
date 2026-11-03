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
/// `stalled` never comes from the tracker: only the status line of an open
/// session can tell that a running turn stopped making progress.
public enum TaskEventKind: String { case completed, needsInput, failed, stalled }
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
