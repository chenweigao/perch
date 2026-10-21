import Foundation
import Observation
import WorkbenchCore

/// The subagent transcript sheet that is open: one roster entry of one session,
/// named by the key its transcript is read under (the entry id or any alias).
struct NativeSubagentSubject: Identifiable, Hashable, Sendable {
    let sessionID: String
    let key: String
    var id: NativeSubagentSubject { self }

    /// `GET` reads this transcript; `POST` with `/stop` stops the subagent.
    var path: String { NativeSubagentRoute.path(session: sessionID, key: key) }
}

enum NativeSubagentRoute {
    /// Unreserved characters only, so a key can never add a path segment or a query.
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static func path(session: String, key: String) -> String {
        "/sessions/\(session)/subagents/\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)"
    }
}

/// Seconds between the follow reads of an open subagent transcript.
struct NativeSubagentCadence: Sendable {
    /// While the subagent is queued or running.
    var live: Double = 1
    /// Once it finished, and while its state is not known yet.
    var idle: Double = 4
    /// The longest single wait, so an older page asked for mid-pause starts promptly.
    var slice: Double = 0.1
}

extension NativeAgentSnapshot {
    /// Agent/Task and agent/spawnAgent tool cards offer their subagent's own
    /// process: the bridge reports a roster for a runtime whose subagents it
    /// records, Claude tasks (protocol 7) and Codex child threads (protocol 9).
    /// An older bridge reports no roster at all.
    var opensSubagents: Bool { subagents != nil && (provider == .claude || provider == .codex) }
}

/// What the open subagent sheet and the roster's stop buttons draw. The
/// connection runs the reads and the stop requests; each result passes the
/// identity checks here before it lands, so a late answer for a closed sheet,
/// a replaced follower or an older stop attempt is dropped. Closing the sheet
/// or disconnecting ends the reads; nothing here ever stops a subagent.
@MainActor @Observable
final class NativeSubagentState {
    /// The open sheet; nil when none is.
    private(set) var presented: NativeSubagentSubject?
    /// The presented subject's transcript as last read.
    private(set) var transcript: NativeSubagentTranscript?
    /// Nothing of the presented subject has been read yet.
    private(set) var loading = false
    /// An older page was asked for and has not landed.
    private(set) var loadingOlder = false
    /// The last read of the presented subject failed; the next success clears it.
    private(set) var error: String?
    /// Entries whose stop was asked for and has no outcome yet, by entry id.
    private(set) var stopping: Set<String> = []
    /// Why the last stop request of an entry failed, by entry id.
    private(set) var stopErrors: [String: String] = [:]

    @ObservationIgnored var cadence = NativeSubagentCadence()
    /// How the follow reads wait. Connection checks substitute a manual clock.
    @ObservationIgnored var sleep: @MainActor (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    /// A stop without an outcome by then offers stopping again.
    @ObservationIgnored var stopTimeout: Double = 20

    @ObservationIgnored private var follower: UUID?
    @ObservationIgnored private var olderRequested = false
    @ObservationIgnored private var attempts: [String: StopAttempt] = [:]
    private struct StopAttempt {
        let id: UUID
        let session: String
        /// When the bridge accepted the request; reads issued after it show the outcome.
        var acceptedAt: Date?
    }

    // MARK: Sheet

    /// Opens the sheet of `subject`, or closes the open one for nil. A different
    /// subject starts from nothing, and the old one's reads no longer land.
    func present(_ subject: NativeSubagentSubject?) {
        guard subject != presented else { return }
        presented = subject
        follower = nil; olderRequested = false
        if transcript != nil { transcript = nil }
        if loading { loading = false }
        if loadingOlder { loadingOlder = false }
        if error != nil { error = nil }
    }

    /// Starts a follower of the presented subject and returns its token, or nil
    /// for a subject that is not presented. A newer follower replaces an older
    /// one, so a single sequence of reads ever applies to one transcript.
    func beginFollowing(_ subject: NativeSubagentSubject) -> UUID? {
        guard presented == subject else { return nil }
        let token = UUID()
        follower = token
        if transcript?.key != subject.key { transcript = NativeSubagentTranscript(key: subject.key) }
        // Whatever an earlier follower had asked for or had in flight is gone with it.
        olderRequested = false
        if loadingOlder { loadingOlder = false }
        let unread = transcript?.epoch == nil && transcript?.messages.isEmpty != false
        if loading != unread { loading = unread }
        return token
    }

    func isFollowing(_ token: UUID) -> Bool { presented != nil && follower == token }

    /// The query of the next follow read: a full window first, then deltas.
    func followQuery(_ token: UUID) -> String {
        guard isFollowing(token) else { return "" }
        return transcript?.followQuery ?? ""
    }

    /// Asks the follower for the page before the held window. It is read after
    /// the read in flight, never next to it.
    func requestOlder() {
        guard presented != nil, transcript?.hasOlder == true, !loadingOlder else { return }
        olderRequested = true
        loadingOlder = true
    }

    /// Drops an older page that cannot be read now; asking again retries it.
    func cancelOlder() {
        olderRequested = false
        if loadingOlder { loadingOlder = false }
    }

    /// The older page `token` reads next, if one was asked for.
    func takeOlderQuery(_ token: UUID) -> String? {
        guard isFollowing(token), olderRequested else { return nil }
        olderRequested = false
        guard let query = transcript?.olderQuery() else {
            if loadingOlder { loadingOlder = false }
            return nil
        }
        return query
    }

    func apply(_ page: NativeSubagentPage, follower token: UUID) {
        guard isFollowing(token), var next = transcript else { return }
        if next.apply(page) { transcript = next }
        if loading { loading = false }
        if error != nil { error = nil }
    }

    func prepend(_ page: NativeSubagentPage, follower token: UUID) {
        guard isFollowing(token), var next = transcript else { return }
        if next.prepend(page) { transcript = next }
        if loadingOlder { loadingOlder = false }
        if error != nil { error = nil }
    }

    func fail(_ message: String, older: Bool, follower token: UUID) {
        guard isFollowing(token) else { return }
        if loading { loading = false }
        if older && loadingOlder { loadingOlder = false }
        if error != message { error = message }
    }

    /// Waits `seconds` before `token`'s next read, in short slices. An older-page
    /// request, a closed sheet or a newer follower ends the wait early.
    func pause(_ seconds: Double, follower token: UUID) async throws {
        let steps = max(1, Int((seconds / max(cadence.slice, 0.001)).rounded(.up)))
        for _ in 0..<steps {
            guard isFollowing(token), !olderRequested else { return }
            try await sleep(seconds / Double(steps))
        }
    }

    // MARK: Stop

    /// Marks `entry` as stopping and returns the attempt; nil while one is pending.
    func beginStop(_ entry: String, session: String) -> UUID? {
        guard !stopping.contains(entry) else { return nil }
        let attempt = UUID()
        attempts[entry] = StopAttempt(id: attempt, session: session)
        stopping.insert(entry)
        if stopErrors[entry] != nil { stopErrors[entry] = nil }
        return attempt
    }

    /// The bridge accepted the stop request and sent it to the worker.
    func acceptStop(_ entry: String, attempt: UUID, at time: Date = Date()) {
        guard attempts[entry]?.id == attempt else { return }
        attempts[entry]?.acceptedAt = time
    }

    /// The pending stop of `entry` reached the worker; only its outcome is missing.
    func isStopAccepted(_ entry: String) -> Bool { attempts[entry]?.acceptedAt != nil }

    /// The request itself failed; the row offers stopping again with the reason.
    func failStop(_ entry: String, attempt: UUID, message: String) {
        guard attempts[entry]?.id == attempt else { return }
        endStop(entry)
        stopErrors[entry] = message
    }

    /// No outcome in time: the row offers stopping again.
    func expireStop(_ entry: String, attempt: UUID) {
        guard attempts[entry]?.id == attempt else { return }
        endStop(entry)
    }

    /// Settles the pending stops of `session` against a roster read issued at
    /// `readAt`: an entry that finished or left the roster is done, and one the
    /// bridge reports a stop error for, in a read issued after the request was
    /// accepted, failed (its row then shows the bridge's error).
    func reconcileStops(_ roster: [NativeSubagent], session: String, readAt: Date) {
        for (key, attempt) in attempts where attempt.session == session {
            guard let entry = roster.first(where: { $0.matches(key) }), entry.status.isLive else {
                endStop(key)
                continue
            }
            if let accepted = attempt.acceptedAt, readAt >= accepted, !entry.stopRequested, entry.stopError != nil {
                endStop(key)
            }
        }
    }

    /// The stop failure a roster row shows: the request's own, else the one the
    /// bridge reports. Nothing while a stop is pending or once the entry finished.
    func stopError(for entry: NativeSubagent) -> String? {
        guard entry.status.isLive, !stopping.contains(entry.id) else { return nil }
        return stopErrors[entry.id] ?? entry.stopError
    }

    private func endStop(_ entry: String) {
        attempts[entry] = nil
        if stopping.contains(entry) { stopping.remove(entry) }
    }

    /// The connection was dropped or replaced: close the sheet and forget the
    /// stops in flight. The subagents themselves are untouched.
    func reset() {
        present(nil)
        attempts = [:]
        if !stopping.isEmpty { stopping = [] }
        if !stopErrors.isEmpty { stopErrors = [:] }
    }
}
