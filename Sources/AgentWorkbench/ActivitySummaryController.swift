import Foundation
import SwiftUI
import WorkbenchCore

struct ActivityNarrativeFailure: Equatable {
    let message: String
    let date: Date
}

@MainActor final class ActivityNarrativeStore: ObservableObject {
    static let shared = ActivityNarrativeStore()

    private struct SessionState {
        var base = ActivityNarrativeSnapshot(turnID: nil, stages: [], entryStageIDs: [:])
        var current: ActivityNarrative?
        var rows: [String: ActivityNarrativeRow] = [:]
        var deferred: ActivityNarrativeSnapshot?
        var attempts: [String: ActivitySummaryBatch] = [:]
        var results: [String: ActivitySummaryResult] = [:]
        var observedRunning = false
        var settingsRevision = -1
        var failure: ActivityNarrativeFailure?
        var retryBatch: ActivitySummaryBatch?
        var touched = Date()
    }
    private struct Pending {
        let session: String
        let batch: ActivitySummaryBatch
        let configuration: ActivitySummaryConfiguration
        let settingsRevision: Int
        let force: Bool
    }

    @Published private var sessions: [String: SessionState] = [:]
    private var pending: Pending?
    private var worker: Task<Void, Never>?
    private var activeSession: String?
    private var activeGroupID: String?
    private var lastRequest = Date.distantPast
    private var generation = 0
    private var observedSession: String?
    private let minimumInterval: TimeInterval
    typealias Summarizer = (ActivitySummaryConfiguration, ActivitySummaryBatch, ActivitySummaryResult?) async throws -> ActivitySummaryResult
    private let summarize: Summarizer

    init(minimumInterval: TimeInterval = 8, summarize: Summarizer? = nil) {
        self.minimumInterval = minimumInterval
        self.summarize = summarize ?? { configuration, batch, previous in
            let settings = ActivitySummarySettings.shared
            let revision = settings.revision
            let key = try await settings.apiKey()
            try Task.checkCancellation()
            guard settings.revision == revision else { throw CancellationError() }
            return try await ActivitySummaryClient().summarize(configuration: configuration, apiKey: key,
                batch: batch, language: AppLanguage.current.localization, previous: previous)
        }
    }

    func narrative(session: String) -> ActivityNarrative? { sessions[session]?.current }
    func row(session: String, entryID: String) -> ActivityNarrativeRow? { sessions[session]?.rows[entryID] }
    func failure(session: String) -> ActivityNarrativeFailure? { sessions[session]?.failure }
    func canRetry(session: String) -> Bool { sessions[session]?.retryBatch != nil }

    func observe(session: String, snapshot: ActivityNarrativeSnapshot, batch: ActivitySummaryBatch?,
                 running: Bool, online: Bool, following: Bool,
                 settings: ActivitySummarySettings) {
        if let observedSession, observedSession != session { cancelRequest() }
        observedSession = session
        var state = sessions[session] ?? SessionState()
        state.touched = Date()
        state.base = snapshot
        if running { state.observedRunning = true }
        if state.settingsRevision != settings.revision {
            if activeSession == session { cancelRequest() }
            if pending?.session == session { pending = nil }
            state.settingsRevision = settings.revision
            state.attempts = [:]
        }
        let rendered = snapshot.applying(state.results)
        state.current = rendered.current
        if following {
            state.rows = Self.rows(in: rendered)
            state.deferred = nil
        } else {
            let latest = Self.rows(in: rendered)
            for (entryID, narrative) in latest where state.rows[entryID] == nil {
                state.rows[entryID] = narrative
            }
            state.deferred = rendered
        }
        sessions[session] = state
        trimSessions()

        guard settings.configuration.enabled, online, state.observedRunning, let batch else {
            if activeSession == session || pending?.session == session { cancelRequest() }
            return
        }
        guard batch.shouldRequest(after: state.attempts[batch.groupID]) else { return }
        enqueue(Pending(session: session, batch: batch, configuration: settings.configuration,
                        settingsRevision: settings.revision, force: false), settings: settings)
    }

    func retry(session: String, settings: ActivitySummarySettings) {
        guard settings.configuration.enabled, let batch = sessions[session]?.retryBatch else { return }
        if sessions[session] != nil { sessions[session]!.failure = nil }
        enqueue(Pending(session: session, batch: batch, configuration: settings.configuration,
                        settingsRevision: settings.revision, force: true), settings: settings)
    }

    private static func rows(in snapshot: ActivityNarrativeSnapshot) -> [String: ActivityNarrativeRow] {
        snapshot.rows
    }

    private func enqueue(_ request: Pending, settings: ActivitySummarySettings) {
        pending = request
        guard worker == nil else { return }
        let version = generation
        worker = Task { [weak self, weak settings] in
            guard let self, let settings else { return }
            defer {
                if self.generation == version {
                    self.worker = nil
                    self.activeSession = nil
                    self.activeGroupID = nil
                }
            }
            while !Task.isCancelled, self.pending != nil {
                let delay = max(0, self.minimumInterval - Date().timeIntervalSince(self.lastRequest))
                do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) } }
                catch { return }
                // Select after the throttle so a burst sends the newest event.
                guard let next = self.pending else { return }
                self.pending = nil
                self.activeSession = next.session
                self.activeGroupID = next.batch.groupID
                defer {
                    if self.generation == version {
                        self.activeSession = nil
                        self.activeGroupID = nil
                    }
                }
                guard !Task.isCancelled, self.generation == version,
                      settings.configuration.enabled,
                      settings.revision == next.settingsRevision else { return }
                guard var state = self.sessions[next.session] else { continue }
                if !next.force && !next.batch.shouldRequest(after: state.attempts[next.batch.groupID]) { continue }
                state.attempts[next.batch.groupID] = next.batch
                state.failure = nil
                state.retryBatch = nil
                self.sessions[next.session] = state
                self.lastRequest = Date()
                do {
                    // Stage order is scoped to the current turn; never carry an
                    // unrelated request's summary into the next turn.
                    let previous = state.base.stages.prefix { $0.narrative.stageID != next.batch.groupID }
                        .reversed().compactMap { stage -> ActivitySummaryResult? in
                            let narrative = stage.narrative
                            if let result = state.results[narrative.stageID] { return result }
                            guard narrative.source == .provider || narrative.source == .commentary else { return nil }
                            return ActivitySummaryResult(subject: narrative.subject, phase: narrative.phase,
                                summary: narrative.headline)
                        }.first
                    let prior = state.results[next.batch.groupID] ?? previous
                    let result = try await self.summarize(next.configuration, next.batch, prior)
                    guard !Task.isCancelled, self.generation == version,
                          settings.revision == next.settingsRevision,
                          var current = self.sessions[next.session] else { return }
                    if let pending = self.pending, pending.session == next.session,
                       pending.batch.groupID == next.batch.groupID,
                       pending.batch.shouldRequest(after: next.batch) { continue }
                    if current.base.stages.contains(where: { $0.narrative.stageID == next.batch.groupID
                        && $0.narrative.source == .local }) {
                        if result.shouldUpdate {
                            current.results[next.batch.groupID] = result
                        }
                        // A no-change response can keep only this stage's existing
                        // refinement. Earlier stages already own their headlines
                        // in history; copying one here would display it twice.
                        current.failure = nil
                        current.retryBatch = nil
                        let rendered = current.base.applying(current.results)
                        current.current = rendered.current
                        if current.deferred == nil { current.rows = Self.rows(in: rendered) }
                        else { current.deferred = rendered }
                        self.sessions[next.session] = current
                        self.trimStages()
                    }
                } catch {
                    if Task.isCancelled || self.generation != version || settings.revision != next.settingsRevision { return }
                    if self.pending?.session == next.session { continue }
                    guard var current = self.sessions[next.session] else { continue }
                    current.failure = ActivityNarrativeFailure(message: error.localizedDescription, date: Date())
                    current.retryBatch = next.batch
                    self.sessions[next.session] = current
                }
            }
        }
    }

    private func cancelRequest() {
        if let activeSession, let activeGroupID {
            sessions[activeSession]?.attempts.removeValue(forKey: activeGroupID)
        }
        generation += 1
        worker?.cancel()
        worker = nil
        activeSession = nil
        activeGroupID = nil
        pending = nil
    }

    private func trimSessions() {
        guard sessions.count > 64 else { return }
        for key in sessions.sorted(by: { $0.value.touched < $1.value.touched }).prefix(sessions.count - 64).map(\.key) {
            sessions.removeValue(forKey: key)
        }
    }

    private func trimStages() {
        var overflow = sessions.values.reduce(0) { $0 + $1.results.count } - 256
        guard overflow > 0 else { return }
        for key in sessions.sorted(by: { $0.value.touched < $1.value.touched }).map(\.key) where overflow > 0 {
            guard var state = sessions[key] else { continue }
            let removable = min(overflow, state.results.count)
            for stageID in state.results.keys.sorted().prefix(removable) { state.results.removeValue(forKey: stageID) }
            overflow -= removable
            sessions[key] = state
        }
    }
}

enum TaskRecapState: Equatable {
    case idle
    case loading
    case result(TaskRecapResult)
    case failed(String)
}

@MainActor final class TaskRecapStore: ObservableObject {
    static let shared = TaskRecapStore()

    @Published private var states: [String: TaskRecapState] = [:]
    @Published private var warnings: [String: String] = [:]
    private var cache: TaskRecapCache
    private let file: TaskRecapFile
    private var tasks: [String: Task<Void, Never>] = [:]
    typealias Summarizer = (ActivitySummaryConfiguration, String, TaskRecapInput, String) async throws -> TaskRecapResult
    private let summarize: Summarizer

    init(file: TaskRecapFile = .applicationFile(), summarize: Summarizer? = nil) {
        self.file = file
        cache = (try? file.load()) ?? TaskRecapCache()
        self.summarize = summarize ?? { configuration, apiKey, input, language in
            try await TaskRecapClient().summarize(configuration: configuration, apiKey: apiKey,
                                                   input: input, language: language)
        }
    }

    func state(for key: String) -> TaskRecapState {
        states[key] ?? cache.result(for: key).map(TaskRecapState.result) ?? .idle
    }

    func warning(for key: String) -> String? { warnings[key] }

    func generate(key: String, force: Bool = false,
                  messages: @escaping @MainActor () async throws -> [KimiMessage],
                  settings: ActivitySummarySettings) {
        guard tasks[key] == nil else { return }
        if !force, let result = cache.result(for: key) {
            states[key] = .result(result)
            return
        }
        let configuration = settings.configuration
        let settingsRevision = settings.revision
        guard configuration.enabled, configuration.isValid else {
            states[key] = .failed(ActivitySummaryError.configuration.localizedDescription)
            return
        }
        states[key] = .loading
        warnings[key] = nil
        tasks[key] = Task { [weak self, weak settings] in
            guard let self, let settings else { return }
            defer { self.tasks[key] = nil }
            do {
                let history = try await messages()
                try Task.checkCancellation()
                guard settings.revision == settingsRevision,
                      let input = TaskRecapInput.make(messages: history,
                                                      includeToolOutput: configuration.includeToolOutput) else {
                    throw CancellationError()
                }
                let apiKey = try await settings.apiKey()
                try Task.checkCancellation()
                guard settings.revision == settingsRevision else { throw CancellationError() }
                let result = try await summarize(configuration, apiKey, input, AppLanguage.current.localization)
                try Task.checkCancellation()
                guard settings.revision == settingsRevision else { throw CancellationError() }
                cache.store(result, for: key)
                states[key] = .result(result)
                let snapshot = cache
                file.save(snapshot) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard let self, case .result(let current) = self.state(for: key), current == result else { return }
                        self.warnings[key] = L("Recap 已生成，但无法保存到本机：\(error)")
                    }
                }
            } catch is CancellationError {
                if case .loading = state(for: key) { states[key] = .idle }
            } catch {
                states[key] = .failed(error.localizedDescription)
            }
        }
    }
}
