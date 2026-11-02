import Foundation

/// A scheduled-task wake-up arrives as a user-role message whose entire text is
/// the cron envelope. The envelope is harness machinery, not typed prose, but
/// unlike folded runtime context it still anchors the turn it started: the row
/// collapses to a quiet marker with the task summary, the raw envelope stays
/// behind a disclosure, and naming/excerpts read the inner prompt.
public struct CronFireEnvelope: Equatable, Sendable {
    public let cron: String
    public let recurring: Bool
    public let coalescedCount: Int
    public let stale: Bool
    /// The scheduled prompt, verbatim.
    public let prompt: String

    /// Parses a full-envelope text. Lenient about missing attributes and a
    /// missing prompt block: anything bracketed by the envelope tags is ours,
    /// and rendering it as a prose bubble would be wrong either way.
    public static func parse(_ text: String) -> CronFireEnvelope? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<cron-fire "), trimmed.hasSuffix("</cron-fire>"),
              let openEnd = trimmed.firstIndex(of: ">") else { return nil }
        let attributeStart = trimmed.index(trimmed.startIndex, offsetBy: "<cron-fire ".count)
        let attributes = Self.attributes(trimmed[attributeStart..<openEnd])
        var prompt = ""
        if let open = trimmed.range(of: "<prompt>", range: openEnd..<trimmed.endIndex),
           let close = trimmed.range(of: "</prompt>", range: open.upperBound..<trimmed.endIndex) {
            prompt = String(trimmed[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return CronFireEnvelope(cron: attributes["cron"] ?? "",
                                recurring: attributes["recurring"] == "true",
                                coalescedCount: Int(attributes["coalescedCount"] ?? "") ?? 0,
                                stale: attributes["stale"] == "true", prompt: prompt)
    }

    private static func attributes(_ source: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = source
        while let equals = rest.firstIndex(of: "=") {
            let key = rest[..<equals].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: equals)...]
            guard rest.first == "\"", let close = rest.dropFirst().firstIndex(of: "\"") else { break }
            if !key.isEmpty, key.allSatisfy(\.isLetter) {
                result[key] = String(rest[rest.index(after: rest.startIndex)..<close])
            }
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}

extension KimiMessage {
    /// The cron envelope when the whole user message is a scheduled wake-up;
    /// ordinary prompts and mixed content never parse.
    public var cronFire: CronFireEnvelope? {
        guard isUserPrompt, content.count == 1, let part = content.first,
              part.type == "text", !part.isRuntimeContext, part.skillContextSplit == nil,
              let text = part.text else { return nil }
        return CronFireEnvelope.parse(text)
    }
}
