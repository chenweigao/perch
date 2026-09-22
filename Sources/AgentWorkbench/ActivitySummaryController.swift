import Foundation
import SwiftUI
import WorkbenchCore

/// Owned by the selected transcript. One request at a time; only new completed
/// activity schedules work. Disabling, changing settings or leaving cancels it.
@MainActor final class ActivitySummaryController: ObservableObject {
    struct Summary { let text: String; let batch: ActivitySummaryBatch }
    @Published private(set) var summaries: [String: Summary] = [:]
    private var attempts: [String: ActivitySummaryBatch] = [:]
    private var pending: ActivitySummaryBatch?
    private var worker: Task<Void, Never>?
    private var lastRequest = Date.distantPast
    private var session = ""
    private var configurationRevision = -1
    private var observedRunning = false
    private var following = true
    private var deferred: [String: Summary] = [:]
    private var generation = 0

    func observe(session: String, batch: ActivitySummaryBatch?, running: Bool, online: Bool, following: Bool,
                 settings: ActivitySummarySettings) {
        if self.session != session || configurationRevision != settings.revision {
            cancel(); summaries = [:]; deferred = [:]; attempts = [:]; observedRunning = false
            self.session = session; configurationRevision = settings.revision
        }
        guard settings.configuration.enabled, online else { cancel(); return }
        self.following = following
        if following && !deferred.isEmpty {
            summaries.merge(deferred) { _, latest in latest }
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
                    let text = try await ActivitySummaryClient().summarize(configuration: config, apiKey: key,
                        batch: next, language: AppLanguage.current.localization)
                    guard !Task.isCancelled, generation == version else { return }
                    // A newer completed batch can supersede this response while it runs.
                    if pending?.groupID != next.groupID || pending?.records == next.records {
                        let summary = Summary(text: text, batch: next)
                        if self.following { summaries[next.groupID] = summary }
                        else { deferred[next.groupID] = summary }
                    }
                } catch {
                    // Rules remain visible. A failure is not retried without new events.
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
