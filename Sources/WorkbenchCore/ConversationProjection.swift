import Foundation

extension String {
    /// Equal to `split(whereSeparator: \.isWhitespace).joined(separator: " ")`:
    /// collapse whitespace runs to one space and trim both ends. The byte path
    /// covers strings whose whitespace is ASCII and not bound to a following
    /// combining mark; anything it cannot prove identical (non-ASCII whitespace
    /// like U+3000, an Extend/SpacingMark right after whitespace, which fuses
    /// into one non-whitespace Character, or unexpected UTF-8) falls back to
    /// the Character-accurate form. The bytes are read in place through
    /// `withUTF8` on a copy-on-write local (a refcount bump for the native
    /// contiguous strings this sees); only the collapsed output is allocated.
    public var collapsedWhitespace: String {
        let strict = { self.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var contiguous = self
        return contiguous.withUTF8 { bytes in
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var pendingSpace = false
            var lastScalar: UInt32 = 0
            var i = 0
            while i < bytes.count {
                let byte = bytes[i]
                if byte == 0x20 || (0x09...0x0D).contains(byte) {
                    // GB9b: a Prepend scalar absorbs the following space into its
                    // own Character, which is then not whitespace; the pinned set
                    // is verified against the stdlib's own breaking in the checks.
                    if Self.isPrependScalar(lastScalar) { return strict() }
                    while i < bytes.count, bytes[i] == 0x20 || (0x09...0x0D).contains(bytes[i]) { i += 1 }
                    if i < bytes.count, bytes[i] >= 0x80, Self.beginsBindingMark(in: bytes, at: i) { return strict() }
                    if !out.isEmpty { pendingSpace = true }
                } else if byte < 0x80 {
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    out.append(byte)
                    lastScalar = 0
                    i += 1
                } else {
                    guard let (scalar, length) = Self.utf8Scalar(in: bytes, at: i),
                          !Self.isNonASCIIWhitespace(scalar) else { return strict() }
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    // A decoded scalar is at most four bytes; copy it directly
                    // instead of walking a slice through the generic append.
                    for offset in 0..<length { out.append(bytes[i + offset]) }
                    lastScalar = scalar
                    i += length
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    /// Unicode GCB=Prepend, pinned. `checkCollapsedWhitespace` walks every
    /// scalar and fails if this set ever disagrees with the toolchain's own
    /// grapheme breaking, so a Unicode data update surfaces as a test
    /// failure, not a silent divergence. 0 means "previous byte was ASCII".
    /// U+111C3 and U+113D1 were added when the whitespace-adjacent walk
    /// surfaced them as Prepend in the current toolchain data; over-inclusion
    /// is the safe direction (a needless strict fallback, never a wrong
    /// answer), so the set may lead the data but must never lag it.
    private static func isPrependScalar(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x0600...0x0605, 0x06DD, 0x070F, 0x0890...0x0891, 0x08E2,
             0x0D4E, 0x110BD, 0x110CD, 0x111C2...0x111C3, 0x113D1,
             0x1193F, 0x11941, 0x11A3A, 0x11A84...0x11A89, 0x11D46,
             0x11F02, 0x16D40...0x16D43:
            return true
        default:
            return false
        }
    }

    /// The Unicode White_Space set outside ASCII, exactly.
    private static func isNonASCIIWhitespace(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    private static func utf8Scalar(in bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> (UInt32, Int)? {
        func continuation(_ j: Int) -> Bool { j < bytes.count && bytes[j] & 0xC0 == 0x80 }
        switch bytes[i] {
        case 0xC2...0xDF:
            guard continuation(i + 1) else { return nil }
            return (UInt32(bytes[i] & 0x1F) << 6 | UInt32(bytes[i + 1] & 0x3F), 2)
        case 0xE0...0xEF:
            guard continuation(i + 1), continuation(i + 2) else { return nil }
            return (UInt32(bytes[i] & 0x0F) << 12 | UInt32(bytes[i + 1] & 0x3F) << 6
                    | UInt32(bytes[i + 2] & 0x3F), 3)
        case 0xF0...0xF4:
            guard continuation(i + 1), continuation(i + 2), continuation(i + 3) else { return nil }
            return (UInt32(bytes[i] & 0x07) << 18 | UInt32(bytes[i + 1] & 0x3F) << 12
                    | UInt32(bytes[i + 2] & 0x3F) << 6 | UInt32(bytes[i + 3] & 0x3F), 4)
        default:
            return nil
        }
    }

    /// Whether the scalar at `i` binds onto a preceding whitespace into one
    /// Character (GB9 x Extend, GB9 x ZWJ, GB9a x SpacingMark). The fused
    /// cluster's `isWhitespace` is a stdlib rule the byte path must not
    /// guess, so any binder forces the strict path. ZWJ is checked by value:
    /// its grapheme-break class is ZWJ, not Extend, so `isGraphemeExtend`
    /// is false for it.
    private static func beginsBindingMark(in bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
        guard let (value, _) = utf8Scalar(in: bytes, at: i), let scalar = Unicode.Scalar(value) else { return true }
        // Scalars the pinned ranges below prove cannot bind skip the property
        // lookups; CJK-heavy excerpts otherwise pay two table walks per
        // whitespace run they follow.
        if isNeverBindingScalar(value) { return false }
        if value == 0x200D || scalar.properties.isGraphemeExtend { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Pinned never-binding ranges for `beginsBindingMark`: CJK, kana, Hangul
    /// and fullwidth blocks that contain no ZWJ, no Grapheme_Extend scalar and
    /// no Mn/Mc/Me, so none of their scalars can fuse with a preceding
    /// whitespace. `checkCollapsedWhitespace` walks every scalar and compares
    /// the byte path against the Character-accurate form on this toolchain's
    /// own Unicode data, so a data update surfaces as a test failure, not a
    /// silent divergence. The halfwidth kana voiced marks U+FF9E/U+FF9F are
    /// Grapheme_Extend and stay out of the set.
    private static func isNeverBindingScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF, 0x3001...0x3029, 0x3030...0x303E,
             0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FF,
             0x3105...0x312F, 0x3131...0x318E, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFF01...0xFF60, 0xFF61...0xFF9D, 0xFFA0...0xFFDC:
            return true
        default:
            return false
        }
    }
}

/// Per-transcript memoization. A streaming tail cannot invalidate completed turns.
/// Compare complete values, including tool results, so history replacement and same-ID
/// edits take exactly the same path as newly received messages.
public final class ConversationProjection {
    public struct Snapshot {
        public let entries: [ConversationTimelineEntry]
        public let results: [String: KimiPart]
        public let navigation: [ConversationTurnSummary]
        public let reusedTurnCount: Int
        public let rebuiltTurnCount: Int
    }
    private struct TurnSnapshot {
        let entries: [ConversationTimelineEntry]
        let results: [String: KimiPart]
        let navigation: [ConversationTurnSummary]
    }
    private struct Turn {
        let messages: [KimiMessage]
        let running: Bool
        let snapshot: TurnSnapshot
    }
    private var turns: [String: Turn] = [:]
    public init() {}

    public func update(_ messages: [KimiMessage], isRunning: Bool) -> Snapshot {
        var groups: [[KimiMessage]] = []
        var group: [KimiMessage] = []
        for message in messages {
            if message.isUserPrompt && !group.isEmpty {
                groups.append(group); group = []
            }
            group.append(message)
        }
        if !group.isEmpty { groups.append(group) }
        var next: [String: Turn] = [:]
        var entries: [ConversationTimelineEntry] = []
        var results: [String: KimiPart] = [:]
        var navigation: [ConversationTurnSummary] = []
        var reusedTurnCount = 0
        var rebuiltTurnCount = 0
        for (index, group) in groups.enumerated() {
            let id = group[0].id
            let running = isRunning && index == groups.count - 1
            let turn: Turn
            if let prior = turns[id], prior.running == running, prior.messages == group {
                turn = prior
                reusedTurnCount += 1
            } else {
                var turnResults: [String: KimiPart] = [:]
                for message in group {
                    for part in message.content where part.type == "tool_result" {
                        if let id = part.toolCallId { turnResults[id] = part }
                    }
                }
                let timeline = ConversationTimelineEntry.make(group, isRunning: running)
                let summary = ConversationTurnSummary.make(group, entries: timeline)
                turn = Turn(messages: group, running: running, snapshot: TurnSnapshot(
                    entries: timeline, results: turnResults, navigation: summary.map { [$0] } ?? []))
                rebuiltTurnCount += 1
            }
            next[id] = turn
            entries.append(contentsOf: turn.snapshot.entries)
            results.merge(turn.snapshot.results) { _, latest in latest }
            navigation.append(contentsOf: turn.snapshot.navigation)
        }
        turns = next
        return Snapshot(entries: entries, results: results, navigation: navigation,
                        reusedTurnCount: reusedTurnCount, rebuiltTurnCount: rebuiltTurnCount)
    }
}

/// Plain, bounded excerpts computed with the existing per-turn cache. Hovering
/// never parses Markdown, mounts a transcript row, or reads from a provider.
public struct ConversationTurnSummary: Identifiable, Equatable {
    public let id: String
    public let prompt: String
    public let reply: String

    static func make(_ messages: [KimiMessage], entries: [ConversationTimelineEntry]) -> Self? {
        guard let user = messages.first, user.isUserPrompt, let entry = entries.first else { return nil }
        func excerpt(_ message: KimiMessage) -> String {
            if let cronFire = message.cronFire {
                return String(cronFire.prompt.prefix(320)).collapsedWhitespace
            }
            // With only one eligible part there is no next part to budget for.
            // Keep the exact prefix and leading separator of the general path,
            // but do not walk its Characters again just to decide to stop.
            if message.content.count == 1, let part = message.content.first,
               part.type == "text", !part.isRuntimeContext {
                let text = part.skillContextSplit?.prefix ?? part.text ?? ""
                return (" " + String(text.prefix(320))).collapsedWhitespace
            }
            var value = ""
            for part in message.content where part.type == "text" && !part.isRuntimeContext {
                value += " " + String((part.skillContextSplit?.prefix ?? part.text ?? "").prefix(320 - value.count))
                if value.count >= 320 { break }
            }
            return value.collapsedWhitespace
        }
        let prompt = excerpt(user)
        let answer = messages.last { $0.role == "assistant" && $0.content.contains { $0.type == "text" && !$0.isRuntimeContext && !($0.text ?? "").isEmpty } }
        return Self(id: entry.id,
                    prompt: prompt.isEmpty ? String(user.content.compactMap(\.name).joined(separator: ", ").prefix(320)) : prompt,
                    reply: answer.map(excerpt) ?? "")
    }
}
