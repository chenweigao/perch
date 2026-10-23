import Foundation
import Observation
import WorkbenchCore

/// One reader per presentation. It never changes the connection's selected
/// conversation. A dismissed or replaced page cannot publish a late response.
@MainActor @Observable final class TaskContextState {
    private(set) var reference: SessionReference?
    private(set) var snapshot: TaskContextSnapshot?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var outputs: [String: String] = [:]
    private(set) var working: Set<String> = []
    private(set) var actionErrors: [String: String] = [:]
    private(set) var stopRequested: Set<String> = []
    var refresh = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sourceGeneration = UUID()
    @ObservationIgnored private var stopTimes: [String: Date] = [:]

    func follow(_ reference: SessionReference?, online: Bool,
                read: @escaping () async throws -> TaskContextSnapshot) async {
        let token = UUID(); generation = token
        if self.reference != reference {
            sourceGeneration = UUID(); stopTimes = [:]
            self.reference = reference; snapshot = nil; outputs = [:]
            actionErrors = [:]; stopRequested = []; working = []
        }
        error = nil; loading = reference != nil && online && snapshot == nil
        guard reference != nil else { loading = false; return }
        guard online else { error = L("状态未同步"); loading = false; return }
        defer { if generation == token { loading = false } }
        while !Task.isCancelled && generation == token {
            do {
                let value = try await read()
                try Task.checkCancellation()
                guard generation == token else { return }
                snapshot = value; error = nil; loading = false
                stopRequested = stopRequested.filter { id in value.tasks.contains { $0.id == id && $0.isRunning } }
                for id in stopRequested where Date().timeIntervalSince(stopTimes[id] ?? .distantPast) > 15 {
                    stopRequested.remove(id)
                    actionErrors[id] = L("停止尚未确认，请查看输出或重试。")
                }
                try await Task.sleep(for: .seconds(value.busy || value.tasks.contains(where: \.isRunning) ? 2 : 8))
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription; loading = false
                return // Explicit retry or the connection's next online transition.
            }
        }
    }

    func perform(_ task: KimiTask, source: SessionReference, stopping: Bool,
                 operation: () async throws -> String) async {
        guard reference == source, !working.contains(task.id) else { return }
        let token = sourceGeneration
        working.insert(task.id); actionErrors[task.id] = nil
        do {
            let result = try await operation()
            guard sourceGeneration == token, reference == source else { return }
            if stopping { stopRequested.insert(task.id); stopTimes[task.id] = Date() }
            else { outputs[task.id] = result }
        } catch {
            guard sourceGeneration == token, reference == source else { return }
            actionErrors[task.id] = error.localizedDescription
        }
        if sourceGeneration == token { working.remove(task.id) }
    }
}

extension WorkbenchModel {
    func readTaskContext(_ source: SessionReference) async throws -> TaskContextSnapshot {
        guard let agents = agentConnections(for: source.hostID) else { throw WorkbenchError(L("状态未同步")) }
        if source.kind == .kimi { return try await agents.kimi.readTaskContext(source.terminalID) }
        return try await agents.native.readTaskContext(source.terminalID)
    }
    func taskContextOperation(_ task: KimiTask, source: SessionReference, stop: Bool) async throws -> String {
        guard let agents = agentConnections(for: source.hostID) else { throw WorkbenchError(L("状态未同步")) }
        if source.kind == .kimi { return try await agents.kimi.taskContextOperation(task, session: source.terminalID, stop: stop) }
        guard stop, task.stoppable == true else { throw WorkbenchError(L("请在完整会话中查看")) }
        try await agents.native.stopTaskContextAgent(task.id, session: source.terminalID)
        return ""
    }
}
