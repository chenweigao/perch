import Foundation

public struct VisibleTool: Identifiable, Equatable {
    public enum Status: Equatable { case running, succeeded, returned, failed, missingResult, disconnected, awaitingApproval }
    public let id: String
    public let name: String
    public let input: JSONValue?
    public let output: JSONValue?
    public let progress: JSONValue?
    public let status: Status
    public let hasCall: Bool
    public var staysVisible: Bool { status != .succeeded && status != .returned || !hasCall }

    public init(id: String, name: String, input: JSONValue?, output: JSONValue? = nil,
                progress: JSONValue? = nil, status: Status, hasCall: Bool = true) {
        self.id = id; self.name = name; self.input = input; self.output = output
        self.progress = progress; self.status = status; self.hasCall = hasCall
    }
}

/// Presentation only: no remote actions or invented success. Retain live-only calls
/// during the snapshot handoff so an absent result becomes visible uncertainty.
/// All ordinary history remains authoritative, including same-ID result edits.
public final class ToolVisibilityProjection {
    public struct Snapshot {
        public let messages: [KimiMessage]
        public let tools: [String: VisibleTool]
    }
    private struct ObservedLive {
        let tool: KimiLiveTool
        let anchor: String?
    }
    private var sessionID: String?
    private var observed: [String: ObservedLive] = [:]
    private var order: [String] = []
    public init() {}

    public func update(_ messages: [KimiMessage], sessionID: String, live: [KimiLiveTool] = [],
                       running: Set<String> = [], online: Bool = true) -> Snapshot {
        if self.sessionID != sessionID {
            self.sessionID = sessionID; observed = [:]; order = []
        }
        let anchor = messages.last(where: { $0.isUserPrompt })?.id
        for tool in live {
            if observed[tool.id] == nil { order.append(tool.id) }
            observed[tool.id] = ObservedLive(tool: tool, anchor: observed[tool.id]?.anchor ?? anchor)
        }
        var calls: [String: KimiPart] = [:], results: [String: KimiPart] = [:]
        for message in messages {
            for part in message.content {
                guard let id = part.toolCallId else { continue }
                if part.type == "tool_use" { calls[id] = part }
                if part.type == "tool_result" { results[id] = part }
            }
        }
        let activeIDs = running.union(live.map(\.id))
        var tools: [String: VisibleTool] = [:]
        var emitted = Set<String>()
        func present(id: String, call: KimiPart?, result: KimiPart?) -> KimiPart {
            let known = observed[id]?.tool
            let active = activeIDs.contains(id)
            let status: VisibleTool.Status
            if let result {
                status = result.isError == true ? .failed : result.isError == false ? .succeeded : .returned
            } else { status = !online ? .disconnected : active ? .running : .missingResult }
            let name = call?.toolName ?? known?.name ?? "工具结果"
            let input = call?.input ?? known?.args
            tools[id] = VisibleTool(id: id, name: name, input: input, output: result?.output,
                                    progress: known?.lastProgress, status: status, hasCall: call != nil || known != nil)
            return KimiPart(type: "tool_use", text: nil, thinking: nil, toolCallId: id, toolName: name,
                            input: input, output: nil, isError: nil, source: nil, fileId: nil, name: nil)
        }
        var normalized: [KimiMessage] = []
        // Keep each source part's position: an invisible duplicate placeholder avoids
        // shifting the existing text/thought row identities after deduplication.
        func hidden() -> KimiPart {
            KimiPart(type: "tool_duplicate", text: nil, thinking: nil, toolCallId: nil, toolName: nil,
                     input: nil, output: nil, isError: nil, source: nil, fileId: nil, name: nil)
        }
        func appendUnrecorded(after turn: String?) {
            for id in order where observed[id]?.anchor == turn && calls[id] == nil && results[id] == nil && emitted.insert(id).inserted {
                let part = present(id: id, call: nil, result: nil)
                normalized.append(KimiMessage(id: "tool-live:\(id)", role: "assistant", content: [part], createdAt: "", metadata: nil))
            }
        }
        var currentAnchor: String?
        for message in messages {
            if message.isUserPrompt {
                appendUnrecorded(after: currentAnchor)
                currentAnchor = message.id
            }
            var orphanParts: [KimiPart] = []
            let content = message.content.enumerated().map { offset, part -> KimiPart in
                guard part.type == "tool_use" || part.type == "tool_result" else { return part }
                let id = part.toolCallId ?? "unidentified:\(message.id):\(offset)"
                if part.type == "tool_use" {
                    guard emitted.insert(id).inserted else { return hidden() }
                    return present(id: id, call: calls[id] ?? part, result: results[id])
                }
                if calls[id] == nil && emitted.insert(id).inserted {
                    orphanParts.append(present(id: id, call: nil, result: results[id] ?? part))
                }
                return part
            }
            normalized.append(KimiMessage(id: message.id, role: message.role, content: content, createdAt: message.createdAt, metadata: message.metadata))
            if !orphanParts.isEmpty {
                normalized.append(KimiMessage(id: "tool-orphan:\(message.id)", role: "assistant", content: orphanParts, createdAt: message.createdAt, metadata: nil))
            }
        }
        appendUnrecorded(after: currentAnchor)
        return Snapshot(messages: normalized, tools: tools)
    }

    /// Native adapters expose busy at session level. Only unresolved calls in the
    /// current turn can be considered running; older missing results stay unknown.
    public static func runningIDs(in messages: [KimiMessage], busy: Bool) -> Set<String> {
        guard busy else { return [] }
        let start = messages.lastIndex { $0.isUserPrompt } ?? 0
        let parts = messages.dropFirst(start).flatMap(\.content)
        return Set(parts.filter { $0.type == "tool_use" }.compactMap(\.toolCallId))
            .subtracting(messages.flatMap(\.content).filter { $0.type == "tool_result" }.compactMap(\.toolCallId))
    }
}
