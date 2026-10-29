import Foundation

/// The task the inspector's task page shows in detail: one entry of one
/// session's task list. Held for the presentation only, never persisted.
public struct TaskContextRoute: Hashable, Sendable {
    public let source: SessionReference
    public let taskID: String

    public init(source: SessionReference, taskID: String) {
        self.source = source; self.taskID = taskID
    }
}

/// One read of a Kimi task's output: the tail the server returned and the size
/// of the whole output, when it reports one.
public struct TaskContextOutput: Equatable, Sendable {
    public let text: String
    public let bytes: Int?

    public init(text: String, bytes: Int?) { self.text = text; self.bytes = bytes }
    public init(_ task: KimiTask) { self.init(text: task.outputPreview ?? "", bytes: task.outputBytes) }

    /// The output is longer than the tail the panel reads.
    public var truncated: Bool { (bytes ?? 0) > KimiTask.outputTailBytes }
}

extension KimiTask {
    /// Bytes of output tail a single task read asks for.
    public static let outputTailBytes = 16_384

    /// The third line of a task panel row: the first line of the command a
    /// background process runs, else the tool a subagent used last.
    public var contextDetailLine: String? {
        if let line = command?.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return line
        }
        guard let tool = latestActivity?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty else { return nil }
        return L("最近工具：\(tool)")
    }
}

extension TaskContextSnapshot {
    /// The task a route names, while the latest read still lists it.
    public func task(for route: TaskContextRoute) -> KimiTask? {
        tasks.first { $0.id == route.taskID }
    }

    /// Entries of Kimi's persisted task list read an output tail and cancel
    /// through the task API; roster subagents belong to the running turn.
    public func readsOutput(_ task: KimiTask) -> Bool { listedTaskIDs.contains(task.id) }

    /// The panel can stop this task now: a running entry of Kimi's task list,
    /// or a subagent its runtime marks individually stoppable.
    public func stops(_ task: KimiTask) -> Bool {
        task.isRunning && (readsOutput(task) || task.stoppable == true)
    }
}
