import Foundation

public struct ProjectBrief: Codable, Equatable, Sendable {
    public var goal = ""
    public var nextStep = ""
    public var seenAt: Double = 0
    public init() {}
}

public enum EvidenceState: String, Codable, CaseIterable, Sendable {
    case unverified, passed, failed
    public var title: String { switch self { case .unverified: return L("未验证"); case .passed: return L("通过"); case .failed: return L("失败") } }
}

public struct DeliveryRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var project: SidebarProjectLocation
    public var title: String
    public var source: SessionReference?
    public var revision = ""
    public var evidence = ""
    public var validation: EvidenceState = .unverified
    public var accepted = false
    public var acceptedRevision: String?
    public var acceptanceCurrent: Bool {
        accepted && !revision.isEmpty && acceptedRevision == revision && (snapshot == nil || evidenceMatchesHead)
    }
    public var pullRequest = ""
    public var snapshot: PullRequestSnapshot?
    public var updatedAt = Date().timeIntervalSince1970
    public init(project: SidebarProjectLocation, title: String, source: SessionReference? = nil) {
        self.project = project; self.title = title; self.source = source
    }
    public var evidenceMatchesHead: Bool { !revision.isEmpty && snapshot?.head == revision }
}

public struct PullRequestSnapshot: Codable, Equatable, Sendable {
    public let url: String
    public let state: String
    public let head: String
    public let checks: [Check]
    public var fetchedAt: Double = Date().timeIntervalSince1970
    public struct Check: Codable, Equatable, Sendable {
        public let name: String
        public let state: String
    }
    public var ciSummary: String {
        guard !checks.isEmpty else { return L("无 CI 记录") }
        if checks.contains(where: { ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"].contains($0.state) }) { return L("CI 未通过") }
        if checks.allSatisfy({ $0.state == "SUCCESS" }) { return L("CI 通过") }
        if checks.allSatisfy({ ["SUCCESS", "NEUTRAL", "SKIPPED"].contains($0.state) }) { return L("CI 已结束") }
        return L("CI 进行中或状态未知")
    }
    public static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        struct Payload: Decodable {
            let url: String; let state: String; let headRefOid: String; let statusCheckRollup: [Status]?
            struct Status: Decodable { let name: String?; let context: String?; let status: String?; let conclusion: String?; let state: String? }
        }
        let raw = try JSONDecoder().decode(Payload.self, from: data)
        return Self(url: raw.url, state: raw.state, head: raw.headRefOid, checks: (raw.statusCheckRollup ?? []).map {
            Check(name: $0.name ?? $0.context ?? "CI", state: ($0.conclusion?.isEmpty == false ? $0.conclusion : nil) ?? $0.state ?? $0.status ?? "UNKNOWN")
        }, fetchedAt: now.timeIntervalSince1970)
    }
    public static func command(directory: String, url: String) throws -> String {
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host == "github.com",
              parsed.pathComponents.count == 5, parsed.pathComponents[3] == "pull",
              Int(parsed.pathComponents[4]) != nil else { throw WorkbenchError(L("请输入 GitHub PR 的完整 HTTPS 地址。")) }
        return "cd " + SSHCommand.quote(directory) + " && gh pr view " + SSHCommand.quote(url)
            + " --json url,state,headRefOid,statusCheckRollup"
    }
}

public enum FollowUpTrigger: String, Codable, CaseIterable, Sendable {
    case time, nextResult, inactivity
    public var title: String { switch self { case .time: return L("指定时间后发送"); case .nextResult: return L("有新结果后发送"); case .inactivity: return L("长时间无更新时提醒") } }
}
public enum FollowUpStatus: String, Codable, Sendable {
    case pending, queued, notified, cancelled, needsReview
    public var title: String { switch self { case .pending: return L("等待触发"); case .queued: return L("已加入发送队列"); case .notified: return L("需要检查"); case .cancelled: return L("已取消"); case .needsReview: return L("请检查发送状态") } }
}
public struct FollowUpRule: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public let session: SessionReference
    public let title: String
    public var trigger: FollowUpTrigger
    public var dueAt: Double
    public var idleMinutes: Int
    public var prompt: String
    public var status: FollowUpStatus = .pending
    public var baselineUpdate: Double
    public var createdAt: Double
    public var note = ""
    public var messageID: String { "perch-followup-\(id.uuidString)" }
    public init(session: WorkspaceSession, trigger: FollowUpTrigger, dueAt: Date, idleMinutes: Int, prompt: String, now: Date = Date()) {
        self.session = session.reference; title = session.title; self.trigger = trigger
        self.dueAt = dueAt.timeIntervalSince1970; self.idleMinutes = idleMinutes; self.prompt = prompt
        baselineUpdate = session.updatedAt; createdAt = now.timeIntervalSince1970
    }
    public func isDue(session item: WorkspaceSession?, now: Date) -> Bool {
        guard status == .pending, let item, item.reference == session, item.online, !item.archived else { return false }
        let time = now.timeIntervalSince1970
        switch trigger {
        case .time: return time >= dueAt && item.section != .attention
        case .nextResult: return item.section == .review && item.updatedAt > baselineUpdate
        case .inactivity: return item.section == .running && time - max(createdAt, item.updatedAt) >= Double(idleMinutes * 60)
        }
    }
}
