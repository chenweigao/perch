import Foundation

/// A request the agent is blocked on, in one line of the agent's own words.
public struct TurnRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case approval, question }
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }

    /// Kimi: the first pending approval's action, else the first question.
    public static func kimi(approvals: [KimiApproval], questions: [KimiQuestion]) -> TurnRequest? {
        if let approval = approvals.first, let text = line(approval.action) ?? line(approval.toolName) {
            return TurnRequest(kind: .approval, text: text)
        }
        if let item = questions.first?.questions.first, let text = line(item.question) {
            return TurnRequest(kind: .question, text: text)
        }
        return nil
    }

    /// Native bridges: AskUserQuestion's first question, else the first
    /// interaction's title, question or message (the task panel's order).
    public static func native(_ interactions: [JSONValue]) -> TurnRequest? {
        guard let request = interactions.first else { return nil }
        if request["name"].string == "AskUserQuestion",
           let text = request["input"]["questions"].array.lazy.compactMap({ $0["question"].string.flatMap(line) }).first {
            return TurnRequest(kind: .question, text: text)
        }
        if let text = request["title"].string.flatMap(line) { return TurnRequest(kind: .approval, text: text) }
        if let text = request["question"].string.flatMap(line) { return TurnRequest(kind: .question, text: text) }
        if let text = request["message"].string.flatMap(line) { return TurnRequest(kind: .approval, text: text) }
        return nil
    }

    /// The first non-empty line, capped so a pasted command cannot fill the status line's tooltip.
    static func line(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
}

/// What the status line says about the latest turn. It answers three questions
/// only: is it alive, what is it doing, what does it need from the reader.
/// Details (plan, edits by file, timing, subagents) live in the task panel.
/// A pure value of the turn's activity, clock and connection, so every state is
/// testable without a view.
public struct TurnStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The connection dropped; what shows is the last state received.
        case offline
        /// The agent waits for a confirmation or an answer.
        case waiting
        case stopping
        case running
        /// The latest turn failed (`SessionTurn.failed`).
        case failed
        /// The turn ended with tool results nobody confirmed.
        case review
        /// The turn ended cleanly while this client watched it run (it has a
        /// clock), until the reader moves on.
        case done
        /// Not running, with plan steps left.
        case plan
        /// Nothing to say: the line takes no space.
        case hidden
    }

    /// Where a running headline comes from, most specific first.
    public enum Source: Equatable, Sendable { case step, narrative, description, phase }

    public struct Progress: Equatable, Sendable {
        public let done: Int
        public let total: Int
    }

    /// This turn's outcome: its edit churn and how long it took.
    public struct Result: Equatable, Sendable {
        public let files: Int
        public let additions: Int
        public let deletions: Int
        /// nil until the turn's end time arrives.
        public let duration: TimeInterval?
        /// The client only saw part of the turn, so the duration is a lower bound.
        public let observedOnly: Bool
    }

    public let state: State
    /// Localized, one line.
    public let headline: String
    public let source: Source?
    /// Secondary text after the headline: the running tool's target, a
    /// suspected stall, or how many requests wait.
    public let detail: String?
    public let progress: Progress?
    /// Uncertain tool results: a count while running, the subject once ended.
    public let attention: Int
    public let result: Result?
    /// A suspected stall, in whole minutes without progress.
    public let stalledMinutes: Int?

    /// Running and a clean end carry the Perch mark; every other state names itself.
    public var symbol: String? {
        switch state {
        case .offline: return "wifi.exclamationmark"
        case .waiting: return "hand.raised"
        case .stopping: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        case .review: return "exclamationmark.circle"
        case .plan: return "checklist"
        case .running, .done, .hidden: return nil
        }
    }
    /// A lost connection and a pending decision stop progress and own the tone.
    public var isBlocking: Bool { state == .offline || state == .waiting }
    public var needsReader: Bool { isBlocking || state == .failed || state == .review }

    /// Running headlines longer than this come from a whole progress reply;
    /// the task panel shows them instead.
    public static let narrativeLimit = 48

    /// `turn` comes from the same constructors the sidebar and notifications
    /// use (`SessionTurn(kimi:)`, `SessionTurn(native:)`), so its precedence of
    /// waiting, running, failed and finished is theirs. `pendingCount` only sizes
    /// the waiting line. `locale` is the view's environment locale, so the line
    /// follows a language switch in the same update as the SwiftUI labels around it.
    public init(activity: ConversationActivity, turn: SessionTurn, online: Bool = true, pendingCount: Int = 0,
                request: TurnRequest? = nil, timing: ConversationTiming? = nil, narrativeHeadline: String? = nil,
                stalledMinutes: Int? = nil, resultDismissed: Bool = false,
                locale: Locale = AppLanguage.current.resolvedLocale) {
        func L(_ value: String.LocalizationValue) -> String { WorkbenchCore.L(value, locale: locale) }
        func L(key: String) -> String { WorkbenchCore.L(String.LocalizationValue(key), locale: locale) }
        progress = activity.todos.isEmpty ? nil : Progress(done: activity.completedSteps, total: activity.todos.count)
        let uncertain = activity.attentionTools.count
        var source: Source?, detail: String?, result: Result?, attention = 0, stalled: Int?
        let phase = turn.state
        if !online {
            state = .offline
            headline = L(key: activity.title)
        } else if phase == .waiting {
            state = .waiting
            if let request {
                headline = request.kind == .question ? L("需要你回答：\(request.text)") : L("需要你确认：\(request.text)")
                if pendingCount > 1 { detail = L("共 \(pendingCount) 项") }
            } else if pendingCount > 0 {
                headline = L("等待你确认 · \(pendingCount) 项")
            } else {
                headline = L("等你处理")
            }
        } else if activity.isStopping {
            state = .stopping
            headline = L(key: activity.title)
        } else if phase == .running {
            state = .running
            attention = uncertain
            let narrative = narrativeHeadline?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let step = activity.currentStep {
                headline = step; source = .step
            } else if let narrative, !narrative.isEmpty, narrative.count <= Self.narrativeLimit {
                headline = narrative; source = .narrative
            } else if let description = activity.operationDescription {
                headline = description; source = .description
            } else {
                headline = L(key: activity.title); source = .phase
            }
            if let stalledMinutes {
                stalled = stalledMinutes
                detail = L("\(stalledMinutes) 分钟没有新进展")
            } else if source != .description, let tool = activity.activeTools.first {
                // A tool's own description already says what it touches.
                let target = ToolPresentation.compactTarget(tool)
                if !target.isEmpty && target != tool.name && target != headline { detail = target }
            }
        } else if phase == .failed {
            state = .failed
            headline = L("本轮失败")
        } else if uncertain > 0 {
            state = .review
            attention = uncertain
            headline = L("完成 · \(uncertain) 项需要你看一下")
        } else if let timing, !resultDismissed {
            // A native bridge reports the run state before the turn's end time;
            // the line stays put and the duration follows.
            state = .done
            headline = L("完成")
            result = Result(files: activity.edits?.perFile.count ?? 0,
                            additions: activity.edits?.total.additions ?? 0,
                            deletions: activity.edits?.total.deletions ?? 0,
                            duration: timing.endedAt.map(timing.elapsed(at:)), observedOnly: timing.observedOnly)
        } else if progress != nil {
            state = .plan
            headline = L(key: "Plan remaining")
        } else {
            state = .hidden
            headline = ""
        }
        self.source = source
        self.detail = detail
        self.result = result
        self.attention = attention
        self.stalledMinutes = stalled
    }

    // MARK: Stalls

    /// A turn is suspected stuck after this long without progress. A running
    /// tool (a build, a test suite) may legitimately stay quiet for longer.
    public static func stallThreshold(toolRunning: Bool) -> TimeInterval { toolRunning ? 600 : 180 }

    /// Whole minutes without progress once past the threshold; nil before it.
    public static func stalledMinutes(quietFor interval: TimeInterval, toolRunning: Bool) -> Int? {
        interval >= stallThreshold(toolRunning: toolRunning) ? Int(interval / 60) : nil
    }

    // MARK: Clock

    /// The line's clock: seconds for the first minute, then whole minutes, so
    /// a long turn does not tick at the edge of the reader's eye.
    public static func clock(_ interval: TimeInterval, chinese: Bool) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600, minutes = seconds / 60 % 60
        // The caller picks the language from its locale; both branches are output, not keys.
        if chinese {
            if hours > 0 { return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时" } // l10n-ignore
            return seconds < 60 ? "\(seconds)秒" : "\(minutes)分" // l10n-ignore
        }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return seconds < 60 ? "\(seconds)s" : "\(minutes)m"
    }

    /// Seconds until `clock` would read differently.
    public static func nextClockChange(after interval: TimeInterval) -> TimeInterval {
        let elapsed = max(0, interval)
        if elapsed < 60 { return 1 - elapsed.truncatingRemainder(dividingBy: 1) }
        return 60 - elapsed.truncatingRemainder(dividingBy: 60)
    }
}
