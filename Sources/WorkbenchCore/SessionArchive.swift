import Foundation

/// Why a session stays out of the batch. Idle is not completion: a session only
/// becomes a candidate when its runtime reports a finished turn the user has seen.
public enum ArchiveBlock: String, Sendable, Equatable {
    case alreadyArchived, offline, running, pendingInteraction, failed, stopped
    case starred, neverRan, unreviewed, queued, noCompletionSignal

    public var reason: String {
        switch self {
        case .alreadyArchived: return "已在归档中"
        case .offline: return "未连接，状态未知"
        case .running: return "正在运行"
        case .pendingInteraction: return "等你处理"
        case .failed: return "上一轮出错"
        case .stopped: return "已主动停止"
        case .starred: return "已置顶"
        case .neverRan: return "从未运行"
        case .unreviewed: return "结果还没查看"
        case .queued: return "还有待发消息"
        case .noCompletionSignal: return "没有完成语义"
        }
    }
}

/// The state a batch decision is made from. `fingerprint` is whatever the source
/// already increments per change (pane revision, completed count, updatedAt), so a
/// session that moves between planning and commit can be detected without new APIs.
public struct ArchiveSubject: Equatable, Sendable {
    public let reference: SessionReference
    public let fingerprint: String
    public let archived: Bool
    public let online: Bool
    public let busy: Bool
    public let pendingInteraction: Bool
    public let failed: Bool
    public let stopped: Bool
    public let starred: Bool
    public let completedTurns: Int
    public let reviewed: Bool
    public let queuedMessages: Int
    public let hasCompletionSignal: Bool

    public init(reference: SessionReference, fingerprint: String, archived: Bool = false, online: Bool = true,
                busy: Bool = false, pendingInteraction: Bool = false, failed: Bool = false, stopped: Bool = false,
                starred: Bool = false, completedTurns: Int = 1, reviewed: Bool = true, queuedMessages: Int = 0,
                hasCompletionSignal: Bool = true) {
        self.reference = reference; self.fingerprint = fingerprint; self.archived = archived; self.online = online
        self.busy = busy; self.pendingInteraction = pendingInteraction; self.failed = failed; self.stopped = stopped
        self.starred = starred; self.completedTurns = completedTurns; self.reviewed = reviewed
        self.queuedMessages = queuedMessages; self.hasCompletionSignal = hasCompletionSignal
    }

    public var block: ArchiveBlock? {
        if archived { return .alreadyArchived }
        if !online { return .offline }
        if busy { return .running }
        if pendingInteraction { return .pendingInteraction }
        if failed { return .failed }
        if stopped { return .stopped }
        if starred { return .starred }
        if !hasCompletionSignal { return .noCompletionSignal }
        if completedTurns <= 0 { return .neverRan }
        if !reviewed { return .unreviewed }
        if queuedMessages > 0 { return .queued }
        return nil
    }
    public var isEligible: Bool { block == nil }
}

public struct ArchiveCandidate: Equatable, Sendable, Identifiable {
    public let reference: SessionReference
    public let fingerprint: String
    public var id: String { reference.id }
    public init(reference: SessionReference, fingerprint: String) {
        self.reference = reference; self.fingerprint = fingerprint
    }
    public init(_ subject: ArchiveSubject) {
        reference = subject.reference; fingerprint = subject.fingerprint
    }
}

public enum ArchiveSkip: Equatable, Sendable {
    case disappeared, changed, blocked(ArchiveBlock)
    public var reason: String {
        switch self {
        case .disappeared: return "会话已不存在"
        case .changed: return "开始前状态已变化"
        case .blocked(let block): return block.reason
        }
    }
}

public struct ArchiveBlocked: Equatable, Sendable {
    public let reference: SessionReference
    public let block: ArchiveBlock
}

/// Candidates locked at click time. Nothing here re-reads live state; the run
/// re-validates every item immediately before committing it.
public struct BatchArchivePlan: Equatable, Sendable {
    public let candidates: [ArchiveCandidate]
    public let blocked: [ArchiveBlocked]
    public let concurrencyLimit: Int

    public init(subjects: [ArchiveSubject], concurrencyLimit: Int = 4) {
        var eligible: [ArchiveCandidate] = []
        var rejected: [ArchiveBlocked] = []
        for subject in subjects {
            if let block = subject.block { rejected.append(ArchiveBlocked(reference: subject.reference, block: block)) }
            else { eligible.append(ArchiveCandidate(subject)) }
        }
        candidates = eligible; blocked = rejected
        self.concurrencyLimit = max(1, concurrencyLimit)
    }
    public init(candidates: [ArchiveCandidate], concurrencyLimit: Int = 4) {
        self.candidates = candidates; blocked = []
        self.concurrencyLimit = max(1, concurrencyLimit)
    }
    public var count: Int { candidates.count }
    public var isEmpty: Bool { candidates.isEmpty }
}

public struct ArchiveSkipped: Equatable, Sendable {
    public let candidate: ArchiveCandidate
    public let skip: ArchiveSkip
}
public struct ArchiveFailure: Equatable, Sendable {
    public let candidate: ArchiveCandidate
    public let message: String
}

/// Bounded, re-validating execution of one batch. A single value owns the whole
/// outcome so undo can restore exactly the set that was actually archived.
public struct BatchArchiveRun: Equatable, Sendable {
    public let plan: BatchArchivePlan
    private var queue: [ArchiveCandidate]
    public private(set) var inFlight: Set<String> = []
    public private(set) var archived: [ArchiveCandidate] = []
    public private(set) var skipped: [ArchiveSkipped] = []
    public private(set) var failures: [ArchiveFailure] = []
    public private(set) var undoFailures: [ArchiveFailure] = []
    public private(set) var restoredCount = 0

    public init(plan: BatchArchivePlan) { self.plan = plan; queue = plan.candidates }

    public mutating func nextBatch() -> [ArchiveCandidate] {
        var started: [ArchiveCandidate] = []
        while inFlight.count < plan.concurrencyLimit, !queue.isEmpty {
            let candidate = queue.removeFirst()
            guard inFlight.insert(candidate.id).inserted else { continue }
            started.append(candidate)
        }
        return started
    }

    /// The only place a commit is authorised. Returns the skip reason when the
    /// session changed after planning, so a just-started turn is never archived.
    public mutating func revalidate(_ candidate: ArchiveCandidate, against subject: ArchiveSubject?) -> ArchiveSkip? {
        guard let subject else { return .disappeared }
        if let block = subject.block { return .blocked(block) }
        if subject.fingerprint != candidate.fingerprint { return .changed }
        return nil
    }

    public mutating func succeed(_ candidate: ArchiveCandidate) {
        guard inFlight.remove(candidate.id) != nil else { return }
        archived.append(candidate)
    }
    public mutating func skip(_ candidate: ArchiveCandidate, _ skip: ArchiveSkip) {
        guard inFlight.remove(candidate.id) != nil else { return }
        skipped.append(ArchiveSkipped(candidate: candidate, skip: skip))
    }
    public mutating func fail(_ candidate: ArchiveCandidate, _ message: String) {
        guard inFlight.remove(candidate.id) != nil else { return }
        failures.append(ArchiveFailure(candidate: candidate, message: message))
    }

    public var isFinished: Bool { queue.isEmpty && inFlight.isEmpty }
    public var undoTargets: [SessionReference] { archived.map(\.reference) }
    public mutating func retryFailures() {
        guard isFinished else { return }
        queue = failures.map(\.candidate); failures = []
    }
    public mutating func beginUndo() { undoFailures = [] }
    public mutating func restored(_ reference: SessionReference) {
        guard let index = archived.firstIndex(where: { $0.reference == reference }) else { return }
        archived.remove(at: index); restoredCount += 1
    }
    public mutating func undoFailed(_ reference: SessionReference, _ message: String) {
        guard let candidate = archived.first(where: { $0.reference == reference }) else { return }
        undoFailures.append(ArchiveFailure(candidate: candidate, message: message))
    }
    public var retryPlan: BatchArchivePlan? {
        failures.isEmpty ? nil : BatchArchivePlan(candidates: failures.map(\.candidate), concurrencyLimit: plan.concurrencyLimit)
    }
    public var summary: String {
        var parts = ["已归档 \(archived.count)"]
        if !skipped.isEmpty { parts.append("跳过 \(skipped.count)") }
        if !failures.isEmpty { parts.append("失败 \(failures.count)") }
        if restoredCount > 0 { parts.append("已恢复 \(restoredCount)") }
        if !undoFailures.isEmpty { parts.append("恢复失败 \(undoFailures.count)") }
        return parts.joined(separator: " · ")
    }
}
