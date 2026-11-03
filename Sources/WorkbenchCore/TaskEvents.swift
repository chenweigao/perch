import Foundation

/// `stalled` never comes from the tracker: only the status line of an open
/// session can tell that a running turn stopped making progress.
public enum TaskEventKind: String { case completed, needsInput, failed, stalled }

/// Turns each session's `SessionTurn` into the events that may call the reader
/// back, by comparing it with the previous observation of the same session.
public struct TaskEventTracker {
    private var previous: [String: SessionTurn] = [:]
    public init() {}
    public mutating func observe(_ turn: SessionTurn, id: String, online: Bool) -> TaskEventKind? {
        guard online else { return nil }
        let old = previous.updateValue(turn, forKey: id)
        guard let old else { return nil }
        if turn.failed && !old.failed { return .failed }
        if turn.pending && !old.pending { return .needsInput }
        if !turn.running, let completion = turn.completion, completion != old.completion { return .completed }
        return nil
    }
}
