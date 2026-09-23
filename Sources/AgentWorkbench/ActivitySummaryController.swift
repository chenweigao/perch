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
    private var lastRequest = Date.distantPast
    private var generation = 0

    func narrative(session: String) -> ActivityNarrative? { sessions[session]?.current }
    func row(session: String, entryID: String) -> ActivityNarrativeRow? { sessions[session]?.rows[entryID] }
    func failure(session: String) -> ActivityNarrativeFailure? { sessions[session]?.failure }
    func canRetry(session: String) -> Bool { sessions[session]?.retryBatch != nil }

    func observe(session: String, snapshot: ActivityNarrativeSnapshot, batch: ActivitySummaryBatch?,
                 running: Bool, online: Bool, following: Bool,
                 settings: ActivitySummarySettings) {
        if let activeSession, activeSession != session { cancelRequest() }
        var state = sessions[session] ?? SessionState()
        state.touched = Date()
        state.base = snapshot
        if running { state.observedRunning = true }
        if state.settingsRevision != settings.revision {
            if activeSession == session { cancelRequest() }
            if pending?.session == session { pending = nil }
            state.settingsRevision = settings.revision
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
            if snapshot.current?.source == .provider || snapshot.current?.source == .commentary {
                if activeSession == session { cancelRequest() }
                if pending?.session == session { pending = nil }
            }
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
                }
            }
            while !Task.isCancelled, let next = self.pending {
                self.pending = nil
                self.activeSession = next.session
                let delay = max(0, 8 - Date().timeIntervalSince(self.lastRequest))
                do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) } }
                catch { return }
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
                    let result = try await ActivitySummaryClient().summarize(
                        configuration: next.configuration, apiKey: try settings.apiKey(),
                        batch: next.batch, language: AppLanguage.current.localization,
                        previous: state.results[next.batch.groupID])
                    guard !Task.isCancelled, self.generation == version,
                          var current = self.sessions[next.session] else { return }
                    if current.base.stages.contains(where: { $0.narrative.stageID == next.batch.groupID
                        && $0.narrative.source == .local }) {
                        if current.results[next.batch.groupID] == nil || result.shouldUpdate {
                            current.results[next.batch.groupID] = result
                        }
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
                    if Task.isCancelled { return }
                    guard var current = self.sessions[next.session] else { continue }
                    current.failure = ActivityNarrativeFailure(message: error.localizedDescription, date: Date())
                    current.retryBatch = next.batch
                    self.sessions[next.session] = current
                }
            }
        }
    }

    private func cancelRequest() {
        generation += 1
        worker?.cancel()
        worker = nil
        activeSession = nil
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
