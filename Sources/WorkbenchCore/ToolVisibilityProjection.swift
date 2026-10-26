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
    /// The exit code a shell result reports in its own output text, carried onto
    /// the label. Like every returned error it is an observed outcome the agent
    /// reads and continues from, not an attention item.
    public var exitCodeReport: Int? {
        guard status == .failed, let text = output?.display,
              let marker = text.range(of: "Command failed with exit code: ", options: .literal)
        else { return nil }
        let digits = text[marker.upperBound...].prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }
    /// A returned error folds away like a success: the agent saw it and moved on.
    /// Only work in flight, uncertainty about the record (no result, a lost
    /// connection, a missing call) or a decision only the user can make stays
    /// visible.
    public var staysVisible: Bool {
        [.running, .missingResult, .disconnected, .awaitingApproval].contains(status) || !hasCall
    }

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
    /// The output for the turns before the latest user prompt. The same instance
    /// is returned while a later update may reuse it.
    public final class Prefix {
        /// Each earlier turn projected on its own, in order, when no tool identity
        /// connects two of them; nil when the prefix was projected as a whole.
        public let chunks: [Chunk]?
        private var storedMessages: [KimiMessage]?
        private var storedTools: [String: VisibleTool]?
        /// Joined on first use: per-turn consumers read the chunks instead.
        public var messages: [KimiMessage] {
            if let storedMessages { return storedMessages }
            var value: [KimiMessage] = []
            value.reserveCapacity(chunks!.reduce(0) { $0 + $1.messages.count })
            for chunk in chunks! { value.append(contentsOf: chunk.messages) }
            storedMessages = value
            return value
        }
        public var tools: [String: VisibleTool] {
            if let storedTools { return storedTools }
            var value: [String: VisibleTool] = [:]
            value.reserveCapacity(chunks!.reduce(0) { $0 + $1.tools.count })
            for chunk in chunks! { value.merge(chunk.tools) { _, latest in latest } }
            storedTools = value
            return value
        }
        fileprivate let source: ArraySlice<KimiMessage>
        fileprivate let anchor: String
        fileprivate let sessionID: String
        fileprivate let online: Bool
        /// Tool identities whose output belongs to the prefix: its own parts and
        /// remembered live tools anchored to an earlier turn.
        fileprivate let identities: Set<String>
        fileprivate let active: Set<String>
        fileprivate let observed: [String: ObservedLive]
        fileprivate init(messages: [KimiMessage]?, tools: [String: VisibleTool]?, chunks: [Chunk]?,
                         source: ArraySlice<KimiMessage>, anchor: String, sessionID: String, online: Bool,
                         identities: Set<String>, active: Set<String>, observed: [String: ObservedLive]) {
            storedMessages = messages; storedTools = tools; self.chunks = chunks
            self.source = source; self.anchor = anchor
            self.sessionID = sessionID; self.online = online; self.identities = identities
            self.active = active; self.observed = observed
        }
    }
    /// One earlier turn, from its user prompt to the next one, or the part of a
    /// turn the loaded window starts with. Its output equals its part of the
    /// whole projection while its tool identities occur in no other turn.
    public final class Chunk {
        public let messages: [KimiMessage]
        public let tools: [String: VisibleTool]
        fileprivate let source: ArraySlice<KimiMessage>
        fileprivate let anchor: String?
        fileprivate let online: Bool
        fileprivate let identities: Set<String>
        /// The running state and remembered live tools its output depends on.
        fileprivate let active: Set<String>
        fileprivate let observed: [String: ObservedLive]
        fileprivate init(messages: [KimiMessage], tools: [String: VisibleTool], source: ArraySlice<KimiMessage>,
                         anchor: String?, online: Bool, identities: Set<String>, active: Set<String>,
                         observed: [String: ObservedLive]) {
            self.messages = messages; self.tools = tools; self.source = source; self.anchor = anchor
            self.online = online; self.identities = identities; self.active = active; self.observed = observed
        }
    }
    public struct Split {
        public let prefix: Prefix
        /// The latest turn, starting with its user prompt.
        public let tail: Snapshot
        /// No tool identity crosses the split: the prefix output and tools are
        /// exactly what a later update projecting only the latest turn may reuse.
        /// When false, only the concatenation equals `update`'s result.
        public let separable: Bool
    }
    fileprivate struct ObservedLive: Equatable {
        let tool: KimiLiveTool
        let anchor: String?
    }
    private var sessionID: String?
    private var observed: [String: ObservedLive] = [:]
    private var order: [String] = []
    private var prefix: Prefix?
    /// The prefix's turns by their first message, reused when a page of older
    /// messages or a new prompt changes the prefix around them.
    private var chunks: [String: Chunk] = [:]
    public init() {}
    public var retainedLiveTools: [KimiLiveTool] { order.compactMap { observed[$0]?.tool } }

    /// Localized fallback names are part of the output; a language change must
    /// not reuse a prefix projected in the previous language.
    public func discardPrefix() { prefix = nil; chunks = [:] }

    public func update(_ messages: [KimiMessage], sessionID: String, live: [KimiLiveTool] = [],
                       running: Set<String> = [], online: Bool = true) -> Snapshot {
        prefix = nil; chunks = [:]
        return project(messages, split: nil, sessionID: sessionID, live: live, running: running, online: online).snapshot
    }

    /// The same projection as `update`, divided at `split`, the index of the
    /// latest user prompt. While the earlier turns, their remembered live tools,
    /// the connection state and their running tools stay the same, and no tool
    /// identity of the latest turn also occurs before it, the earlier output is
    /// reused and only the latest turn is projected. A changed prefix reuses its
    /// unchanged turns while no tool identity connects two turns or the latest
    /// one. Otherwise everything is projected.
    public func update(_ messages: [KimiMessage], splittingAt split: Int, sessionID: String, live: [KimiLiveTool] = [],
                       running: Set<String> = [], online: Bool = true) -> Split {
        precondition(messages.indices.contains(split) && messages[split].isUserPrompt
                     && !messages[(split + 1)...].contains(where: \.isUserPrompt), "Split at the latest user prompt")
        observe(live, sessionID: sessionID, anchor: messages[split].id)
        let activeIDs = running.union(live.map(\.id))
        if let prefix, canReuse(prefix, messages: messages, split: split, sessionID: sessionID,
                                activeIDs: activeIDs, online: online) {
            let tail = normalize(messages[split...], activeIDs: activeIDs, online: online, anchor: prefix.anchor)
            return Split(prefix: prefix, tail: tail, separable: true)
        }
        if let prefix = projectTurns(messages, split: split, sessionID: sessionID, activeIDs: activeIDs, online: online) {
            self.prefix = prefix
            let tail = normalize(messages[split...], activeIDs: activeIDs, online: online, anchor: prefix.anchor)
            return Split(prefix: prefix, tail: tail, separable: true)
        }
        let result = project(messages, split: split, sessionID: sessionID, live: [], running: activeIDs, online: online)
        let prefix = result.prefix!
        let separable = separates(messages[split...], from: prefix.identities, anchor: prefix.anchor)
        // Its output then depends on the latest turn, e.g. an earlier call's late result.
        if !separable { self.prefix = nil }
        return Split(prefix: prefix, tail: result.tail!, separable: separable)
    }

    /// The prefix as its turns, each projected on its own and reused while its
    /// messages, running tools, remembered live tools and the connection state
    /// stay the same. Nil unless that equals the projection of the whole window:
    /// every tool identity occurs in one turn only, none of them in the latest
    /// turn, and each remembered live tool belongs to a known turn.
    private func projectTurns(_ messages: [KimiMessage], split: Int, sessionID: String,
                              activeIDs: Set<String>, online: Bool) -> Prefix? {
        let anchor = messages[split].id
        var anchored: [String: [String]] = [:]
        for id in order {
            // The whole projection emits a live tool without a turn before the first prompt.
            guard let turn = observed[id]?.anchor else { return nil }
            anchored[turn, default: []].append(id)
        }
        var bounds: [Range<Int>] = []
        var start = 0
        for index in 1..<max(split, 1) where messages[index].isUserPrompt {
            bounds.append(start..<index); start = index
        }
        if split > 0 { bounds.append(start..<split) }
        // Every turn but a leading partial one starts with its prompt.
        let leadingPrompt = messages[0].isUserPrompt
        var turnAnchors: [String: Int] = [:]
        for (index, range) in bounds.enumerated() where index > 0 || leadingPrompt {
            // Two prompts with one id would both take the live tools anchored to it.
            guard turnAnchors.updateValue(index, forKey: messages[range.lowerBound].id) == nil else { return nil }
        }
        guard turnAnchors[anchor] == nil else { return nil }
        var candidates: [Chunk?] = []
        var identities: [Set<String>] = []
        var owner: [String: Int] = [:]
        for (index, range) in bounds.enumerated() {
            let source = messages[range]
            let previous = chunks[source.first!.id]
            let candidate = previous.flatMap { $0.source.count == source.count && $0.source.elementsEqual(source) ? $0 : nil }
            let own = candidate?.identities ?? Self.identities(in: source)
            for id in own where owner.updateValue(index, forKey: id) != nil { return nil }
            candidates.append(candidate); identities.append(own)
        }
        // A live tool appended after its turn is placed there only while no
        // other turn holds its call or result.
        for (turn, ids) in anchored {
            guard let index = turnAnchors[turn] else { continue }
            for id in ids where owner[id].map({ $0 != index }) == true { return nil }
        }
        let prefixIdentities = Set(owner.keys).union(observed.compactMap { $0.value.anchor != anchor ? $0.key : nil })
        guard separates(messages[split...], from: prefixIdentities, anchor: anchor) else { return nil }
        var observedByTurn: [Int: [String: ObservedLive]] = [:]
        for (id, entry) in observed {
            if let index = owner[id] { observedByTurn[index, default: [:]][id] = entry }
            if let turn = entry.anchor, let index = turnAnchors[turn] { observedByTurn[index, default: [:]][id] = entry }
        }
        var next: [String: Chunk] = [:]
        var result: [Chunk] = []
        result.reserveCapacity(bounds.count)
        for (index, range) in bounds.enumerated() {
            let source = messages[range]
            let turnAnchor = index > 0 || leadingPrompt ? source.first!.id : nil
            let relevant = observedByTurn[index] ?? [:]
            let active = activeIDs.filter { identities[index].contains($0) || relevant[$0] != nil }
            let chunk: Chunk
            if let candidate = candidates[index], candidate.anchor == turnAnchor, candidate.online == online,
               candidate.active == active, candidate.observed == relevant {
                chunk = candidate
            } else {
                var pass = Pass(observed: observed, order: order, activeIDs: activeIDs, online: online)
                for message in source { pass.collect(message) }
                for message in source { pass.normalize(message) }
                pass.appendUnrecorded(after: turnAnchor)
                chunk = Chunk(messages: pass.normalized, tools: pass.tools, source: source, anchor: turnAnchor,
                              online: online, identities: identities[index], active: active, observed: relevant)
            }
            next[source.first!.id] = chunk
            result.append(chunk)
        }
        chunks = next
        return Prefix(messages: nil, tools: nil, chunks: result, source: messages[..<split], anchor: anchor,
                      sessionID: sessionID, online: online, identities: prefixIdentities,
                      active: activeIDs.intersection(prefixIdentities),
                      observed: observedForPrefix(identities: prefixIdentities, anchor: anchor))
    }

    private static func identities(in messages: ArraySlice<KimiMessage>) -> Set<String> {
        var result = Set<String>()
        for message in messages {
            for (offset, part) in message.content.enumerated() {
                if let id = identity(of: part, in: message, offset: offset) { result.insert(id) }
            }
        }
        return result
    }

    private func observe(_ live: [KimiLiveTool], sessionID: String, anchor: String?) {
        if self.sessionID != sessionID {
            self.sessionID = sessionID; observed = [:]; order = []; prefix = nil; chunks = [:]
        }
        for tool in live {
            if observed[tool.id] == nil { order.append(tool.id) }
            observed[tool.id] = ObservedLive(tool: tool, anchor: observed[tool.id]?.anchor ?? anchor)
        }
    }

    /// Tool identity of a call or result part, including the positional
    /// identity the projection assigns to a part without one.
    private static func identity(of part: KimiPart, in message: KimiMessage, offset: Int) -> String? {
        guard part.type == "tool_use" || part.type == "tool_result" else { return nil }
        return part.toolCallId ?? "unidentified:\(message.id):\(offset)"
    }

    private func observedForPrefix(identities: Set<String>, anchor: String) -> [String: ObservedLive] {
        observed.filter { identities.contains($0.key) || $0.value.anchor != anchor }
    }

    private func canReuse(_ prefix: Prefix, messages: [KimiMessage], split: Int, sessionID: String,
                          activeIDs: Set<String>, online: Bool) -> Bool {
        guard prefix.sessionID == sessionID, prefix.source.count == split, prefix.anchor == messages[split].id,
              prefix.online == online, activeIDs.intersection(prefix.identities) == prefix.active,
              observedForPrefix(identities: prefix.identities, anchor: prefix.anchor) == prefix.observed else { return false }
        return separates(messages[split...], from: prefix.identities, anchor: prefix.anchor)
            && messages[..<split].elementsEqual(prefix.source)
    }

    private func separates(_ tail: ArraySlice<KimiMessage>, from identities: Set<String>, anchor: String) -> Bool {
        // A remembered live tool of the latest turn whose call or result is in
        // an earlier turn is resolved there, not appended after this turn.
        for (id, entry) in observed where entry.anchor == anchor && identities.contains(id) { return false }
        for message in tail {
            for (offset, part) in message.content.enumerated() {
                if let id = Self.identity(of: part, in: message, offset: offset), identities.contains(id) { return false }
            }
        }
        return true
    }

    private func project(_ messages: [KimiMessage], split: Int?, sessionID: String, live: [KimiLiveTool],
                         running: Set<String>, online: Bool)
        -> (snapshot: Snapshot, prefix: Prefix?, tail: Snapshot?) {
        let anchor = messages.last(where: { $0.isUserPrompt })?.id
        observe(live, sessionID: sessionID, anchor: anchor)
        var pass = Pass(observed: observed, order: order, activeIDs: running.union(live.map(\.id)), online: online)
        var prefixIdentities = Set<String>()
        for (index, message) in messages.enumerated() {
            if let split, index < split {
                for (offset, part) in message.content.enumerated() {
                    if let id = Self.identity(of: part, in: message, offset: offset) { prefixIdentities.insert(id) }
                }
            }
            pass.collect(message)
        }
        var currentAnchor: String?
        var boundary: (count: Int, tools: [String: VisibleTool])?
        for (index, message) in messages.enumerated() {
            if message.isUserPrompt {
                pass.appendUnrecorded(after: currentAnchor)
                currentAnchor = message.id
            }
            if index == split { boundary = (pass.normalized.count, pass.tools) }
            pass.normalize(message)
        }
        pass.appendUnrecorded(after: currentAnchor)
        let snapshot = Snapshot(messages: pass.normalized, tools: pass.tools)
        guard let split, let boundary, let anchor else { prefix = nil; return (snapshot, nil, nil) }
        let identities = prefixIdentities.union(observed.compactMap { $0.value.anchor != anchor ? $0.key : nil })
        let value = Prefix(messages: Array(pass.normalized[..<boundary.count]), tools: boundary.tools, chunks: nil,
                           source: messages[..<split], anchor: anchor, sessionID: sessionID, online: online,
                           identities: identities, active: pass.activeIDs.intersection(identities),
                           observed: observedForPrefix(identities: identities, anchor: anchor))
        prefix = value
        let tail = Snapshot(messages: Array(pass.normalized[boundary.count...]),
                            tools: pass.tools.filter { boundary.tools[$0.key] == nil })
        return (snapshot, value, tail)
    }

    /// The latest turn alone, valid once `canReuse` has established that none
    /// of its tool identities is shared with the earlier turns.
    private func normalize(_ messages: ArraySlice<KimiMessage>, activeIDs: Set<String>, online: Bool,
                           anchor: String) -> Snapshot {
        var pass = Pass(observed: observed, order: order, activeIDs: activeIDs, online: online)
        for message in messages { pass.collect(message) }
        for message in messages { pass.normalize(message) }
        pass.appendUnrecorded(after: anchor)
        return Snapshot(messages: pass.normalized, tools: pass.tools)
    }

    private struct Pass {
        let observed: [String: ObservedLive]
        let order: [String]
        let activeIDs: Set<String>
        let online: Bool
        var calls: [String: KimiPart] = [:]
        var results: [String: KimiPart] = [:]
        var tools: [String: VisibleTool] = [:]
        var emitted = Set<String>()
        var normalized: [KimiMessage] = []

        init(observed: [String: ObservedLive], order: [String], activeIDs: Set<String>, online: Bool) {
            self.observed = observed; self.order = order; self.activeIDs = activeIDs; self.online = online
        }

        mutating func collect(_ message: KimiMessage) {
            for part in message.content {
                guard let id = part.toolCallId else { continue }
                if part.type == "tool_use" { calls[id] = part }
                if part.type == "tool_result" { results[id] = part }
            }
        }

        mutating func present(id: String, call: KimiPart?, result: KimiPart?) -> KimiPart {
            let known = observed[id]?.tool
            let active = activeIDs.contains(id)
            let status: VisibleTool.Status
            if let result {
                status = result.isError == true ? .failed : result.isError == false ? .succeeded : .returned
            } else { status = !online ? .disconnected : active ? .running : .missingResult }
            let name = call?.toolName ?? known?.name ?? L("工具结果")
            let input = call?.input ?? known?.args
            tools[id] = VisibleTool(id: id, name: name, input: input, output: result?.output,
                                    progress: known?.lastProgress, status: status, hasCall: call != nil || known != nil)
            return KimiPart(type: "tool_use", text: nil, thinking: nil, toolCallId: id, toolName: name,
                            input: input, output: nil, isError: nil, source: nil, fileId: nil, name: nil)
        }

        // Keep each source part's position: an invisible duplicate placeholder avoids
        // shifting the existing text/thought row identities after deduplication.
        static func hidden() -> KimiPart {
            KimiPart(type: "tool_duplicate", text: nil, thinking: nil, toolCallId: nil, toolName: nil,
                     input: nil, output: nil, isError: nil, source: nil, fileId: nil, name: nil)
        }

        mutating func appendUnrecorded(after turn: String?) {
            for id in order where observed[id]?.anchor == turn && calls[id] == nil && results[id] == nil && emitted.insert(id).inserted {
                let part = present(id: id, call: nil, result: nil)
                normalized.append(KimiMessage(id: "tool-live:\(id)", role: "assistant", content: [part], createdAt: "", metadata: nil))
            }
        }

        mutating func normalize(_ message: KimiMessage) {
            var orphanParts: [KimiPart] = []
            var content: [KimiPart] = []
            content.reserveCapacity(message.content.count)
            for (offset, part) in message.content.enumerated() {
                guard part.type == "tool_use" || part.type == "tool_result" else { content.append(part); continue }
                let id = part.toolCallId ?? "unidentified:\(message.id):\(offset)"
                if part.type == "tool_use" {
                    content.append(emitted.insert(id).inserted ? present(id: id, call: calls[id] ?? part, result: results[id]) : Self.hidden())
                    continue
                }
                if calls[id] == nil && emitted.insert(id).inserted {
                    orphanParts.append(present(id: id, call: nil, result: results[id] ?? part))
                }
                content.append(part)
            }
            normalized.append(KimiMessage(id: message.id, role: message.role, content: content, createdAt: message.createdAt, metadata: message.metadata))
            if !orphanParts.isEmpty {
                normalized.append(KimiMessage(id: "tool-orphan:\(message.id)", role: "assistant", content: orphanParts, createdAt: message.createdAt, metadata: nil))
            }
        }
    }

    /// Native adapters expose busy at session level. Only unresolved calls in the
    /// current turn can be considered running; older missing results stay unknown.
    public static func runningIDs(in messages: [KimiMessage], busy: Bool) -> Set<String> {
        guard busy else { return [] }
        let start = messages.lastIndex { $0.isUserPrompt } ?? 0
        var running = Set<String>()
        for message in messages[start...] {
            for part in message.content where part.type == "tool_use" {
                if let id = part.toolCallId { running.insert(id) }
            }
        }
        // Views evaluate this per update over the whole loaded window: scan the
        // results from the latest message back and stop once every call is resolved.
        for message in messages.reversed() where !running.isEmpty {
            for part in message.content where part.type == "tool_result" {
                if let id = part.toolCallId { running.remove(id) }
            }
        }
        return running
    }
}
