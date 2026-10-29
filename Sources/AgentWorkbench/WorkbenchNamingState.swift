import Foundation
import Observation
import os
import WorkbenchCore

/// Naming failures were invisible, which made "it did not fire" undiagnosable.
/// Log attempt/success/failure only; the skip guards run per snapshot and are
/// too hot to log. No excerpts or credentials go into the log.
let namingLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.agentworkbench.mac", category: "session-naming")

/// Owns naming attempts, progress and errors; workspace mutation remains with
/// the coordinator and is revalidated against live inputs after the request.
@MainActor @Observable
final class WorkbenchNamingState {
    /// Session id → settings revision of the one naming attempt. A saved
    /// configuration change allows exactly one retry per session.
    @ObservationIgnored private var namingAttempts: [String: Int] = [:]
    private(set) var namingInProgress: Set<String> = []
    private(set) var namingErrors: [String: String] = [:]
    /// The request boundary is replaceable by isolated lifecycle checks.
    @ObservationIgnored var sessionNamer: (ActivitySummaryConfiguration, String, String) async throws -> String = { configuration, excerpt, language in
        let settings = ActivitySummarySettings.shared
        let key = try await settings.apiKey()
        try Task.checkCancellation()
        guard settings.configuration == configuration else { throw CancellationError() }
        return try await SessionNamingClient().name(configuration: configuration, apiKey: key,
                                                     excerpt: excerpt, language: language)
    }

    func consider(reference: SessionReference, remoteTitle: String, messages: [KimiMessage],
                  busy: Bool, turnCompleted: Bool, hasOlder: Bool,
                  mayName: @escaping () -> Bool, remoteTitleNow: @escaping () -> String?,
                  loadHistory: () -> Void, apply: @escaping (String) -> Void) {
        let settings = ActivitySummarySettings.shared
        let configuration = settings.configuration
        guard configuration.enabled, configuration.nameSessions, configuration.isValid else { return }
        guard mayName(),
              namingAttempts[reference.id] != settings.revision else { return }
        if reference.kind == .kimi { guard !busy, turnCompleted else { return } }
        if hasOlder { loadHistory(); return }
        guard let excerpt = SessionNaming.excerpt(from: messages, hasOlder: hasOlder),
              SessionNaming.isPlaceholder(remoteTitle, kind: reference.kind, firstUserText: excerpt) else { return }
        let revision = settings.revision
        namingAttempts[reference.id] = revision
        namingInProgress.insert(reference.id)
        namingErrors.removeValue(forKey: reference.id)
        namingLog.info("attempt \(reference.id, privacy: .public)")
        Task {
            defer { if namingAttempts[reference.id] == revision { namingInProgress.remove(reference.id) } }
            do {
                guard settings.revision == revision else { return }
                let name = try await sessionNamer(configuration, excerpt, AppLanguage.current.localization)
                guard settings.revision == revision, mayName(),
                      let latestTitle = remoteTitleNow(),
                      SessionNaming.isPlaceholder(latestTitle, kind: reference.kind, firstUserText: excerpt) else { return }
                apply(name)
                namingLog.info("named \(reference.id, privacy: .public)")
            } catch {
                if settings.revision == revision { namingErrors[reference.id] = error.localizedDescription }
                namingLog.error("failed \(reference.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
