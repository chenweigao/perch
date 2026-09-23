import Foundation

public enum ActivityNarrativePhase: String, Codable, CaseIterable, Hashable, Sendable {
    case exploring, editing, validating, integrating, blocked, mixed

    public var label: String {
        switch self {
        case .exploring: return L("探索")
        case .editing: return L("修改")
        case .validating: return L("验证")
        case .integrating: return L("整合")
        case .blocked: return L("受阻")
        case .mixed: return L("推进")
        }
    }
}

public enum ActivityNarrativeSource: String, Codable, Sendable {
    case provider, commentary, external, local

    public var label: String {
        switch self {
        case .provider: return L("模型原生摘要")
        case .commentary: return L("Agent 进度")
        case .external: return L("外部摘要")
        case .local: return L("本地推断")
        }
    }
}

public enum ActivityNarrativeLifecycle: String, Codable, Sendable {
    case streaming, final
}

public struct ActivityNarrative: Equatable, Sendable {
    public let turnID: String
    public let stageID: String
    public let phase: ActivityNarrativePhase
    public let subject: String
    public let headline: String
    public let detail: String?
    public let source: ActivityNarrativeSource
    public let evidenceIDs: [String]
    public let lifecycle: ActivityNarrativeLifecycle
    public let revision: Int

    public init(turnID: String, stageID: String, phase: ActivityNarrativePhase,
                subject: String = "", headline: String, detail: String? = nil,
                source: ActivityNarrativeSource, evidenceIDs: [String] = [],
                lifecycle: ActivityNarrativeLifecycle, revision: Int = 0) {
        self.turnID = turnID
        self.stageID = stageID
        self.phase = phase
        self.subject = subject
        self.headline = headline
        self.detail = detail
        self.source = source
        self.evidenceIDs = evidenceIDs
        self.lifecycle = lifecycle
        self.revision = revision
    }
}

public struct ActivityNarrativeStage: Equatable, Sendable {
    public let narrative: ActivityNarrative
    public let entryIDs: [String]
    public let toolIDs: [String]
    public let closed: Bool
}

public struct ActivityNarrativeRow: Equatable, Sendable {
    public let narrative: ActivityNarrative
    public let isAnchor: Bool
    public let stageClosed: Bool

    public init(narrative: ActivityNarrative, isAnchor: Bool, stageClosed: Bool) {
        self.narrative = narrative
        self.isAnchor = isAnchor
        self.stageClosed = stageClosed
    }
}

public struct ActivityNarrativeSnapshot: Equatable, Sendable {
    public let turnID: String?
    public let stages: [ActivityNarrativeStage]
    public let entryStageIDs: [String: String]

    public init(turnID: String?, stages: [ActivityNarrativeStage], entryStageIDs: [String: String]) {
        self.turnID = turnID
        self.stages = stages
        self.entryStageIDs = entryStageIDs
    }

    public var current: ActivityNarrative? { stages.last?.narrative }
    public var rows: [String: ActivityNarrativeRow] {
        stages.reduce(into: [:]) { result, stage in
            for (index, entryID) in stage.entryIDs.enumerated() {
                result[entryID] = ActivityNarrativeRow(
                    narrative: stage.narrative, isAnchor: index == 0, stageClosed: stage.closed)
            }
        }
    }
    public func row(for entryID: String) -> ActivityNarrativeRow? { rows[entryID] }
    public func narrative(for entryID: String) -> ActivityNarrative? { row(for: entryID)?.narrative }

    public func applying(_ external: [String: ActivitySummaryResult]) -> Self {
        let updated = stages.map { stage -> ActivityNarrativeStage in
            guard stage.narrative.source == .local,
                  let result = external[stage.narrative.stageID], result.shouldUpdate else { return stage }
            let headline = Self.clean(result.summary)
            guard !headline.isEmpty else { return stage }
            let narrative = ActivityNarrative(
                turnID: stage.narrative.turnID, stageID: stage.narrative.stageID,
                phase: result.phase, subject: Self.clean(result.subject, limit: 80),
                headline: headline, detail: stage.narrative.detail, source: .external,
                evidenceIDs: result.evidenceIDs.filter(stage.toolIDs.contains),
                lifecycle: stage.closed ? .final : .streaming,
                revision: stage.narrative.revision + 1)
            return ActivityNarrativeStage(narrative: narrative, entryIDs: stage.entryIDs,
                                          toolIDs: stage.toolIDs, closed: stage.closed)
        }
        return Self(turnID: turnID, stages: updated, entryStageIDs: entryStageIDs)
    }

    fileprivate static func clean(_ value: String, limit: Int? = nil) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["### ", "## ", "# ", "**"] where text.hasPrefix(marker) {
            text.removeFirst(marker.count)
            if marker == "**" { text = text.replacingOccurrences(of: "**", with: "") }
            break
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ":：")))
        guard let limit, text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    fileprivate static func narrativeText(_ value: String) -> (headline: String, detail: String?) {
        let text = clean(value)
        for separator in ["：", ": "] {
            guard let range = text.range(of: separator) else { continue }
            let headline = clean(String(text[..<range.lowerBound]), limit: 80)
            let detail = clean(String(text[range.upperBound...]))
            if !headline.isEmpty, headline.count <= 48, !detail.isEmpty {
                return (headline, detail)
            }
        }
        return (text, nil)
    }
}

public enum ActivityNarrativeProjection {
    private struct Builder {
        var narrative: ActivityNarrative
        var entryIDs: [String] = []
        var toolIDs: [String] = []
    }

    public static func make(entries: [ConversationTimelineEntry], tools: [String: VisibleTool],
                            isRunning: Bool,
                            external: [String: ActivitySummaryResult] = [:]) -> ActivityNarrativeSnapshot {
        let boundary = entries.lastIndex { entry in
            entry.presentation == .message && entry.messages.first?.isUserPrompt == true
        }
        let turnID = boundary.flatMap { entries[$0].messages.first?.id }
        let currentEntries = boundary.map { Array(entries.dropFirst($0 + 1)) } ?? entries
        guard let turnID = turnID ?? currentEntries.first?.messages.first?.id else {
            return ActivityNarrativeSnapshot(turnID: nil, stages: [], entryStageIDs: [:])
        }

        var stages: [Builder] = []
        var entryStageIDs: [String: String] = [:]

        func phase(from text: String) -> ActivityNarrativePhase {
            let value = text.lowercased()
            if value.contains("fail") || value.contains("error") || value.contains("block")
                || value.contains("失败") || value.contains("错误") || value.contains("受阻") { return .blocked }
            if value.contains("test") || value.contains("build") || value.contains("lint") || value.contains("verify")
                || value.contains("测试") || value.contains("构建") || value.contains("验证") || value.contains("检查") { return .validating }
            if value.contains("edit") || value.contains("implement") || value.contains("write") || value.contains("fix")
                || value.contains("修改") || value.contains("实现") || value.contains("修复") || value.contains("编写") { return .editing }
            if value.contains("git") || value.contains("commit") || value.contains("merge") || value.contains("integrat")
                || value.contains("提交") || value.contains("合并") || value.contains("整合") || value.contains("冲突") { return .integrating }
            if value.contains("read") || value.contains("search") || value.contains("inspect") || value.contains("explor")
                || value.contains("读取") || value.contains("搜索") || value.contains("查看") || value.contains("分析") { return .exploring }
            return .mixed
        }

        func localHeadline(_ phase: ActivityNarrativePhase, target: String?) -> String {
            let cleanTarget = ActivityNarrativeSnapshot.clean(target ?? "", limit: 80)
            if cleanTarget.isEmpty {
                switch phase {
                case .exploring: return L("分析任务")
                case .editing: return L("修改实现")
                case .validating: return L("验证改动")
                case .integrating: return L("整合改动")
                case .blocked: return L("处理失败的操作")
                case .mixed: return L("推进任务")
                }
            }
            return "\(phase.label) \(cleanTarget)"
        }

        func toolPhase(_ tool: VisibleTool) -> ActivityNarrativePhase {
            if [.failed, .missingResult, .disconnected].contains(tool.status) { return .blocked }
            let name = tool.name.lowercased()
            if ToolPresentation.isExploration(name) || ["fetch", "web_search", "view_image"].contains(name) { return .exploring }
            if ["edit", "write", "edit_file", "write_file", "apply_patch", "filechange"].contains(name) { return .editing }
            if let command = ShellActivity.command(tool) { return ShellActivity.parse(command)?.phase ?? .mixed }
            return .mixed
        }

        func appendStage(id: String, phase: ActivityNarrativePhase, subject: String,
                         headline: String, detail: String?, source: ActivityNarrativeSource,
                         evidenceIDs: [String] = [], lifecycle: ActivityNarrativeLifecycle = .streaming) {
            let narrative = ActivityNarrative(turnID: turnID, stageID: id, phase: phase,
                subject: subject, headline: ActivityNarrativeSnapshot.clean(headline),
                detail: detail.map { ActivityNarrativeSnapshot.clean($0) },
                source: source, evidenceIDs: evidenceIDs, lifecycle: lifecycle)
            stages.append(Builder(narrative: narrative))
        }

        for entry in currentEntries {
            if entry.presentation == .progress {
                let text = entry.messages.flatMap(\.content).compactMap(\.visibleText)
                .map({ ActivityNarrativeSnapshot.clean($0) }).filter({ !$0.isEmpty }).joined(separator: " ")
                if !text.isEmpty {
                    let narrativeText = ActivityNarrativeSnapshot.narrativeText(text)
                    appendStage(id: "commentary:\(entry.messages[0].id)", phase: phase(from: text),
                            subject: narrativeText.headline, headline: narrativeText.headline,
                            detail: narrativeText.detail, source: .commentary)
                }
            }

            for message in entry.messages {
                for part in message.content {
                    if part.type == "thinking", part.source?["kind"].string == "activity_summary" {
                        let parts = part.source?["summaryParts"].array.compactMap(\.string) ?? []
                        let text = parts.map { ActivityNarrativeSnapshot.clean($0) }
                            .filter { !$0.isEmpty }.joined(separator: " ")
                        guard !text.isEmpty else { continue }
                        let narrativeText = ActivityNarrativeSnapshot.narrativeText(text)
                        let itemID = part.source?["itemId"].string ?? message.id
                        let state = part.source?["state"].string == "final"
                            ? ActivityNarrativeLifecycle.final : .streaming
                        appendStage(id: "provider:\(itemID)", phase: phase(from: text),
                                    subject: narrativeText.headline, headline: narrativeText.headline,
                                    detail: narrativeText.detail, source: .provider, lifecycle: state)
                        continue
                    }
                    if part.type == "thinking", stages.isEmpty {
                        appendStage(id: "stage:\(turnID):thinking:\(message.id)", phase: .exploring,
                                    subject: "", headline: L("分析任务"), detail: nil, source: .local)
                        continue
                    }
                    guard part.type == "tool_use", let id = part.toolCallId, let tool = tools[id] else { continue }
                    let nextPhase = toolPhase(tool)
                    let target = ToolPresentation.compactTarget(tool)
                    let shellCommand = ShellActivity.command(tool)
                    let shell = shellCommand.flatMap(ShellActivity.parse)
                    let headline: String
                    if shellCommand != nil, nextPhase != .blocked {
                        let description = tool.input?["description"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
                        headline = description.flatMap { $0.isEmpty ? nil : $0 }
                            ?? shell?.headline ?? L("准备命令环境")
                    } else { headline = localHeadline(nextPhase, target: target) }
                    // Waiting/setup commands are evidence within the current task,
                    // not a new semantic stage that displaces explicit progress.
                    let incidental = shellCommand != nil && (shell?.category == nil || shell?.category == "wait") && nextPhase != .blocked
                    let needsStage = stages.isEmpty || (!incidental && stages.last!.narrative.phase != nextPhase && !stages.last!.toolIDs.isEmpty)
                    if needsStage {
                        appendStage(id: "stage:\(turnID):tool:\(id)", phase: nextPhase, subject: target,
                                    headline: headline, detail: nil,
                                    source: .local, evidenceIDs: [id])
                    } else {
                        var current = stages.removeLast()
                        if current.narrative.source == .local && current.toolIDs.isEmpty {
                            current.narrative = ActivityNarrative(turnID: turnID, stageID: current.narrative.stageID,
                                phase: nextPhase, subject: target, headline: headline,
                                detail: nil, source: .local, evidenceIDs: [id], lifecycle: .streaming)
                        }
                        stages.append(current)
                    }
                    if !stages[stages.count - 1].toolIDs.contains(id) {
                        stages[stages.count - 1].toolIDs.append(id)
                    }
                }
            }
            if entry.isProcess || entry.presentation == .progress, !stages.isEmpty {
                let index = stages.count - 1
                if !stages[index].entryIDs.contains(entry.id) { stages[index].entryIDs.append(entry.id) }
                entryStageIDs[entry.id] = stages[index].narrative.stageID
            }
        }

        let output = stages.enumerated().map { index, builder -> ActivityNarrativeStage in
            let closed = index < stages.count - 1 || !isRunning
            let narrative = ActivityNarrative(turnID: builder.narrative.turnID,
                stageID: builder.narrative.stageID, phase: builder.narrative.phase,
                subject: builder.narrative.subject, headline: builder.narrative.headline,
                detail: builder.narrative.detail, source: builder.narrative.source,
                evidenceIDs: builder.toolIDs.isEmpty ? builder.narrative.evidenceIDs : builder.toolIDs,
                lifecycle: closed ? .final : builder.narrative.lifecycle,
                revision: builder.narrative.revision)
            return ActivityNarrativeStage(narrative: narrative, entryIDs: builder.entryIDs,
                                          toolIDs: builder.toolIDs, closed: closed)
        }
        return ActivityNarrativeSnapshot(turnID: turnID, stages: output,
                                         entryStageIDs: entryStageIDs).applying(external)
    }
}

public extension ConversationTimelineEntry {
    func isNarrativeSource(for narrative: ActivityNarrative) -> Bool {
        switch narrative.source {
        case .commentary:
            return presentation == .progress
        case .provider:
            return messages.contains { message in
                message.content.contains {
                    $0.type == "thinking" && $0.source?["kind"].string == "activity_summary"
                }
            }
        case .external, .local:
            return false
        }
    }
}
