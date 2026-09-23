import Foundation
import SwiftUI
import WorkbenchCore

/// Owned by the selected transcript. One request at a time; only new completed
/// activity schedules work. Disabling, changing settings or leaving cancels it.
@MainActor final class ActivitySummaryController: ObservableObject {
    @Published private(set) var summaries: [String: String] = [:]
    private var attempts: [String: ActivitySummaryBatch] = [:]
    private var results: [String: ActivitySummaryResult] = [:]
    private var pending: ActivitySummaryBatch?
    private var worker: Task<Void, Never>?
    private var lastRequest = Date.distantPast
    private var session = ""
    private var configurationRevision = -1
    private var observedRunning = false
    private var following = true
    private var deferred: [String: String] = [:]
    private var generation = 0

    func observe(session: String, batch: ActivitySummaryBatch?, running: Bool, online: Bool, following: Bool,
                 settings: ActivitySummarySettings) {
        if self.session != session || configurationRevision != settings.revision {
            cancel()
            if !summaries.isEmpty { summaries = [:] }
            deferred = [:]; attempts = [:]; results = [:]; observedRunning = false
            self.session = session; configurationRevision = settings.revision
        }
        guard settings.configuration.enabled, online else { cancel(); return }
        self.following = following
        if following && !deferred.isEmpty {
            let changes = deferred.filter { summaries[$0.key] != $0.value }
            if !changes.isEmpty { summaries.merge(changes) { _, latest in latest } }
            deferred = [:]
        }
        if running { observedRunning = true }
        guard observedRunning, let batch, batch.shouldRequest(after: attempts[batch.groupID]) else { return }
        pending = batch
        guard worker == nil else { return }
        let config = settings.configuration
        let settingsVersion = settings.revision
        let version = generation
        worker = Task {
            defer { if generation == version { worker = nil } }
            while pending != nil && !Task.isCancelled {
                let delay = max(0, 15 - Date().timeIntervalSince(lastRequest))
                do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) } }
                catch { return }
                guard !Task.isCancelled, settings.configuration.enabled,
                      settings.revision == settingsVersion, let next = pending else { return }
                pending = nil
                guard next.shouldRequest(after: attempts[next.groupID]) else { continue }
                attempts[next.groupID] = next
                lastRequest = Date()
                do {
                    let key = try settings.apiKey()
                    let previous = results[next.groupID]
                    let result = try await ActivitySummaryClient().summarize(configuration: config, apiKey: key,
                        batch: next, language: AppLanguage.current.localization, previous: previous)
                    guard !Task.isCancelled, generation == version else { return }
                    // A newer completed batch can supersede this response while it runs.
                    if pending?.groupID != next.groupID || pending?.records == next.records {
                        guard previous == nil || result.shouldUpdate else { continue }
                        results[next.groupID] = result
                        if self.following {
                            // Publishing identical text would rerun transcript projection
                            // and layout even though no row's presentation changed.
                            if summaries[next.groupID] != result.summary { summaries[next.groupID] = result.summary }
                        } else { deferred[next.groupID] = result.summary }
                    }
                } catch {
                    // Activity stays visible. A failure is not retried without new events.
                    if Task.isCancelled { return }
                }
            }
        }
    }
    func cancel() {
        generation += 1
        worker?.cancel(); worker = nil; pending = nil
    }
}
