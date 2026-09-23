import Foundation

/// One frame of a subagent's transcript. Kimi's frame union (text, thinking,
/// tool, notice) stays flat, like KimiPart, so an added kind decodes instead of
/// failing the page.
public struct KimiTranscriptFrame: Decodable, Identifiable, Equatable, Sendable {
    public let kind: String
    public let frameId: String
    public var text: String?
    public let role: String?
    public let toolCallId: String?
    public let name: String?
    public var state: String?
    public let input: JSONValue?
    public var output: JSONValue?
    public var error: String?
    public let progress: JSONValue?
    public let level: String?
    public var message: String?
    public let taskId: String?
    public var id: String { frameId }

    /// Tool frames carry exactly what a tool card reads. The card's own labels
    /// describe the observed state, so a frame with no state stays uncertain.
    public var tool: VisibleTool? {
        guard kind == "tool", let toolCallId else { return nil }
        let status: VisibleTool.Status
        switch state {
        case "running": status = .running
        case "done": status = .succeeded
        case "error": status = .failed
        default: status = .missingResult
        }
        return VisibleTool(id: toolCallId, name: name ?? toolCallId, input: input, output: output,
                           progress: progress, status: status)
    }
}

/// A step header arrives without frames and a frame without its step, so both
/// collections are optional and folded in place.
public struct KimiTranscriptStep: Decodable, Identifiable, Equatable, Sendable {
    public let stepId: String
    public var state: String?
    public var frames: [KimiTranscriptFrame]?
    public var endedAt: String?
    public var endMessage: String?
    public var id: String { stepId }
}

/// An item of the transcript's own timeline. Only turns are kept here; markers
/// and task references carry nothing a reader can act on without the full store.
public struct KimiTranscriptItem: Decodable, Identifiable, Equatable, Sendable {
    public let kind: String
    public let turnId: String?
    public let ordinal: Int?
    public var state: String?
    public var prompt: String?
    public var steps: [KimiTranscriptStep]?
    public var error: String?
    public var endedAt: String?
    public var id: String { turnId ?? "" }
}

/// `GET /sessions/{id}/transcript?agent_id=…` returns one turn-granular page.
public struct KimiTranscriptPage: Decodable, Sendable {
    public let agentId: String
    public let items: [KimiTranscriptItem]
    public let hasMore: Bool
    public let seq: Int?
}

/// The reset a subscription receives. The server's reset window holds no turns,
/// so this is a watermark plus whatever non-turn state the store keeps.
public struct KimiTranscriptReset: Decodable, Sendable {
    public let agentId: String
    public let snapshot: KimiTranscriptSnapshot?
    public let hasMoreOlder: Bool?
    public let seq: Int?
}
public struct KimiTranscriptSnapshot: Decodable, Equatable, Sendable {
    public let items: [KimiTranscriptItem]?
}

/// One `transcript.ops` delivery.
public struct KimiTranscriptOpsBatch: Decodable, Sendable {
    public let agentId: String
    public let ops: [KimiTranscriptOp]
    public let seq: Int?
}
public struct KimiTranscriptOp: Decodable, Equatable, Sendable {
    public let op: String
    public let turn: KimiTranscriptItem?
    public let turnId: String?
    public let step: KimiTranscriptStep?
    public let stepId: String?
    public let frame: KimiTranscriptFrame?
    public let snapshot: KimiTranscriptSnapshot?
    public let ids: [String]?
}

/// One subagent's transcript as this client knows it: a page read over REST plus
/// the operations streamed since. Upserts replace whole records, so an operation
/// that arrives twice cannot duplicate a turn, step or frame.
public struct KimiSubagentTranscript: Equatable, Sendable {
    public let agentId: String
    public private(set) var turns: [KimiTranscriptItem] = []
    public private(set) var seq: Int?
    public private(set) var hasMoreOlder = false
    public init(agentId: String) { self.agentId = agentId }

    public mutating func load(_ page: KimiTranscriptPage, prepend: Bool) {
        let incoming = Self.turnItems(page.items)
        if prepend {
            let known = Set(turns.compactMap(\.turnId))
            turns = incoming.filter { !known.contains($0.turnId ?? "") } + turns
        } else {
            turns = incoming
        }
        // An older page carries an older watermark; only a newer one replaces it.
        if let pageSeq = page.seq, pageSeq > (seq ?? -1) { seq = pageSeq }
        hasMoreOlder = page.hasMore
    }

    public mutating func apply(_ reset: KimiTranscriptReset) {
        seq = reset.seq ?? seq
        let incoming = Self.turnItems(reset.snapshot?.items ?? [])
        // The reset window carries no turns, so an empty list is a watermark and
        // must not discard the page already read.
        guard !incoming.isEmpty else { return }
        turns = incoming
        hasMoreOlder = reset.hasMoreOlder ?? false
    }

    public mutating func apply(_ batch: KimiTranscriptOpsBatch) {
        seq = batch.seq ?? seq
        for op in batch.ops { apply(op) }
    }

    private mutating func apply(_ op: KimiTranscriptOp) {
        switch op.op {
        case "reset":
            guard let snapshot = op.snapshot else { return }
            let incoming = Self.turnItems(snapshot.items ?? [])
            guard !incoming.isEmpty else { return }
            turns = incoming
        case "turn.upsert":
            guard let turn = op.turn, let id = turn.turnId else { return }
            guard let index = turns.firstIndex(where: { $0.turnId == id }) else { turns.append(turn); return }
            // A header carries no steps; keep the ones already folded in.
            var merged = turn
            merged.steps = turns[index].steps
            turns[index] = merged
        case "step.upsert":
            guard let turnId = op.turnId, let step = op.step,
                  let turn = turns.firstIndex(where: { $0.turnId == turnId }) else { return }
            var steps = turns[turn].steps ?? []
            if let index = steps.firstIndex(where: { $0.stepId == step.stepId }) {
                // A header carries no frames; keep the ones already folded in.
                var merged = step
                merged.frames = steps[index].frames
                steps[index] = merged
            } else { steps.append(step) }
            turns[turn].steps = steps
        case "frame.upsert":
            guard let turnId = op.turnId, let stepId = op.stepId, let frame = op.frame,
                  let turn = turns.firstIndex(where: { $0.turnId == turnId }) else { return }
            var steps = turns[turn].steps ?? []
            guard let step = steps.firstIndex(where: { $0.stepId == stepId }) else { return }
            var frames = steps[step].frames ?? []
            if let index = frames.firstIndex(where: { $0.frameId == frame.frameId }) { frames[index] = frame }
            else { frames.append(frame) }
            steps[step].frames = frames
            turns[turn].steps = steps
        case "items.remove":
            let removed = Set(op.ids ?? [])
            turns.removeAll { removed.contains($0.turnId ?? "") }
        // Markers, task references, tasks, interactions, attachments, todos,
        // prompts and meta describe state this view does not render. `append`
        // only arrives at the delta grade, which this client does not request.
        default: return
        }
    }

    private static func turnItems(_ items: [KimiTranscriptItem]) -> [KimiTranscriptItem] {
        items.filter { $0.kind == "turn" && $0.turnId != nil }
    }
}
